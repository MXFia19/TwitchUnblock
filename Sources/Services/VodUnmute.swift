import AVFoundation

// ═══════════════════════════════════════════════════════════════════════════
//  Son des passages coupés (musique protégée)
//
//  Twitch coupe le son de certains passages des VODs : la playlist pointe
//  alors vers « N-muted.ts » (son muet), ou vers « N-unmuted.ts », que le CDN
//  refuse. Pendant un jour ou deux après la diffusion, l'original « N.ts »,
//  avec le son, reste pourtant servi — ensuite il est effacé (403).
//
//  Tant qu'il est là, on le remet : la playlist passe par ce chargeur (adresse
//  `tuunmute://…`), qui la lit sur le CDN, vérifie chaque passage coupé et
//  remplace ceux dont l'original répond. Les segments, eux, viennent toujours
//  du CDN en direct (adresses absolues) : rien ne transite par nos serveurs.
//
//  AirPlay ne sait pas lire ces adresses : quand la lecture part sur un autre
//  écran, on revient à la playlist du CDN (`fallBackForAirPlay`).
// ═══════════════════════════════════════════════════════════════════════════
final class VodUnmuteLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let shared = VodUnmuteLoader()
    static let scheme = "tuunmute"
    /// Résultat d'une playlist réécrite : `url` (adresse du CDN), `restored`
    /// (passages rétablis), `remaining` ([MutedRange] encore muets).
    static let resultNotification = Notification.Name("VodUnmuteResult")

    private let queue = DispatchQueue(label: "twitchunblock.unmute")
    /// Playlists déjà réécrites (changement de qualité, retour en arrière).
    private var cache: [String: Data] = [:]
    private let lock = NSLock()

    // MARK: Adresses
    /// Ça vaut la peine d'essayer : passages coupés, et VOD assez récente
    /// pour que les originaux existent encore (au-delà, ils sont effacés).
    static func worthTrying(_ m: VodMarkers) -> Bool {
        guard !m.muted.isEmpty else { return false }
        guard let created = m.createdAt else { return true }
        return Date().timeIntervalSince(created) < 4 * 86400
    }

    static func wrap(_ links: QualityLinks) -> QualityLinks {
        links.mapValues { link in
            // L'audio seul n'a jamais d'original : rien à gagner, autant
            // garder la lecture directe (et AirPlay).
            guard link.hasPrefix("https://"), !link.contains("/audio_only/") else { return link }
            return scheme + "://" + link.dropFirst("https://".count)
        }
    }

    static func unwrap(_ url: URL) -> URL? {
        guard url.scheme == scheme else { return url }
        return URL(string: "https://" + url.absoluteString.dropFirst(scheme.count + 3))
    }

    static func unwrap(_ link: String) -> String {
        link.hasPrefix(scheme + "://") ? "https://" + link.dropFirst(scheme.count + 3) : link
    }

    /// Élément de lecture : passe par le chargeur pour une adresse maison.
    static func playerItem(url: URL) -> AVPlayerItem {
        guard url.scheme == scheme else { return AVPlayerItem(url: url) }
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(shared, queue: shared.queue)
        return AVPlayerItem(asset: asset)
    }

    /// AirPlay en cours : on repasse sur la playlist du CDN, à la même position.
    static func fallBackForAirPlay(_ player: AVPlayer) {
        guard player.isExternalPlaybackActive,
              let asset = player.currentItem?.asset as? AVURLAsset,
              asset.url.scheme == scheme, let plain = unwrap(asset.url) else { return }
        logger.info("UNMUTE", "AirPlay : retour à la playlist d'origine", nil)
        let t = player.currentTime()
        let item = AVPlayerItem(url: plain)
        var obs: NSKeyValueObservation?
        obs = item.observe(\.status, options: [.new]) { item, _ in
            guard item.status == .readyToPlay else { return }
            DispatchQueue.main.async {
                player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
                obs?.invalidate(); obs = nil
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
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

    private func cached(_ key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }

    private func store(_ data: Data, for key: String) {
        lock.lock(); defer { lock.unlock() }
        if cache.count > 20 { cache.removeAll() }
        cache[key] = data
    }

    private func playlist(_ url: URL) async -> Data? {
        if let hit = cached(url.absoluteString) { return hit }
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard text.hasPrefix("#EXTM3U") else { return nil }
        let out = Data(await rewrite(text, base: url).utf8)
        store(out, for: url.absoluteString)
        return out
    }

    /// Adresses rendues absolues (la base n'est plus celle du CDN), passages
    /// coupés remplacés par leur original quand le CDN l'a encore.
    private func rewrite(_ text: String, base: URL) async -> String {
        var lines = text.components(separatedBy: "\n")
        struct Muted { let index: Int; let original: URL; let start: Double; let duration: Double }
        var muted: [Muted] = []
        var clock = 0.0, pending = 0.0
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXTINF:") {
                pending = Double(line.dropFirst(8).split(separator: ",").first ?? "") ?? 0
                continue
            }
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let abs = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
            var segment = abs.absoluteString
            if let r = segment.range(of: #"-(un)?muted\.ts"#, options: .regularExpression) {
                // « -unmuted » n'existe pas sur le CDN : la version muette sert de repli.
                let original = segment.replacingCharacters(in: r, with: ".ts")
                segment = segment.replacingCharacters(in: r, with: "-muted.ts")
                if let o = URL(string: original) {
                    muted.append(Muted(index: i, original: o, start: clock, duration: pending))
                }
            }
            lines[i] = segment
            clock += pending
            pending = 0
        }
        guard !muted.isEmpty else { return lines.joined(separator: "\n") }

        // Quatre premiers d'abord : tous refusés, les originaux sont effacés
        // (VOD trop ancienne) — inutile d'interroger les centaines suivants.
        var available = Set<Int>()
        let probe = Array(muted.prefix(4))
        let first = await exist(probe.map(\.original))
        for (k, ok) in first.enumerated() where ok { available.insert(probe[k].index) }
        if !available.isEmpty, muted.count > probe.count {
            let rest = Array(muted.dropFirst(probe.count))
            let others = await exist(rest.map(\.original))
            for (k, ok) in others.enumerated() where ok { available.insert(rest[k].index) }
        }
        for m in muted where available.contains(m.index) { lines[m.index] = m.original.absoluteString }

        // Passages encore muets, fusionnés, pour la barre de lecture.
        var remaining: [MutedRange] = []
        for m in muted where !available.contains(m.index) {
            if let last = remaining.last, m.start <= last.end + 0.5 {
                remaining[remaining.count - 1] = MutedRange(start: last.start, end: m.start + m.duration)
            } else {
                remaining.append(MutedRange(start: m.start, end: m.start + m.duration))
            }
        }
        logger.info("UNMUTE", "Passages coupés : \(available.count)/\(muted.count) segments rétablis",
                    base.deletingLastPathComponent().lastPathComponent)
        let restored = available.count
        let playlistURL = base.absoluteString
        await MainActor.run {
            NotificationCenter.default.post(name: Self.resultNotification, object: nil, userInfo: [
                "url": playlistURL, "restored": restored, "remaining": remaining,
            ])
        }
        return lines.joined(separator: "\n")
    }

    /// Le CDN sert-il ces fichiers ? HEAD en parallèle, huit à la fois.
    private func exist(_ urls: [URL]) async -> [Bool] {
        var result = [Bool](repeating: false, count: urls.count)
        await withTaskGroup(of: (Int, Bool).self) { group in
            var next = 0
            while next < min(8, urls.count) {
                let i = next; next += 1
                group.addTask { let ok = await VodUnmuteLoader.head(urls[i]); return (i, ok) }
            }
            while let done = await group.next() {
                result[done.0] = done.1
                if next < urls.count {
                    let j = next; next += 1
                    group.addTask { let ok = await VodUnmuteLoader.head(urls[j]); return (j, ok) }
                }
            }
        }
        return result
    }

    private static func head(_ url: URL) async -> Bool {
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "HEAD"
        let code = (try? await URLSession.shared.data(for: req).1 as? HTTPURLResponse)?.statusCode
        return code == 200
    }
}
