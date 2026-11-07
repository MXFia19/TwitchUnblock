import AVFoundation

// ═══════════════════════════════════════════════════════════════════════════
//  Direct au plus près : playlists de direct réécrites pour AVPlayer.
//
//  Twitch annonce des segments de 6 s (EXT-X-TARGETDURATION:6) qui en durent
//  2. AVPlayer s'y fie : il ne relit la liste que toutes les 6 s, et se tient
//  par défaut à trois fois cette durée du bord — 18 s, plus le temps que le
//  segment arrive : une vingtaine de secondes de retard. Réécrite avec la
//  vraie durée, la liste est relue toutes les 2 s et le lecteur peut tenir à
//  quelques secondes du bord (LiveLatencyController).
//
//  La liste passe par ce chargeur (adresse `tulive://…`) ; les segments, eux,
//  restent lus sur le CDN en direct (adresses absolues). Les lignes
//  TWITCH-PREFETCH (segments pas encore finis) sont retirées. Utilisé avec le
//  mode faible latence pour la durée cible ; les pubs sont toujours filtrées.
//  AirPlay ne sait pas lire ces adresses : repli sur la playlist d'origine
//  (VodUnmuteLoader.fallBackForAirPlay).
// ═══════════════════════════════════════════════════════════════════════════
final class LivePlaylistLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let shared = LivePlaylistLoader()
    static let scheme = LivePlaylistRewriter.scheme
    static let bufferedScheme = LivePlaylistRewriter.bufferedScheme
    static let playlistNotification = Notification.Name("TULivePlaylist")
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    let queue = DispatchQueue(label: "twitchunblock.live")
    /// Sans cache : une playlist de direct change toutes les 2 s.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    // MARK: Adresses
    static func wrap(_ links: QualityLinks, lowLatency: Bool = true) -> QualityLinks {
        links.mapValues { LivePlaylistRewriter.wrap($0, lowLatency: lowLatency) }
    }

    static func unwrap(_ url: URL) -> URL? { LivePlaylistRewriter.unwrap(url) }

    // MARK: Chargement
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, LivePlaylistRewriter.isWrapped(url),
              let real = Self.unwrap(url) else { return false }
        let id = ObjectIdentifier(loadingRequest)
        tasks[id] = Task {
            let data = await self.playlist(real, lowLatency: url.scheme == Self.scheme)
            self.queue.async {
                self.tasks.removeValue(forKey: id)
                guard !loadingRequest.isCancelled else { return }
                if let data {
                    loadingRequest.dataRequest?.respond(with: data)
                    loadingRequest.finishLoading()
                } else {
                    loadingRequest.finishLoading(with: URLError(.badServerResponse))
                }
            }
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }

    private func playlist(_ url: URL, lowLatency: Bool) async -> Data? {
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        guard let (data, resp) = try? await session.data(for: req), !Task.isCancelled,
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard text.hasPrefix("#EXTM3U") else { return nil }
        let playlist = TwitchAdPlaylist(text)
        // Feed the countdown even when AVPlayer is waiting on an all-GAP
        // playlist and hasn't produced timed metadata or a currentDate yet.
        await MainActor.run {
            guard !Task.isCancelled else { return }
            NotificationCenter.default.post(name: Self.playlistNotification, object: url,
                                            userInfo: ["playlist": playlist])
        }
        return Data(Self.rewrite(text, base: resp.url ?? url, lowLatency: lowLatency).utf8)
    }

    static func rewrite(_ text: String, base: URL, lowLatency: Bool = true) -> String {
        LivePlaylistRewriter.rewrite(text, base: base, lowLatency: lowLatency)
    }
}
