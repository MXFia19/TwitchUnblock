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

    // MARK: – Load global badges (Helix)
    func loadGlobal(token: String) async {
        guard !globalsLoaded else { return }
        guard let url = URL(string: "https://api.twitch.tv/helix/chat/badges/global") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)",  forHTTPHeaderField: "Authorization")
        req.setValue(kHelixClientID,      forHTTPHeaderField: "Client-Id")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sets = json["data"] as? [[String: Any]] else { return }

        global = parseSets(sets)
        globalsLoaded = true
        logger.success("BADGES", "Badges globaux chargés", "\(global.count) sets")
    }

    // MARK: – Load channel badges (Helix — badges sub perso, bits, etc.)
    func loadChannel(channelId: String, token: String) async {
        guard !loadedChannels.contains(channelId) else { return }
        loadedChannels.insert(channelId)

        guard let url = URL(string:
            "https://api.twitch.tv/helix/chat/badges?broadcaster_id=\(channelId)"
        ) else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)",  forHTTPHeaderField: "Authorization")
        req.setValue(kHelixClientID,      forHTTPHeaderField: "Client-Id")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sets = json["data"] as? [[String: Any]] else { return }

        channel[channelId] = parseSets(sets)
        logger.success("BADGES", "Badges canal \(channelId) chargés",
                       "\(channel[channelId]?.count ?? 0) sets")
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
