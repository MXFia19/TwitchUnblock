import Foundation

// MARK: – Helpers
private let requestHeaders: [String: String] = [
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Safari/537.36",
    "Referer": "https://www.twitch.tv/",
    "Origin": "https://www.twitch.tv",
]

private let qualityOrder = ["chunked","source","1080p60","1080p30","720p60","720p30",
                             "480p30","360p30","160p30","audio_only"]

// MARK: – M3U8 Parser
func parseM3U8(_ content: String, baseURL: URL? = nil) -> QualityLinks {
    var links: QualityLinks = [:]
    let lines = content.components(separatedBy: "\n")
    for i in 0..<lines.count {
        let line = lines[i].trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("#EXT-X-STREAM-INF") else { continue }
        let nameMatch = line.range(of: #"VIDEO="([^"]+)""#, options: .regularExpression)
        var quality = "unknown"
        if let r = nameMatch {
            let raw = String(line[r]).replacingOccurrences(of: "VIDEO=\"", with: "").replacingOccurrences(of: "\"", with: "")
            quality = raw == "chunked" ? "Source" : raw
        } else if let r = line.range(of: #"RESOLUTION=(\d+x\d+)"#, options: .regularExpression) {
            quality = String(line[r]).replacingOccurrences(of: "RESOLUTION=", with: "")
        }
        let nextLine = i + 1 < lines.count ? lines[i + 1].trimmingCharacters(in: .whitespaces) : ""
        if !nextLine.isEmpty && !nextLine.hasPrefix("#") {
            if nextLine.hasPrefix("http") {
                links[quality] = nextLine
            } else if let base = baseURL, let fullURL = URL(string: nextLine, relativeTo: base)?.absoluteString {
                links[quality] = fullURL
            } else {
                links[quality] = nextLine
            }
        }
    }
    return links
}

// MARK: – GQL
private func twitchGQL(_ query: String) async throws -> Any {
    guard let url = URL(string: "https://gql.twitch.tv/gql") else { throw URLError(.badURL) }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue(kGQLClientID, forHTTPHeaderField: "Client-ID")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(requestHeaders["User-Agent"], forHTTPHeaderField: "User-Agent")
    req.setValue("MkMq8a9\(Int.random(in: 100000...999999))", forHTTPHeaderField: "Device-ID")
    req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    return try JSONSerialization.jsonObject(with: data)
}

// MARK: – Access Token
private func getAccessToken(id: String, isLive: Bool) async -> (value: String, signature: String)? {
    logger.debug("TOKEN", "Récupération token \(isLive ? "live" : "VOD") pour \"\(id)\"")
    let q = isLive
        ? "query { streamPlaybackAccessToken(channelName: \"\(gqlStr(id))\", params: {platform: \"web\", playerBackend: \"mediaplayer\", playerType: \"site\"}) { value signature } }"
        : "query { videoPlaybackAccessToken(id: \"\(gqlStr(id))\", params: {platform: \"web\", playerBackend: \"mediaplayer\", playerType: \"site\"}) { value signature } }"
    guard let json = try? await twitchGQL(q) as? [String: Any],
          let data = json["data"] as? [String: Any],
          let token = (isLive ? data["streamPlaybackAccessToken"] : data["videoPlaybackAccessToken"]) as? [String: Any],
          let value = token["value"] as? String,
          let sig   = token["signature"] as? String else {
        logger.warn("TOKEN", "Token vide pour \"\(id)\"")
        return nil
    }
    logger.success("TOKEN", "Token obtenu pour \"\(id)\"")
    return (value, sig)
}

// MARK: – Storyboard Hack
// Dossier CDN d'une VOD (« https://<distribution>.cloudfront.net/<empreinte>_<chaîne>_<id>_<date> »),
// celui qui contient ses playlists. Avant, il n'était lu que dans seekPreviewsURL :
// une VOD réservée aux abonnés, ou masquée mais toujours listée, peut ne plus l'avoir
// alors que ses autres aperçus pointent encore vers le même dossier. Même logique que
// `vodCdnRoot` du Worker ; renvoie aussi l'aperçu utilisé, pour les logs.
//  - seekPreviewsURL / animatedPreviewURL : https://<cdn>/<dossier>/storyboards/…
//  - previewThumbnailURL : https://static-cdn.jtvnw.net/cf_vods/<distribution>/<dossier>//thumb/…
// Une VOD encore en traitement a une miniature « _404/404_processing » : nil.
private func vodCdnRoot(_ video: [String: Any]) -> (root: String, source: String)? {
    for key in ["seekPreviewsURL", "animatedPreviewURL"] {
        guard let raw = video[key] as? String, let url = URL(string: raw), let host = url.host else { continue }
        let parts = url.path.components(separatedBy: "/")
        if let i = parts.firstIndex(of: "storyboards"), i > 1 {
            return ("https://\(host)/\(parts[i - 1])", key)
        }
    }
    if let raw = video["previewThumbnailURL"] as? String, let url = URL(string: raw),
       url.host == "static-cdn.jtvnw.net" {
        // ["", "cf_vods", distribution, dossier, "", "thumb", …]
        let parts = url.path.components(separatedBy: "/")
        if parts.count > 3, parts[1] == "cf_vods",
           parts[2].range(of: #"^[a-z0-9]+$"#, options: .regularExpression) != nil,
           parts[3].range(of: #"^[0-9a-f]{20}_"#, options: .regularExpression) != nil {
            return ("https://\(parts[2]).cloudfront.net/\(parts[3])", "previewThumbnailURL")
        }
    }
    return nil
}

private func storyboardHack(vodId: String) async -> QualityLinks {
    logger.info("STORYBOARD", "Tentative storyboard hack pour VOD \(vodId)")
    guard let json = try? await twitchGQL("query { video(id: \"\(gqlStr(vodId))\") { seekPreviewsURL animatedPreviewURL previewThumbnailURL(width: 320, height: 180) } }") as? [String: Any],
          let data = json["data"] as? [String: Any],
          let video = data["video"] as? [String: Any] else {
        logger.warn("STORYBOARD", "VOD introuvable", "supprimée ?")
        return [:]
    }
    guard let (root, source) = vodCdnRoot(video) else {
        logger.warn("STORYBOARD", "Aucun aperçu exploitable", "VOD en traitement ou supprimée ?")
        return [:]
    }
    logger.info("STORYBOARD", "Dossier CDN trouvé via \(source)", root)

    var found: QualityLinks = [:]
    await withTaskGroup(of: (String, String)?.self) { group in
        for q in qualityOrder {
            group.addTask {
                let url = "\(root)/\(q)/index-dvr.m3u8"
                guard var req = URL(string: url).map({ URLRequest(url: $0) }) else { return nil }
                req.httpMethod = "HEAD"
                requestHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
                let status = (try? await URLSession.shared.data(for: req).1 as? HTTPURLResponse)?.statusCode
                return status == 200 ? (q == "chunked" ? "Source" : q, url) : nil
            }
        }
        for await result in group {
            if let (key, url) = result { found[key] = url }
        }
    }
    logger.success("STORYBOARD", "\(found.count) qualités trouvées", found.keys.joined(separator: ", "))
    return found
}

// MARK: – getM3U8 (VODs)
func getM3U8(vodId: String) async -> M3U8Data {
    logger.info("M3U8", "Lancement VOD \(vodId)")

    if let token = await getAccessToken(id: vodId, isLive: false) {
        // Identifiant numérique uniquement (il peut venir de l'historique
        // synchronisé) : sinon l'adresse est invalide et le `!` plantait.
        if vodId.allSatisfy(\.isNumber), !vodId.isEmpty,
           var comps = URLComponents(string: "https://usher.ttvnw.net/vod/\(vodId).m3u8") {
        comps.queryItems = [
            .init(name: "nauth",            value: token.value),
            .init(name: "nauthsig",         value: token.signature),
            .init(name: "allow_source",     value: "true"),
            .init(name: "allow_audio_only", value: "true"),
            .init(name: "allow_spectre",    value: "true"),
            .init(name: "player_backend",   value: "mediaplayer"),
        ]
        if let url = comps.url, let req = { var r = URLRequest(url: url); requestHeaders.forEach { r.setValue($1, forHTTPHeaderField: $0) }; return r }() as URLRequest?,
           let (data, resp) = try? await URLSession.shared.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let body = String(data: data, encoding: .utf8) {
            let links = parseM3U8(body, baseURL: url)
            if !links.isEmpty {
                logger.success("M3U8", "[1/3] ✅ \(links.count) qualités", links.keys.joined(separator: ", "))
                return M3U8Data(links: links, error: nil)
            }
        }
        }
        logger.warn("M3U8", "[1/3] Échec token officiel")
    }

    let sbLinks = await storyboardHack(vodId: vodId)
    if !sbLinks.isEmpty {
        logger.success("M3U8", "[2/3] ✅ Storyboard \(sbLinks.count) qualités")
        return M3U8Data(links: sbLinks, error: nil)
    }

    if let url = URL(string: "\(kAPIURL)/api/get-m3u8?id=\(vodId)&proxy=false"),
       let (data, resp) = try? await URLSession.shared.data(from: url),
       (resp as? HTTPURLResponse)?.statusCode == 200,
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let links = json["links"] as? QualityLinks, !links.isEmpty {
        logger.success("M3U8", "[3/3] ✅ Worker \(links.count) qualités")
        return M3U8Data(links: links, error: nil)
    }

    logger.error("M3U8", "❌ Toutes les tentatives ont échoué pour VOD \(vodId)")
    return M3U8Data(links: [:], error: "VOD introuvable ou réservée aux abonnés")
}

// MARK: – getLive (STREAMS)
func getLive(channelName: String) async -> LiveData {
    let login = channelName.trimmingCharacters(in: .whitespaces).lowercased()
    logger.info("LIVE", "Lancement stream \"\(login)\"")

    // ← id ajouté à la query pour récupérer le userId Twitch du canal
    let q = """
    query { user(login: "\(gqlStr(login))") {
        id
        profileImageURL(width: 70)
        stream {
            title game { name } previewImageURL(width: 320, height: 180) viewersCount createdAt
            archiveVideo { id }
        }
    }}
    """
    async let streamTask = twitchGQL(q)
    async let tokenTask  = getAccessToken(id: login, isLive: true)

    guard let (streamJSON, token) = try? await (streamTask, tokenTask),
          let json = streamJSON as? [String: Any],
          let data = json["data"] as? [String: Any],
          let user = data["user"] as? [String: Any] else {
        logger.error("LIVE", "Streamer \"\(login)\" introuvable")
        return LiveData(title: "", game: "", thumbnail: "", error: "Streamer introuvable")
    }

    let avatar = user["profileImageURL"] as? String
    let userId = user["id"] as? String   // ← récupéré ici

    guard let stream = user["stream"] as? [String: Any] else {
        logger.warn("LIVE", "\"\(login)\" est hors ligne")
        return LiveData(title: "Hors ligne", game: "", thumbnail: "", avatar: avatar,
                        userId: userId, error: "offline")
    }

    let title       = stream["title"] as? String ?? ""
    let game        = (stream["game"] as? [String: Any])?["name"] as? String ?? ""
    let thumbnail   = stream["previewImageURL"] as? String ?? ""
    let viewerCount = stream["viewersCount"] as? Int ?? 0
    // VOD en cours d'enregistrement → rembobinage du live (DVR)
    let dvrVideoId  = (stream["archiveVideo"] as? [String: Any])?["id"] as? String
    if let d = dvrVideoId {
        logger.success("LIVE", "Rembobinage disponible (DVR)", "vod \(d)")
    } else {
        logger.debug("LIVE", "Pas de rembobinage", "le streamer n'archive pas ses lives")
    }

    var startedAt: Date? = nil
    if let createdAtStr = stream["createdAt"] as? String {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        startedAt = df.date(from: createdAtStr) ?? ISO8601DateFormatter().date(from: createdAtStr)
    }

    var links: QualityLinks = [:]

    let sourcePref = UserDefaults.standard.string(forKey: "liveSource") ?? "auto"
    logger.info("LIVE", "Source sélectionnée : \(sourcePref.uppercased())")

    // 1 - Luminous (plusieurs miroirs : on bascule sur le suivant si l'un tombe)
    if sourcePref == "auto" || sourcePref == "luminous" {
        for host in kLuminousHosts {
            if !links.isEmpty { break }
            logger.info("LIVE", "Tentative Luminous (Sans Pub)…", host)
            guard var lumComps = URLComponents(string: "https://\(host)/live/\(login)") else { continue }
            lumComps.queryItems = [
                .init(name: "allow_source",     value: "true"),
                .init(name: "allow_audio_only", value: "true"),
                // fast_bread = variante faible latence côté Twitch.
                .init(name: "fast_bread",       value: "true")
            ]
            guard let lumUrl = lumComps.url else { continue }
            var req = URLRequest(url: lumUrl)
            requestHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200, let body = String(data: data, encoding: .utf8) {
                    links = parseM3U8(body, baseURL: lumUrl)
                    if !links.isEmpty {
                        logger.success("LIVE", "✅ Luminous OK (\(host))", "\(links.count) qualités")
                    } else {
                        logger.warn("LIVE", "⚠️ Luminous \(host) : playlist vide", "miroir suivant…")
                    }
                } else {
                    logger.warn("LIVE", "⚠️ Luminous \(host) échec (\(code))", "miroir suivant…")
                }
            } catch {
                logger.error("LIVE", "❌ Erreur Luminous \(host)", error.localizedDescription)
            }
        }
    }

    // 2 - Officiel Twitch
    if links.isEmpty && (sourcePref == "auto" || sourcePref == "twitch") {
        if let token = token {
            logger.info("LIVE", "Tentative Twitch officiel...")
            if login.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), !login.isEmpty,
               var comps = URLComponents(string: "https://usher.ttvnw.net/api/channel/hls/\(login).m3u8") {
            // Mode faible latence : Twitch sert alors la variante « low latency »
            // (segments plus courts, playlist rafraîchie plus souvent).
            let wantsLowLatency = UserDefaults.standard.bool(forKey: "cfg_low_latency")
            comps.queryItems = [
                .init(name: "allow_source",              value: "true"),
                .init(name: "allow_audio_only",           value: "true"),
                .init(name: "allow_spectre",              value: "true"),
                .init(name: "fast_bread",                 value: wantsLowLatency ? "true" : "false"),
                .init(name: "low_latency",                value: wantsLowLatency ? "true" : "false"),
                .init(name: "player_backend",             value: "mediaplayer"),
                .init(name: "playlist_include_framerate", value: "true"),
                .init(name: "segment_preference",         value: "4"),
                .init(name: "sig",                        value: token.signature),
                .init(name: "token",                      value: token.value),
            ]
            if wantsLowLatency { logger.info("LIVE", "Mode faible latence demandé à Twitch") }
            if let url = comps.url,
               let (data, resp) = try? await URLSession.shared.data(from: url),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let body = String(data: data, encoding: .utf8) {
                links = parseM3U8(body, baseURL: url)
                logger.success("LIVE", "✅ Twitch officiel : \(links.count) qualités")
            }
            }
        }
    }

    // 3 - Cloudflare Worker
    if links.isEmpty && (sourcePref == "auto" || sourcePref == "cloudflare") {
        logger.info("LIVE", "Tentative Cloudflare Worker...")
        if let url = URL(string: "\(kAPIURL)/api/get-live?name=\(login)&proxy=false"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let json2 = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let fbLinks = json2["links"] as? QualityLinks {
            links = fbLinks
            logger.success("LIVE", "✅ Cloudflare Worker : \(links.count) qualités")
        }
    }

    if let uid = userId {
        logger.success("LIVE", "userId récupéré : \(uid) → emotes canal disponibles")
    }

    return LiveData(title: title, game: game, thumbnail: thumbnail, avatar: avatar,
                    userId: userId, links: links, viewerCount: viewerCount,
                    startedAt: startedAt, dvrVideoId: dvrVideoId)
}

// MARK: – getStreamStats (rafraîchissement LÉGER viewers/uptime, sans re-fetch des liens)
func getStreamStats(channelName: String) async -> (viewerCount: Int, startedAt: Date?) {
    let login = channelName.trimmingCharacters(in: .whitespaces).lowercased()
    let q = "query { user(login: \"\(gqlStr(login))\") { stream { viewersCount createdAt } } }"
    guard let json   = try? await twitchGQL(q) as? [String: Any],
          let data   = json["data"]   as? [String: Any],
          let user   = data["user"]   as? [String: Any],
          let stream = user["stream"] as? [String: Any] else {
        return (0, nil)
    }
    let viewerCount = stream["viewersCount"] as? Int ?? 0
    var startedAt: Date? = nil
    if let createdAtStr = stream["createdAt"] as? String {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        startedAt = df.date(from: createdAtStr) ?? ISO8601DateFormatter().date(from: createdAtStr)
    }
    return (viewerCount, startedAt)
}

// MARK: – getChannelVideos
func getChannelVideos(channelName: String, cursor: String? = nil) async -> (videos: [VodData], avatar: String?, error: String?, cursor: String?) {
    logger.info("VIDEOS", "Chargement VODs de \"\(channelName)\"\(cursor != nil ? " (Page suivante)" : "")")

    let afterCursor = cursor != nil ? ", after: \"\(gqlStr(cursor!))\"" : ""
    let q = """
    query {
        user(login: "\(gqlStr(channelName))") {
            profileImageURL(width: 70)
            videos(first: 100, type: ARCHIVE, sort: TIME\(afterCursor)) {
                edges { cursor node { id title previewThumbnailURL(height: 180, width: 320) publishedAt lengthSeconds } }
                pageInfo { hasNextPage }
            }
        }
    }
    """

    guard let json = try? await twitchGQL(q) as? [String: Any],
          let data = json["data"] as? [String: Any],
          let user = data["user"] as? [String: Any] else {
        logger.error("VIDEOS", "Streamer \"\(channelName)\" introuvable")
        return (videos: [], avatar: nil, error: "Streamer introuvable", cursor: nil)
    }

    let avatar     = user["profileImageURL"] as? String
    let videosDict = user["videos"] as? [String: Any]
    let edges      = (videosDict?["edges"] as? [[String: Any]]) ?? []

    let videos: [VodData] = edges.compactMap { e in
        guard let node  = e["node"] as? [String: Any],
              let id    = node["id"] as? String,
              let title = node["title"] as? String else { return nil }
        return VodData(
            id: id, title: title,
            previewThumbnailURL: node["previewThumbnailURL"] as? String ?? "",
            publishedAt: node["publishedAt"] as? String ?? "",
            lengthSeconds: node["lengthSeconds"] as? Int ?? 0
        )
    }

    let pageInfo    = videosDict?["pageInfo"] as? [String: Any]
    let hasNextPage = pageInfo?["hasNextPage"] as? Bool ?? false
    let nextCursor  = hasNextPage ? (edges.last?["cursor"] as? String) : nil

    logger.success("VIDEOS", "\(videos.count) VODs trouvées pour \"\(channelName)\"")
    return (videos: videos, avatar: avatar, error: nil, cursor: nextCursor)
}

// MARK: – Couleur du pseudo (Helix)
/// Change la couleur du pseudo dans le chat.
///
/// Les commandes de modération et de compte (`/color`, `/ban`…) ont été
/// retirées de l'IRC par Twitch en 2023 : les envoyer en PRIVMSG renvoie
/// « Unrecognized command ». Tout passe maintenant par Helix.
///
/// Renvoie nil si tout s'est bien passé, sinon une clé de message d'erreur.
func setChatColor(token: String, userId: String, color: String) async -> String? {
    guard !userId.isEmpty,
          let url = URL(string: "https://api.twitch.tv/helix/chat/color?user_id=\(userId)&color=\(color)")
    else { return "color_bad_request" }

    var req = URLRequest(url: url)
    req.httpMethod = "PUT"
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(kHelixClientID, forHTTPHeaderField: "Client-Id")

    guard let (_, resp) = try? await URLSession.shared.data(for: req) else {
        return "color_network"
    }
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    switch code {
    case 204, 200:
        logger.success("CHAT", "Couleur du pseudo changée", color)
        return nil
    case 401:
        // Jeton émis avant l'ajout du scope user:manage:chat_color.
        logger.warn("CHAT", "Couleur refusée : scope manquant", "reconnexion nécessaire")
        return "color_needs_relogin"
    default:
        logger.warn("CHAT", "Couleur refusée", "HTTP \(code)")
        return "color_failed"
    }
}

// MARK: – Chatteurs
//  Il n'existe plus d'API publique pour lister les personnes présentes :
//    • tmi.twitch.tv/group/user/<canal>/chatters a été fermé en 2023 ;
//    • la requête GQL `channel { chatters }` répond « failed integrity check »,
//      elle exige un jeton signé obtenu par un défi JavaScript ;
//    • Helix /chat/chatters impose d'être modérateur du canal.
//  La liste est donc constituée depuis l'IRC (voir ChatService.presentUsers).

// MARK: – Helix
func getTwitchUser(token: String) async -> TwitchUser? {
    guard let url = URL(string: "https://api.twitch.tv/helix/users") else { return nil }
    var req = URLRequest(url: url)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(kHelixClientID, forHTTPHeaderField: "Client-Id")
    guard let (data, resp) = try? await URLSession.shared.data(for: req),
          (resp as? HTTPURLResponse)?.statusCode == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let arr  = json["data"] as? [[String: Any]], let u = arr.first else { return nil }
    logger.success("HELIX", "Connecté en tant que \"\(u["display_name"] as? String ?? "")\"")
    return TwitchUser(
        id: u["id"] as? String ?? "",
        login: u["login"] as? String ?? "",
        displayName: u["display_name"] as? String ?? "",
        profileImageURL: u["profile_image_url"] as? String ?? ""
    )
}

/// Photo de profil d'un pseudo du chat. Mise en cache pour la session : on la
/// redemanderait sinon à chaque message ouvert, pour une image qui ne bouge pas.
actor AvatarCache {
    static let shared = AvatarCache()
    private var cache: [String: String] = [:]

    func avatar(login: String, token: String?) async -> String? {
        let key = login.lowercased()
        guard !key.isEmpty else { return nil }
        if let hit = cache[key] { return hit.isEmpty ? nil : hit }

        // Sans compte Twitch, pas de Helix : la photo vient de l'API publique
        // (GQL). Avant, la fonction renvoyait nil et le bandeau du lecteur
        // restait sur un rond gris.
        guard let token,
              let url = URL(string: "https://api.twitch.tv/helix/users?login=\(key)") else {
            let img = await publicAvatar(login: key)
            if let img { cache[key] = img }
            return img
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(kHelixClientID, forHTTPHeaderField: "Client-Id")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr  = json["data"] as? [[String: Any]],
              let img  = arr.first?["profile_image_url"] as? String else {
            // Jeton expiré ou refusé : on tente encore l'API publique.
            let img = await publicAvatar(login: key)
            cache[key] = img ?? ""   // évite de re-tenter en boucle sur un compte disparu
            return img
        }
        cache[key] = img
        return img
    }

    private func publicAvatar(login: String) async -> String? {
        await getUserAvatarGQL(login: login)
    }
}

/// Photo de profil par l'API publique (sans compte).
func getUserAvatarGQL(login: String) async -> String? {
    let q = "query($l: String!) { user(login: $l) { profileImageURL(width: 150) } }"
    guard let d = await gqlRequest(q, ["l": login.lowercased()]),
          let user = d["user"] as? [String: Any],
          let img = user["profileImageURL"] as? String, !img.isEmpty else { return nil }
    return img
}

func getFollowedStreams(token: String, userId: String) async throws -> [TwitchStream] {
    guard let url = URL(string: "https://api.twitch.tv/helix/streams/followed?user_id=\(userId)&first=50") else { return [] }
    var req = URLRequest(url: url)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(kHelixClientID, forHTTPHeaderField: "Client-Id")
    let (data, resp) = try await URLSession.shared.data(for: req)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    // 401 distingué : l'accueil s'en sert pour déconnecter un jeton expiré
    // (le test sur le texte de l'erreur ne correspondait jamais).
    if status == 401 { throw URLError(.userAuthenticationRequired) }
    guard status == 200 else { throw URLError(.badServerResponse) }
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let arr  = json?["data"] as? [[String: Any]] ?? []
    logger.success("HELIX", "\(arr.count) streams suivis en direct")
    return arr.map { streamFromDict($0) }
}

func getTopStreams(token: String, lang: String? = nil) async throws -> [TwitchStream] {
    var urlStr = "https://api.twitch.tv/helix/streams?first=50"
    if let lang { urlStr += "&language=\(lang)" }
    guard let url = URL(string: urlStr) else { return [] }
    var req = URLRequest(url: url)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(kHelixClientID, forHTTPHeaderField: "Client-Id")
    let (data, _) = try await URLSession.shared.data(for: req)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let arr  = json?["data"] as? [[String: Any]] ?? []
    logger.success("HELIX", "\(arr.count) top streams chargés")
    return arr.map { streamFromDict($0) }
}

// MARK: – Catégories (Helix)
/// Top des catégories, triées par audience décroissante côté Twitch.
func getTopCategories(token: String, cursor: String? = nil) async throws -> (categories: [TwitchCategory], cursor: String?) {
    var urlStr = "https://api.twitch.tv/helix/games/top?first=100"
    if let cursor { urlStr += "&after=\(cursor)" }
    guard let url = URL(string: urlStr) else { return ([], nil) }
    var req = URLRequest(url: url)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(kHelixClientID, forHTTPHeaderField: "Client-Id")
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let arr  = json?["data"] as? [[String: Any]] ?? []
    let next = (json?["pagination"] as? [String: Any])?["cursor"] as? String
    logger.success("HELIX", "\(arr.count) catégories chargées")
    return (arr.map { categoryFromDict($0) }, arr.isEmpty ? nil : next)
}

/// Recherche de catégories par nom (barre de recherche de l'onglet Catégories).
func searchCategories(token: String, query: String) async throws -> [TwitchCategory] {
    // « & », « + », « = » encodés aussi : « Dungeons & Dragons » était coupé,
    // « C++ » devenait « C  ».
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&+=?#")
    let q = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    guard !q.isEmpty,
          let url = URL(string: "https://api.twitch.tv/helix/search/categories?first=50&query=\(q)")
    else { return [] }
    var req = URLRequest(url: url)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(kHelixClientID, forHTTPHeaderField: "Client-Id")
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let arr  = json?["data"] as? [[String: Any]] ?? []
    logger.success("HELIX", "\(arr.count) catégories pour « \(query) »")
    return arr.map { categoryFromDict($0) }
}

/// Lives d'une catégorie. Twitch les renvoie déjà par audience décroissante ;
/// les autres tris sont appliqués côté app (voir CategoriesView).
func getStreamsByCategory(token: String, gameId: String, cursor: String? = nil) async throws -> (streams: [TwitchStream], cursor: String?) {
    var urlStr = "https://api.twitch.tv/helix/streams?first=100&game_id=\(gameId)"
    if let cursor { urlStr += "&after=\(cursor)" }
    guard let url = URL(string: urlStr) else { return ([], nil) }
    var req = URLRequest(url: url)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(kHelixClientID, forHTTPHeaderField: "Client-Id")
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let arr  = json?["data"] as? [[String: Any]] ?? []
    let next = (json?["pagination"] as? [String: Any])?["cursor"] as? String
    logger.success("HELIX", "\(arr.count) lives dans la catégorie \(gameId)")
    return (arr.map { streamFromDict($0) }, arr.isEmpty ? nil : next)
}

/// Audience par catégorie, en une requête pour toute une page.
///
/// Helix ne la donne pas : `games/top` renvoie un classement, pas de chiffres.
/// GQL, lui, expose `viewersCount` par identifiant. Les champs sont aliasés
/// pour tenir dans un seul aller-retour — cent alias passent sans broncher —
/// et la requête ne demande aucun jeton d'intégrité, contrairement à
/// `channel { chatters }`.
///
/// Un échec n'est pas une erreur ici : la carte affiche simplement la
/// catégorie sans son audience.
func categoryViewers(ids: [String]) async -> [String: Int] {
    guard !ids.isEmpty else { return [:] }
    var out: [String: Int] = [:]

    for start in stride(from: 0, to: ids.count, by: 100) {
        let chunk = Array(ids[start ..< min(start + 100, ids.count)])
        let fields = chunk.enumerated()
            .map { "g\($0.offset): game(id: \"\(gqlStr($0.element))\") { id viewersCount }" }
            .joined(separator: " ")

        guard let json = try? await twitchGQL("query { \(fields) }") as? [String: Any],
              let data = json["data"] as? [String: Any] else { continue }

        for (_, value) in data {
            guard let game = value as? [String: Any],
                  let id    = game["id"] as? String,
                  let count = game["viewersCount"] as? Int else { continue }
            out[id] = count
        }
    }

    logger.success("GQL", "\(out.count) audiences de catégories sur \(ids.count)")
    return out
}

private func categoryFromDict(_ d: [String: Any]) -> TwitchCategory {
    // 570×760, soit le double de la taille de référence de Twitch. La grille
    // fait deux colonnes : une jaquette y occupe environ 170 pt, donc plus de
    // 500 px sur un écran ×3. À 144×192 l'image était agrandie quatre fois et
    // sortait floue. Le CDN sert la taille demandée telle quelle, sans
    // agrandissement de son côté.
    let raw = (d["box_art_url"] as? String ?? "")
        .replacingOccurrences(of: "{width}",  with: "570")
        .replacingOccurrences(of: "{height}", with: "760")
    return TwitchCategory(
        id:   d["id"]   as? String ?? UUID().uuidString,
        name: d["name"] as? String ?? "",
        boxArtURL: raw
    )
}

private func streamFromDict(_ d: [String: Any]) -> TwitchStream {
    TwitchStream(
        id: d["user_id"] as? String ?? UUID().uuidString,
        userLogin: d["user_login"] as? String ?? "",
        userName:  d["user_name"]  as? String ?? "",
        title:     d["title"]      as? String ?? "",
        gameName:  d["game_name"]  as? String ?? "",
        viewerCount: d["viewer_count"] as? Int ?? 0,
        thumbnailURL: d["thumbnail_url"] as? String ?? ""
    )
}

// MARK: – Autocomplete GQL
func searchUsersGQL(_ query: String) async -> [AutocompleteSuggestion] {
    // `stream` : présent seulement si la chaîne est en live (pastille dans la liste).
    let q = "query($q: String!) { searchUsers(userQuery: $q, first: 5) { edges { node { login displayName profileImageURL(width: 70) stream { viewersCount game { displayName } } } } } }"
    guard let data = await gqlRequest(q, ["q": query]),
          let edges = (data["searchUsers"] as? [String: Any])?["edges"] as? [[String: Any]] else { return [] }
    let list: [AutocompleteSuggestion] = edges.compactMap { e in
        guard let node  = e["node"] as? [String: Any],
              let login = node["login"] as? String else { return nil }
        let stream = node["stream"] as? [String: Any]
        return AutocompleteSuggestion(login: login,
                                      name: node["displayName"] as? String ?? login,
                                      avatar: node["profileImageURL"] as? String,
                                      viewers: stream.map { $0["viewersCount"] as? Int ?? 0 },
                                      game: (stream?["game"] as? [String: Any])?["displayName"] as? String)
    }
    // Les chaînes en live d'abord, sans changer l'ordre de Twitch entre elles.
    return list.filter(\.isLive) + list.filter { !$0.isLive }
}

func getVodMetaGQL(_ vodId: String) async -> VodMeta? {
    let q = "query { video(id: \"\(gqlStr(vodId))\") { title lengthSeconds viewCount owner { displayName } previewThumbnailURL(height: 180, width: 320) } }"
    guard let json = try? await twitchGQL(q) as? [String: Any],
          let data = json["data"] as? [String: Any],
          let v    = data["video"] as? [String: Any],
          let title = v["title"] as? String else { return nil }
    return VodMeta(
        title: title,
        streamer: (v["owner"] as? [String: Any])?["displayName"] as? String ?? "Inconnu",
        thumb: v["previewThumbnailURL"] as? String ?? "",
        lengthSeconds: v["lengthSeconds"] as? Int ?? 0,
        viewCount: v["viewCount"] as? Int ?? 0
    )
}

// MARK: – Utilities
func extractVodId(_ input: String) -> String? {
    let pattern = #"\d{8,}"#
    guard let range = input.range(of: pattern, options: .regularExpression) else { return nil }
    return String(input[range])
}

func formatViewers(_ count: Int) -> String {
    count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : "\(count)"
}

func formatDuration(_ seconds: Int) -> String {
    let h = seconds / 3600, m = (seconds % 3600) / 60
    return h > 0 ? "\(h)h \(m)min" : "\(m)min"
}

/// Twitch date ses VODs sans fractions de seconde et ses lives avec : on
/// accepte les deux formats.
private func parseTwitchDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    let df = ISO8601DateFormatter()
    df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return df.date(from: s) ?? ISO8601DateFormatter().date(from: s)
}

/// Fin du dernier live : la dernière VOD (début + durée) ou, si plus tard, le
/// dernier live lancé (un live sans VOD n'en laisse pas).
func lastLiveEnd(publishedAt: String?, lengthSeconds: Int, lastStart: String?) -> Date? {
    let fromVod = parseTwitchDate(publishedAt)?.addingTimeInterval(TimeInterval(lengthSeconds))
    let started = parseTwitchDate(lastStart)
    switch (fromVod, started) {
    case let (a?, b?): return max(a, b)
    case let (a?, nil): return a
    case let (nil, b?): return b
    default: return nil
    }
}

/// « 13 d · 21 sept. » : durée dans la langue de l'app, puis la date (avec
/// l'année si ce n'est pas celle en cours).
func offlineLabel(since end: Date, store: AppStore) -> String {
    let diff = Date().timeIntervalSince(end)
    guard diff > 0 else { return "" }
    let days = Int(diff / 86400), hours = Int(diff / 3600), minutes = Int(diff / 60)
    let span = days > 0 ? "\(days) \(store.t("day"))"
             : hours > 0 ? "\(hours) \(store.t("hour"))"
             : "\(minutes) \(store.t("min"))"
    let df = DateFormatter()
    df.locale = Locale(identifier: store.lang.rawValue)
    let sameYear = Calendar.current.component(.year, from: end) == Calendar.current.component(.year, from: Date())
    df.setLocalizedDateFormatFromTemplate(sameYear ? "d MMM" : "d MMM y")
    return "\(span) · \(df.string(from: end))"
}

func sortQualities(_ keys: [String]) -> [String] {
    let order = ["Source","chunked","source","1080p60","1080p30","1080p","720p60","720p30","720p",
                 "480p60","480p30","480p","360p30","360p","160p30","160p","audio_only"]
    return keys.sorted { a, b in
        let ai = order.firstIndex { a.lowercased().contains($0.lowercased()) || $0.lowercased().contains(a.lowercased()) } ?? 999
        let bi = order.firstIndex { b.lowercased().contains($0.lowercased()) || $0.lowercased().contains(b.lowercased()) } ?? 999
        return ai < bi
    }
}

// MARK: – Validité de la session web
/// La session web (cookie `auth-token`) n'a pas de date d'expiration connue :
/// elle meurt quand Twitch le décide — déconnexion ailleurs, changement de mot
/// de passe, révocation. Sans vérification, on s'en aperçoit seulement quand
/// les points de chaîne cessent silencieusement de répondre.
///
/// Renvoie `false` uniquement quand Twitch dit explicitement que le jeton ne
/// vaut rien : une panne réseau laisse la session en place, la couper sur un
/// wifi capricieux serait pire que le mal.
func isWebSessionValid(token: String) async -> Bool {
    guard !token.isEmpty, let url = URL(string: "https://gql.twitch.tv/gql") else { return false }

    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue(kGQLClientID,       forHTTPHeaderField: "Client-ID")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("OAuth \(token)",   forHTTPHeaderField: "Authorization")
    req.httpBody = try? JSONSerialization.data(
        withJSONObject: ["query": "query { currentUser { id login } }"])

    guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
        logger.debug("AUTH/WEB", "Vérification impossible", "réseau — session conservée")
        return true
    }
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code == 401 || code == 403 {
        logger.warn("AUTH/WEB", "Session web expirée", "HTTP \(code)")
        return false
    }
    guard code == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let payload = json["data"] as? [String: Any] else {
        return true   // réponse inattendue : on ne tranche pas
    }
    // `currentUser` à null = jeton rejeté, même avec un HTTP 200.
    if payload["currentUser"] is NSNull || payload["currentUser"] == nil {
        logger.warn("AUTH/WEB", "Session web expirée", "currentUser vide")
        return false
    }
    logger.debug("AUTH/WEB", "Session web valide", nil)
    return true
}

// MARK: – Photo de profil d'une chaîne
/// L'avatar du bandeau du lecteur. En direct, `getLive` le ramène déjà ; pour
/// une VOD il n'était jamais demandé, d'où le rond gris. On passe par le cache
/// partagé avec la feuille de message : une requête par chaîne et par session.
func channelAvatar(login: String, token: String?) async -> String? {
    await AvatarCache.shared.avatar(login: login, token: token)
}

/// Texte rendu sûr pour une chaîne GQL entre guillemets. Sans cela, un `"`
/// tapé dans la recherche (ou venu de l'historique synchronisé) cassait la
/// requête ou permettait d'en réécrire le contenu.
func gqlStr(_ s: String) -> String {
    var out = ""
    for ch in s.unicodeScalars {
        switch ch {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n", "\r", "\t": out += " "
        default:
            if ch.value >= 0x20 { out.unicodeScalars.append(ch) }
        }
    }
    return out
}

// MARK: – Clips
/// Requête GQL avec variables (les valeurs ne sont jamais collées dans le texte).
private func gqlRequest(_ query: String, _ variables: [String: Any]) async -> [String: Any]? {
    guard let url = URL(string: "https://gql.twitch.tv/gql"),
          let body = try? JSONSerialization.data(withJSONObject: ["query": query, "variables": variables]) else { return nil }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue(kGQLClientID, forHTTPHeaderField: "Client-ID")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = body
    guard let (data, _) = try? await URLSession.shared.data(for: req),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return json["data"] as? [String: Any]
}

// MARK: – Lives sans compte (GQL public)
private func streamFromGQL(user u: [String: Any], stream s: [String: Any]) -> TwitchStream? {
    guard let login = u["login"] as? String else { return nil }
    return TwitchStream(
        id: u["id"] as? String ?? login,
        userLogin: login,
        userName: u["displayName"] as? String ?? login,
        title: s["title"] as? String ?? "",
        gameName: (s["game"] as? [String: Any])?["displayName"] as? String ?? "",
        viewerCount: s["viewersCount"] as? Int ?? 0,
        thumbnailURL: s["previewImageURL"] as? String ?? "")
}

/// Lesquelles de ces chaînes sont en live (suivis sans compte). 100 max par requête.
/// nil si Twitch n'a pas répondu (réseau, requête annulée) : à ne pas
/// confondre avec « personne en live », sinon la liste se viderait.
func getLiveStreamsGQL(logins: [String]) async -> [TwitchStream]? {
    guard !logins.isEmpty else { return [] }
    let q = """
    query($l: [String!]) { users(logins: $l) { id login displayName
      stream { title viewersCount previewImageURL(width: 440, height: 248) game { displayName } } } }
    """
    var out: [TwitchStream] = []
    for start in stride(from: 0, to: logins.count, by: 100) {
        let chunk = Array(logins[start..<min(start + 100, logins.count)])
        guard let d = await gqlRequest(q, ["l": chunk]),
              let users = d["users"] as? [Any] else { return nil }
        for case let u as [String: Any] in users {
            if let s = u["stream"] as? [String: Any], let st = streamFromGQL(user: u, stream: s) { out.append(st) }
        }
    }
    return out.sorted { $0.viewerCount > $1.viewerCount }
}

// MARK: – Chaînes suivies (en live ou non)
/// Une chaîne suivie : son live s'il y en a un, sinon de quoi ouvrir sa page.
struct ChannelBrief: Identifiable {
    let login: String
    let name: String
    let avatar: String
    let stream: TwitchStream?
    /// Fin du dernier live connu (pour « hors ligne depuis »).
    var lastEnd: Date? = nil
    var id: String { login }
}

/// Infos de ces chaînes (avatar, live éventuel) par GQL public, 100 par requête.
/// nil si Twitch n'a pas répondu, pour ne pas vider une liste affichée.
func getChannelsGQL(logins: [String]) async -> [ChannelBrief]? {
    guard !logins.isEmpty else { return [] }
    let q = """
    query($l: [String!]) { users(logins: $l) { id login displayName profileImageURL(width: 70)
      lastBroadcast { startedAt }
      videos(first: 1, type: ARCHIVE, sort: TIME) { edges { node { publishedAt lengthSeconds } } }
      stream { title viewersCount previewImageURL(width: 440, height: 248) game { displayName } } } }
    """
    var out: [ChannelBrief] = []
    for start in stride(from: 0, to: logins.count, by: 100) {
        let chunk = Array(logins[start..<min(start + 100, logins.count)])
        guard let d = await gqlRequest(q, ["l": chunk]),
              let users = d["users"] as? [Any] else { return nil }
        for case let u as [String: Any] in users {
            guard let login = u["login"] as? String else { continue }
            let stream = (u["stream"] as? [String: Any]).flatMap { streamFromGQL(user: u, stream: $0) }
            let video = ((u["videos"] as? [String: Any])?["edges"] as? [[String: Any]])?.first?["node"] as? [String: Any]
            let lastEnd = lastLiveEnd(publishedAt: video?["publishedAt"] as? String,
                                      lengthSeconds: video?["lengthSeconds"] as? Int ?? 0,
                                      lastStart: (u["lastBroadcast"] as? [String: Any])?["startedAt"] as? String)
            out.append(ChannelBrief(login: login, name: u["displayName"] as? String ?? login,
                                    avatar: u["profileImageURL"] as? String ?? "", stream: stream,
                                    lastEnd: lastEnd))
        }
    }
    return out
}

/// Toutes les chaînes suivies par le compte (Helix, pages de 100, 1 000 au plus).
func getFollowedLogins(token: String, userId: String) async -> [String]? {
    var logins: [String] = []
    var cursor: String? = nil
    repeat {
        var urlStr = "https://api.twitch.tv/helix/channels/followed?user_id=\(userId)&first=100"
        if let cursor { urlStr += "&after=\(cursor)" }
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(kHelixClientID, forHTTPHeaderField: "Client-Id")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for f in json["data"] as? [[String: Any]] ?? [] {
            if let l = f["broadcaster_login"] as? String { logins.append(l) }
        }
        cursor = (json["pagination"] as? [String: Any])?["cursor"] as? String
    } while cursor != nil && logins.count < 1000
    return logins
}

// MARK: – Catégories suivies (compte Twitch, session web)
/// Catégories suivies sur Twitch. Demande la session web (cookie auth-token) :
/// Helix n'a pas d'équivalent. nil si indisponible.
func getFollowedCategoriesGQL(webToken: String) async -> [TwitchCategory]? {
    guard let url = URL(string: "https://gql.twitch.tv/gql") else { return nil }
    let q = """
    query { currentUser { followedGames(first: 100, type: ALL) { nodes { id displayName boxArtURL(width: 285, height: 380) viewersCount } } } }
    """
    guard let body = try? JSONSerialization.data(withJSONObject: ["query": q]) else { return nil }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue(kGQLClientID, forHTTPHeaderField: "Client-ID")
    req.setValue("OAuth \(webToken)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = body
    guard let (data, _) = try? await URLSession.shared.data(for: req),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let nodes = (((json["data"] as? [String: Any])?["currentUser"] as? [String: Any])?["followedGames"] as? [String: Any])?["nodes"] as? [[String: Any]]
    else { return nil }
    return nodes.compactMap { n in
        guard let id = n["id"] as? String else { return nil }
        return TwitchCategory(id: id, name: n["displayName"] as? String ?? "",
                              boxArtURL: n["boxArtURL"] as? String ?? "",
                              viewers: n["viewersCount"] as? Int)
    }
}

/// Identifiant Twitch d'une chaîne (GQL public).
func getUserIdGQL(login: String) async -> String? {
    let d = await gqlRequest("query($l: String!) { user(login: $l) { id } }", ["l": login.lowercased()])
    return (d?["user"] as? [String: Any])?["id"] as? String
}

/// Top des lives sans jeton (GQL public) ; `lang` au format Helix (« fr », « zh-hk »).
func getTopStreamsGQL(lang: String?) async -> [TwitchStream] {
    let q = """
    query($n: Int!, $langs: [Language!]) { streams(first: $n, options: { broadcasterLanguages: $langs }) {
      edges { node { title viewersCount previewImageURL(width: 440, height: 248) game { displayName }
        broadcaster { id login displayName } } } } }
    """
    var vars: [String: Any] = ["n": 30]   // Twitch refuse au-delà de 30
    if let lang { vars["langs"] = [lang.uppercased().replacingOccurrences(of: "-", with: "_")] }
    guard let d = await gqlRequest(q, vars),
          let edges = (d["streams"] as? [String: Any])?["edges"] as? [[String: Any]] else { return [] }
    return edges.compactMap { e in
        guard let n = e["node"] as? [String: Any], let b = n["broadcaster"] as? [String: Any] else { return nil }
        return streamFromGQL(user: b, stream: n)
    }
}

/// Clips les plus vus d'une chaîne sur la période (LAST_DAY, LAST_WEEK, LAST_MONTH, ALL_TIME).
func getClips(login: String, period: String) async -> [ClipData] {
    let q = """
    query($l: String!, $p: ClipsPeriod) { user(login: $l) { clips(first: 30, criteria: { period: $p, sort: VIEWS_DESC }) {
      edges { node { slug title viewCount durationSeconds createdAt thumbnailURL(width: 480, height: 272) curator { displayName } } }
    } } }
    """
    guard let d = await gqlRequest(q, ["l": login.lowercased(), "p": period]),
          let user = d["user"] as? [String: Any],
          let clips = user["clips"] as? [String: Any],
          let edges = clips["edges"] as? [[String: Any]] else { return [] }
    return edges.compactMap { e in
        guard let n = e["node"] as? [String: Any], let slug = n["slug"] as? String else { return nil }
        return ClipData(id: slug,
                        title: n["title"] as? String ?? "",
                        thumbnailURL: n["thumbnailURL"] as? String ?? "",
                        viewCount: n["viewCount"] as? Int ?? 0,
                        durationSeconds: n["durationSeconds"] as? Int ?? 0,
                        createdAt: n["createdAt"] as? String ?? "",
                        curator: (n["curator"] as? [String: Any])?["displayName"] as? String)
    }
}

/// Highlights d'une chaîne (les 50 plus récents).
func getHighlights(login: String) async -> [VodData] {
    let q = """
    query($l: String!) { user(login: $l) { videos(first: 50, type: HIGHLIGHT, sort: TIME) {
      edges { node { id title lengthSeconds createdAt previewThumbnailURL(width: 320, height: 180) } }
    } } }
    """
    guard let d = await gqlRequest(q, ["l": login.lowercased()]),
          let user = d["user"] as? [String: Any],
          let videos = user["videos"] as? [String: Any],
          let edges = videos["edges"] as? [[String: Any]] else { return [] }
    return edges.compactMap { e in
        guard let v = e["node"] as? [String: Any], let id = v["id"] as? String else { return nil }
        return VodData(id: id,
                       title: v["title"] as? String ?? "",
                       previewThumbnailURL: v["previewThumbnailURL"] as? String ?? "",
                       publishedAt: v["createdAt"] as? String ?? "",
                       lengthSeconds: v["lengthSeconds"] as? Int ?? 0)
    }
}

/// Playlists (collections) d'une chaîne, avec leurs vidéos — vides exclues.
func getCollections(login: String) async -> [PlaylistData] {
    let q = """
    query($l: String!) { user(login: $l) { collections(first: 20) { edges { node {
      id title description
      items(first: 50) { totalCount edges { node { ... on Video {
        id title lengthSeconds createdAt previewThumbnailURL(width: 320, height: 180)
      } } } }
    } } } }
    """
    guard let d = await gqlRequest(q, ["l": login.lowercased()]),
          let user = d["user"] as? [String: Any],
          let cols = user["collections"] as? [String: Any],
          let edges = cols["edges"] as? [[String: Any]] else { return [] }
    return edges.compactMap { e -> PlaylistData? in
        guard let n = e["node"] as? [String: Any], let id = n["id"] as? String,
              let items = n["items"] as? [String: Any] else { return nil }
        let videos: [VodData] = (items["edges"] as? [[String: Any]] ?? []).compactMap { ie in
            guard let v = ie["node"] as? [String: Any], let vid = v["id"] as? String else { return nil }
            return VodData(id: vid,
                           title: v["title"] as? String ?? "",
                           previewThumbnailURL: v["previewThumbnailURL"] as? String ?? "",
                           publishedAt: v["createdAt"] as? String ?? "",
                           lengthSeconds: v["lengthSeconds"] as? Int ?? 0)
        }
        guard !videos.isEmpty else { return nil }
        return PlaylistData(id: id,
                            title: n["title"] as? String ?? "",
                            description: n["description"] as? String ?? "",
                            total: items["totalCount"] as? Int ?? videos.count,
                            videos: videos)
    }
}

/// MP4 signés d'un clip (lus directement par AVPlayer) et sa VOD d'origine.
func getClip(slug: String) async -> ClipPlayback? {
    let q = """
    query($s: ID!) { clip(slug: $s) {
      title broadcaster { login displayName } video { id } videoOffsetSeconds
      playbackAccessToken(params: { platform: "web", playerType: "site", playerBackend: "mediaplayer" }) { signature value }
      videoQualities { quality frameRate sourceURL }
    } }
    """
    guard let d = await gqlRequest(q, ["s": slug]),
          let c = d["clip"] as? [String: Any],
          let tok = c["playbackAccessToken"] as? [String: Any],
          let sig = tok["signature"] as? String, let value = tok["value"] as? String,
          let qualities = c["videoQualities"] as? [[String: Any]] else { return nil }
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&+=?#")
    let token = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    var links: QualityLinks = [:]
    for qd in qualities {
        guard let src = qd["sourceURL"] as? String, src.hasPrefix("https://") else { continue }
        let fps = (qd["frameRate"] as? Double) ?? Double(qd["frameRate"] as? Int ?? 30)
        let label = "\(qd["quality"] as? String ?? "?")p\(fps >= 50 ? String(Int(fps.rounded())) : "")"
        links[label] = src + (src.contains("?") ? "&" : "?") + "sig=\(sig)&token=\(token)"
    }
    guard !links.isEmpty else { return nil }
    let b = c["broadcaster"] as? [String: Any]
    let vodId = (c["video"] as? [String: Any])?["id"] as? String
    let offset = (c["videoOffsetSeconds"] as? Double) ?? (c["videoOffsetSeconds"] as? Int).map(Double.init)
    return ClipPlayback(links: links, title: c["title"] as? String ?? "Clip",
                        broadcasterLogin: b?["login"] as? String,
                        broadcasterName: b?["displayName"] as? String,
                        vodId: vodId, vodOffset: offset)
}

// MARK: – Chapitres de VOD
/// Changements de jeu d'une VOD (repères sur la barre de lecture).
func getVodChapters(vodId: String) async -> [VodChapter] {
    let q = """
    query($id: ID!) { video(id: $id) { moments(first: 50, momentRequestType: VIDEO_CHAPTER_MARKERS) {
      edges { node { positionMilliseconds durationMilliseconds description } }
    } } }
    """
    guard let d = await gqlRequest(q, ["id": vodId]),
          let v = d["video"] as? [String: Any],
          let m = v["moments"] as? [String: Any],
          let edges = m["edges"] as? [[String: Any]] else { return [] }
    let chapters: [VodChapter] = edges.compactMap { e in
        guard let n = e["node"] as? [String: Any] else { return nil }
        let pos = (n["positionMilliseconds"] as? Double) ?? Double(n["positionMilliseconds"] as? Int ?? 0)
        let dur = (n["durationMilliseconds"] as? Double) ?? Double(n["durationMilliseconds"] as? Int ?? 0)
        return VodChapter(start: pos / 1000, duration: dur / 1000, title: n["description"] as? String ?? "")
    }
    // Un seul chapitre n'apporte rien (toute la VOD sur le même jeu).
    return chapters.count > 1 ? chapters.sorted { $0.start < $1.start } : []
}
