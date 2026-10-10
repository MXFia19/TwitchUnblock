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
//  mode faible latence seulement : le couper rend la playlist d'origine.
//  AirPlay ne sait pas lire ces adresses : repli sur la playlist d'origine
//  (VodUnmuteLoader.fallBackForAirPlay).
// ═══════════════════════════════════════════════════════════════════════════
final class LivePlaylistLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let shared = LivePlaylistLoader()
    static let scheme = "tulive"

    let queue = DispatchQueue(label: "twitchunblock.live")
    /// Sans cache : une playlist de direct change toutes les 2 s.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    // MARK: Adresses
    static func wrap(_ links: QualityLinks) -> QualityLinks {
        links.mapValues { link in
            guard link.hasPrefix("https://") else { return link }
            return scheme + "://" + link.dropFirst("https://".count)
        }
    }

    static func unwrap(_ url: URL) -> URL? {
        guard url.scheme == scheme else { return url }
        return URL(string: "https://" + url.absoluteString.dropFirst(scheme.count + 3))
    }

    // MARK: Chargement
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == Self.scheme,
              let real = Self.unwrap(url) else { return false }
        Task {
            if let data = await self.playlist(real) {
                loadingRequest.dataRequest?.respond(with: data)
                loadingRequest.finishLoading()
            } else {
                loadingRequest.finishLoading(with: URLError(.badServerResponse))
            }
        }
        return true
    }

    private func playlist(_ url: URL) async -> Data? {
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard text.hasPrefix("#EXTM3U") else { return nil }
        return Data(Self.rewrite(text, base: url).utf8)
    }

    /// Adresses absolues, segments annoncés d'avance retirés, et vraie durée
    /// cible. Une liste maîtresse voit ses variantes passer par le chargeur
    /// elles aussi.
    static func rewrite(_ text: String, base: URL) -> String {
        let isMaster = text.contains("#EXT-X-STREAM-INF")
        var out: [String] = []
        var longest = 0.0
        var nextIsVariant = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-TWITCH-PREFETCH") { continue }
            if line.hasPrefix("#EXTINF:") {
                longest = max(longest, Double(line.dropFirst(8).split(separator: ",").first ?? "") ?? 0)
            }
            if line.hasPrefix("#EXT-X-STREAM-INF") { nextIsVariant = true }
            if !line.isEmpty, !line.hasPrefix("#"),
               let abs = URL(string: line, relativeTo: base)?.absoluteString {
                if nextIsVariant, abs.hasPrefix("https://") {
                    out.append(scheme + "://" + abs.dropFirst("https://".count))
                } else {
                    out.append(abs)
                }
                nextIsVariant = false
                continue
            }
            out.append(line)
        }
        // Durée cible = plus long segment, arrondi (règle HLS) : 2 sur Twitch.
        if !isMaster, longest > 0 {
            let target = max(1, Int(longest.rounded()))
            out = out.map { $0.hasPrefix("#EXT-X-TARGETDURATION:") ? "#EXT-X-TARGETDURATION:\(target)" : $0 }
        }
        return out.joined(separator: "\n")
    }
}
