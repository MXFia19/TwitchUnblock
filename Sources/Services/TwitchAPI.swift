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
        ? "query { streamPlaybackAccessToken(channelName: \"\(id)\", params: {platform: \"web\", playerBackend: \"mediaplayer\", playerType: \"site\"}) { value signature } }"
        : "query { videoPlaybackAccessToken(id: \"\(id)\", params: {platform: \"web\", playerBackend: \"mediaplayer\", playerType: \"site\"}) { value signature } }"
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
private func storyboardHack(vodId: String) async -> QualityLinks {
    logger.info("STORYBOARD", "Tentative storyboard hack pour VOD \(vodId)")
    guard let json = try? await twitchGQL("query { video(id: \"\(vodId)\") { seekPreviewsURL } }") as? [String: Any],
          let data = json["data"] as? [String: Any],
          let video = data["video"] as? [String: Any],
          let seekUrl = video["seekPreviewsURL"] as? String,
          let parsedURL = URL(string: seekUrl) else {
        logger.warn("STORYBOARD", "seekPreviewsURL absent")
        return [:]
    }
    let parts = seekUrl.components(separatedBy: "/")
    guard let storyIndex = parts.firstIndex(of: "storyboards"), storyIndex > 0 else {
        logger.warn("STORYBOARD", "Structure URL inattendue")
        return [:]
    }
    let hash = parts[storyIndex - 1]
    let root = "https://\(parsedURL.host!)/\(hash)"

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
        var comps = URLComponents(string: "https://usher.ttvnw.net/vod/\(vodId).m3u8")!
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

    let q = """
    query { user(login: "\(login)") {
        profileImageURL(width: 70)
        stream { title game { name } previewImageURL(width: 320, height: 180) viewersCount createdAt }
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
    guard let stream = user["stream"] as? [String: Any] else {
        logger.warn("LIVE", "\"\(login)\" est hors ligne")
        return LiveData(title: "Hors ligne", game: "", thumbnail: "", avatar: avatar, error: "offline")
    }

    let title     = stream["title"] as? String ?? ""
    let game      = (stream["game"] as? [String: Any])?["name"] as? String ?? ""
    let thumbnail = stream["previewImageURL"] as? String ?? ""
    let viewerCount = stream["viewersCount"] as? Int ?? 0

    // Parse startedAt ISO8601
    var startedAt: Date? = nil
    if let createdAtStr = stream["createdAt"] as? String {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        startedAt = df.date(from: createdAtStr) ?? ISO8601DateFormatter().date(from: createdAtStr)
    }

    var links: QualityLinks = [:]

    // ✨ RÉCUPÉRATION DU CHOIX DE L'UTILISATEUR
    let sourcePref = UserDefaults.standard.string(forKey: "liveSource") ?? "auto"
    logger.info("LIVE", "Source sélectionnée : \(sourcePref.uppercased())")

    // ✨ 1 - TENTATIVE LUMINOUS
    if sourcePref == "auto" || sourcePref == "luminous" {
        logger.info("LIVE", "Tentative Luminous (Sans Pub)...")
        var lumComps = URLComponents(string: "https://as.luminous.dev/live/\(login)")!
        lumComps.queryItems = [
            .init(name: "allow_source", value: "true"),
            .init(name: "allow_audio_only", value: "true"),
            .init(name: "fast_bread", value: "true")
        ]
        
        if let lumUrl = lumComps.url {
            var req = URLRequest(url: lumUrl)
            requestHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let httpResp = resp as? HTTPURLResponse {
                    if httpResp.statusCode == 200 {
                        if let body = String(data: data, encoding: .utf8) {
                            links = parseM3U8(body, baseURL: lumUrl)
                            if !links.isEmpty {
                                logger.success("LIVE", "✅ Luminous OK (Aucune Pub) : \(links.count) qualités")
                            }
                        }
                    } else {
                        logger.warn("LIVE", "⚠️ Luminous a échoué (Erreur \(httpResp.statusCode)).")
                    }
                }
            } catch {
                logger.error("LIVE", "❌ Erreur réseau avec Luminous (\(error.localizedDescription)).")
            }
        }
    }

    // ✨ 2 - FALLBACK OFFICIEL TWITCH (Avec pub)
    if links.isEmpty && (sourcePref == "auto" || sourcePref == "twitch") {
        if let token = token {
            logger.info("LIVE", "Tentative sur le serveur officiel Twitch...")
            var comps = URLComponents(string: "https://usher.ttvnw.net/api/channel/hls/\(login).m3u8")!
            comps.queryItems = [
                .init(name: "allow_source",               value: "true"),
                .init(name: "allow_audio_only",            value: "true"),
                .init(name: "allow_spectre",               value: "true"),
                .init(name: "player_backend",              value: "mediaplayer"),
                .init(name: "playlist_include_framerate",  value: "true"),
                .init(name: "segment_preference",          value: "4"),
                .init(name: "sig",                         value: token.signature),
                .init(name: "token",                       value: token.value),
            ]
            if let url = comps.url,
               let (data, resp) = try? await URLSession.shared.data(from: url),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let body = String(data: data, encoding: .utf8) {
                links = parseM3U8(body, baseURL: url)
                logger.success("LIVE", "✅ Serveur Officiel Twitch OK : \(links.count) qualités HLS")
            }
        }
    }

    // ✨ 3 - FALLBACK FINAL CLOUDFLARE WORKER
    if links.isEmpty && (sourcePref == "auto" || sourcePref == "cloudflare") {
        logger.info("LIVE", "Tentative sur le Cloudflare Proxy...")
        if let url = URL(string: "\(kAPIURL)/api/get-live?name=\(login)&proxy=false"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let json2 = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let fbLinks = json2["links"] as? QualityLinks {
            links = fbLinks
            logger.success("LIVE", "✅ Fallback Cloudflare Worker OK : \(links.count) qualités")
        }
    }

    return LiveData(title: title, game: game, thumbnail: thumbnail, avatar: avatar, links: links, viewerCount: viewerCount, startedAt: startedAt)
}

// MARK: – getChannelVideos
func getChannelVideos(channelName: String, cursor: String? = nil) async -> (videos: [VodData], avatar: String?, error: String?, cursor: String?) {
    logger.info("VIDEOS", "Chargement VODs de \"\(channelName)\"\(cursor != nil ? " (Page suivante)" : "")")
    
    let afterCursor = cursor != nil ? ", after: \"\(cursor!)\"" : ""
    let q = """
    query {
        user(login: "\(channelName)") {
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
    
    let avatar = user["profileImageURL"] as? String
    let videosDict = user["videos"] as? [String: Any]
    let edges  = (videosDict?["edges"] as? [[String: Any]]) ?? []
    
    let videos: [VodData] = edges.compactMap { e in
        guard let node = e["node"] as? [String: Any],
              let id   = node["id"] as? String,
              let title = node["title"] as? String else { return nil }
        return VodData(
            id: id, title: title,
            previewThumbnailURL: node["previewThumbnailURL"] as? String ?? "",
            publishedAt: node["publishedAt"] as? String ?? "",
            lengthSeconds: node["lengthSeconds"] as? Int ?? 0
        )
    }
    
    let pageInfo = videosDict?["pageInfo"] as? [String: Any]
    let hasNextPage = pageInfo?["hasNextPage"] as? Bool ?? false
    let nextCursor = hasNextPage ? (edges.last?["cursor"] as? String) : nil
    
    logger.success("VIDEOS", "\(videos.count) VODs trouvées pour \"\(channelName)\"")
    return (videos: videos, avatar: avatar, error: nil, cursor: nextCursor)
}

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

func getFollowedStreams(token: String, userId: String) async throws -> [TwitchStream] {
    guard let url = URL(string: "https://api.twitch.tv/helix/streams/followed?user_id=\(userId)&first=50") else { return [] }
    var req = URLRequest(url: url)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(kHelixClientID, forHTTPHeaderField: "Client-Id")
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
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
    let q = "query { searchUsers(userQuery: \"\(query)\", first: 5) { edges { node { login displayName profileImageURL(width: 70) } } } }"
    guard let json = try? await twitchGQL(q) as? [String: Any],
          let data = json["data"] as? [String: Any],
          let edges = (data["searchUsers"] as? [String: Any])?["edges"] as? [[String: Any]] else { return [] }
    return edges.compactMap { e in
        guard let node = e["node"] as? [String: Any],
              let login = node["login"] as? String else { return nil }
        return AutocompleteSuggestion(login: login, name: node["displayName"] as? String ?? login, avatar: node["profileImageURL"] as? String)
    }
}

func getVodMetaGQL(_ vodId: String) async -> VodMeta? {
    let q = "query { video(id: \"\(vodId)\") { title owner { displayName } previewThumbnailURL(height: 180, width: 320) } }"
    guard let json = try? await twitchGQL(q) as? [String: Any],
          let data = json["data"] as? [String: Any],
          let v = data["video"] as? [String: Any],
          let title = v["title"] as? String else { return nil }
    return VodMeta(
        title: title,
        streamer: (v["owner"] as? [String: Any])?["displayName"] as? String ?? "Inconnu",
        thumb: v["previewThumbnailURL"] as? String ?? ""
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

func getTimeSince(publishedAt: String, lengthSeconds: Int, store: AppStore) -> String {
    let df = ISO8601DateFormatter()
    df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let startDate = df.date(from: publishedAt) else { return "" }
    let endDate = startDate.addingTimeInterval(TimeInterval(lengthSeconds))
    let diff = Date().timeIntervalSince(endDate)
    guard diff > 0 else { return "" }
    let days = Int(diff / 86400), hours = Int(diff / 3600), minutes = Int(diff / 60)
    if days > 0    { return "\(days) \(store.t("day"))" }
    if hours > 0   { return "\(hours) \(store.t("hour"))" }
    return "\(minutes) \(store.t("min"))"
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
