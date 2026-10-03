import Foundation

// MARK: – Badge cache (global + par canal)
actor BadgeService {
    static let shared = BadgeService()
    private init() {}

    // [setId: [version: imageUrl2x]]
    private var global:  [String: [String: String]] = [:]
    private var channel: [String: [String: [String: String]]] = [:]   // channelId → setId → version → url
    private var globalsLoaded = false
    private var loadedChannels: Set<String> = []

    /// Vide les badges chargés pour forcer un rechargement complet.
    func reset() {
        global.removeAll()
        channel.removeAll()
        globalsLoaded = false
        loadedChannels.removeAll()
    }

    // MARK: – Load global badges (Helix)
    func loadGlobal(token: String?) async {
        guard !globalsLoaded else { return }
        guard let token, !token.isEmpty,
              let url = URL(string: "https://api.twitch.tv/helix/chat/badges/global") else {
            await loadGlobalPublic(); return
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)",  forHTTPHeaderField: "Authorization")
        req.setValue(kHelixClientID,      forHTTPHeaderField: "Client-Id")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sets = json["data"] as? [[String: Any]] else { await loadGlobalPublic(); return }

        global = parseSets(sets)
        globalsLoaded = true
        logger.success("BADGES", "Badges globaux chargés", "\(global.count) sets")
    }

    // MARK: – Load channel badges (Helix — badges sub perso, bits, etc.)
    func loadChannel(channelId: String, token: String?) async {
        guard !loadedChannels.contains(channelId) else { return }
        loadedChannels.insert(channelId)

        guard let token, !token.isEmpty, let url = URL(string:
            "https://api.twitch.tv/helix/chat/badges?broadcaster_id=\(channelId)"
        ) else { await loadChannelPublic(channelId: channelId); return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)",  forHTTPHeaderField: "Authorization")
        req.setValue(kHelixClientID,      forHTTPHeaderField: "Client-Id")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sets = json["data"] as? [[String: Any]] else {
            await loadChannelPublic(channelId: channelId); return
        }

        channel[channelId] = parseSets(sets)
        logger.success("BADGES", "Badges canal \(channelId) chargés",
                       "\(channel[channelId]?.count ?? 0) sets")
    }

    // MARK: – Repli public (GQL, sans connexion)
    // Helix exige un jeton : sans compte (ou jeton refusé), les badges
    // restaient introuvables et laissaient un trou devant chaque pseudo.
    private func gqlBadges(_ query: String, _ variables: [String: Any]) async -> [String: Any]? {
        guard let url = URL(string: "https://gql.twitch.tv/gql"),
              let body = try? JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(kGQLClientID, forHTTPHeaderField: "Client-ID")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["data"] as? [String: Any]
    }

    private func parseGQL(_ list: [[String: Any]]) -> [String: [String: String]] {
        var map: [String: [String: String]] = [:]
        for b in list {
            guard let set = b["setID"] as? String, let v = b["version"] as? String,
                  let u = b["imageURL"] as? String, u.hasPrefix("https://") else { continue }
            map[set, default: [:]][v] = u
        }
        return map
    }

    private func loadGlobalPublic() async {
        guard !globalsLoaded,
              let d = await gqlBadges("query { badges { setID version imageURL(size: DOUBLE) } }", [:]),
              let list = d["badges"] as? [[String: Any]], !list.isEmpty else { return }
        global = parseGQL(list)
        globalsLoaded = true
        logger.success("BADGES", "Badges globaux chargés (GQL)", "\(global.count) sets")
    }

    private func loadChannelPublic(channelId: String) async {
        guard let d = await gqlBadges(
                "query($id: ID!) { user(id: $id) { broadcastBadges { setID version imageURL(size: DOUBLE) } } }",
                ["id": channelId]),
              let user = d["user"] as? [String: Any],
              let list = user["broadcastBadges"] as? [[String: Any]] else { return }
        channel[channelId] = parseGQL(list)
        logger.success("BADGES", "Badges canal \(channelId) chargés (GQL)", "\(channel[channelId]?.count ?? 0) sets")
    }

    // MARK: – Resolve
    /// Retourne l'URL 2x d'un badge (ex: "moderator/1").
    /// Priorité : canal → global → CDN statique (fallback standard)
    func resolve(badgeId: String, channelId: String?) -> String {
        let parts = badgeId.components(separatedBy: "/")
        guard parts.count == 2 else { return "" }
        let setId = parts[0], version = parts[1]

        if let cid = channelId, let url = channel[cid]?[setId]?[version] { return url }
        if let url = global[setId]?[version] { return url }

        // CDN statique : fonctionne pour broadcaster, moderator, staff, vip…
        return "https://static-cdn.jtvnw.net/badges/v1/\(setId)/\(version)/2"
    }

    // MARK: – Parsing helper
    private func parseSets(_ sets: [[String: Any]]) -> [String: [String: String]] {
        var map: [String: [String: String]] = [:]
        for set in sets {
            guard let setId    = set["set_id"] as? String,
                  let versions = set["versions"] as? [[String: Any]] else { continue }
            var vMap: [String: String] = [:]
            for v in versions {
                guard let vid  = v["id"] as? String,
                      let url  = v["image_url_2x"] as? String else { continue }
                vMap[vid] = url
            }
            map[setId] = vMap
        }
        return map
    }
}
