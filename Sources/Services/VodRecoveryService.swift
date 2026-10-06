import Foundation
import CryptoKit

// ═══════════════════════════════════════════════════════════════════════════
//  Récupération de VODs supprimées.
//
//  Twitch efface les métadonnées d'une diffusion dès sa VOD supprimée : son
//  id de diffusion et son heure de début deviennent introuvables via l'API.
//  On les relit donc chez une source externe (kVodRecoveryMetaAPI), à qui on
//  ne transmet que le nom public de la chaîne, sur une session sans cookies.
//
//  Avec (login, streamID, heure), on reconstruit le dossier CDN de la VOD —
//    dossier = SHA1("login_streamID_epoch")[:20]_login_streamID_epoch
//  (formule vérifiée) — puis on cherche sa playlist parmi les hôtes connus.
//  Les segments d'une VOD supprimée restent servis un temps (jours à quelques
//  semaines) : au-delà, le CDN les purge et la récupération échoue — c'est une
//  limite du procédé, pas un bug.
// ═══════════════════════════════════════════════════════════════════════════
@MainActor
final class VodRecoveryService: ObservableObject {
    @Published private(set) var streams: [RecoverableStream] = []
    @Published private(set) var loading = false
    @Published private(set) var failed  = false
    @Published private(set) var channel = ""

    /// Session éphémère : ni cookies ni cache, et seul le nom de chaîne sort.
    private nonisolated let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.httpCookieStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    // MARK: – Liste des diffusions passées (source externe)
    func load(channel raw: String) async {
        let login = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !login.isEmpty else { return }
        if login == channel, !streams.isEmpty { return }   // déjà chargé
        channel = login; loading = true; failed = false; streams = []
        defer { loading = false }

        guard let url = URL(string: kVodRecoveryMetaAPI + login) else { failed = true; return }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            logger.warn("RECOVER", "Source externe injoignable", login)
            failed = true; return
        }

        let iso = ISO8601DateFormatter()
        var out: [RecoverableStream] = []
        for item in arr {
            guard let m = item["Metadata"] as? [String: Any] else { continue }
            let sid = (m["StreamID"] as? String) ?? (m["StreamID"] as? NSNumber)?.stringValue
            guard let streamID = sid, !streamID.isEmpty,
                  let startStr = m["StartTime"] as? String,
                  let start = iso.date(from: startStr) else { continue }
            out.append(RecoverableStream(
                streamID: streamID,
                login: (m["StreamerLoginAtStart"] as? String ?? login).lowercased(),
                startedAt: start,
                title: m["TitleAtStart"] as? String ?? "",
                game: m["GameNameAtStart"] as? String ?? "",
                maxViews: (m["MaxViews"] as? NSNumber)?.intValue ?? 0))
        }
        streams = out
        logger.info("RECOVER", "\(out.count) diffusions récupérables listées", login)
    }

    // MARK: – Reconstruction des liens d'une diffusion
    /// Liens prêts à lire, ou nil si le CDN ne sert plus cette diffusion.
    nonisolated func resolve(_ s: RecoverableStream) async -> QualityLinks? {
        let epoch0 = Int(s.startedAt.timeIntervalSince1970)
        // Le décalage 0 couvre la quasi-totalité ; ±1,±2 rattrape un horodatage
        // de la source légèrement différent du nom de dossier réel.
        let plans: [([Int], [String])] = [
            ([0], kVodRecoveryHosts),
            ([-1, 1, -2, 2], Array(kVodRecoveryHosts.prefix(8))),
        ]
        for (offsets, hosts) in plans {
            for off in offsets {
                let folder = folderName(login: s.login, streamID: s.streamID, epoch: epoch0 + off)
                if let host = await firstHost(folder: folder, hosts: hosts) {
                    logger.success("RECOVER", "VOD reconstruite", "\(host) · décalage \(off)")
                    return await buildLinks(host: host, folder: folder)
                }
            }
        }
        logger.warn("RECOVER", "Diffusion plus disponible sur le CDN", s.streamID)
        return nil
    }

    private nonisolated func folderName(login: String, streamID: String, epoch: Int) -> String {
        let key = "\(login)_\(streamID)_\(epoch)"
        let hash = Insecure.SHA1.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "\(hash.prefix(20))_\(key)"
    }

    /// Premier hôte servant `chunked/index-dvr.m3u8`, sondé en parallèle borné.
    private nonisolated func firstHost(folder: String, hosts: [String]) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            let maxConcurrent = 6
            var index = 0
            func launch() {
                guard index < hosts.count else { return }
                let host = hosts[index]; index += 1
                group.addTask {
                    await self.exists("https://\(host)/\(folder)/chunked/index-dvr.m3u8") ? host : nil
                }
            }
            for _ in 0..<min(maxConcurrent, hosts.count) { launch() }
            var found: String? = nil
            while let r = await group.next() {
                if let r { found = r; group.cancelAll(); break }
                launch()
            }
            return found
        }
    }

    /// « Source » (chunked) plus les qualités inférieures présentes au même dossier.
    private nonisolated func buildLinks(host: String, folder: String) async -> QualityLinks {
        let qualities = [("chunked", "Source"), ("720p60", "720p60"),
                         ("720p30", "720p"), ("480p30", "480p")]
        var links: QualityLinks = [:]
        await withTaskGroup(of: (String, String)?.self) { group in
            for (q, label) in qualities {
                group.addTask {
                    let url = "https://\(host)/\(folder)/\(q)/index-dvr.m3u8"
                    return await self.exists(url) ? (label, url) : nil
                }
            }
            for await r in group { if let (label, url) = r { links[label] = url } }
        }
        // chunked a déjà répondu lors de la détection : on la garantit.
        if links["Source"] == nil {
            links["Source"] = "https://\(host)/\(folder)/chunked/index-dvr.m3u8"
        }
        return links
    }

    private nonisolated func exists(_ url: String) async -> Bool {
        guard let u = URL(string: url) else { return false }
        var req = URLRequest(url: u)
        req.httpMethod = "HEAD"
        req.setValue("https://www.twitch.tv/", forHTTPHeaderField: "Referer")
        req.setValue("https://www.twitch.tv", forHTTPHeaderField: "Origin")
        guard let (_, resp) = try? await session.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}
