import Foundation

// MARK: – Emote cache per channel
actor EmoteService {
    static let shared = EmoteService()
    private init() {}

    private var globalBTTV: [String: TwitchEmote] = [:]
    private var globalFFZ:  [String: TwitchEmote] = [:]
    private var global7TV:  [String: TwitchEmote] = [:]

    // Toutes les sources de canal sont maintenant indexées par channelId (cohérent)
    private var channelBTTV: [String: [String: TwitchEmote]] = [:]
    private var channelFFZ:  [String: [String: TwitchEmote]] = [:]   // clé = channelId (fix!)
    private var channel7TV:  [String: [String: TwitchEmote]] = [:]

    private var twitchById:     [String: TwitchEmote] = [:]
    private var loadedChannels: Set<String> = []

    // MARK: – Load globals once
    func loadGlobals() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadBTTVGlobal() }
            group.addTask { await self.loadFFZGlobal() }
            group.addTask { await self.load7TVGlobal() }
        }
        logger.success("EMOTES", "Emotes globales chargées",
                       "BTTV:\(globalBTTV.count) FFZ:\(globalFFZ.count) 7TV:\(global7TV.count)")
    }

    // MARK: – Load per channel
    func loadChannel(channelId: String, channelName: String) async {
        guard !loadedChannels.contains(channelId) else { return }
        loadedChannels.insert(channelId)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadBTTVChannel(channelId: channelId) }
            // FFZ reçoit maintenant les deux : channelId pour stocker, channelName pour l'API
            group.addTask { await self.loadFFZChannel(channelId: channelId, channelName: channelName) }
            group.addTask { await self.load7TVChannel(channelId: channelId) }
        }
        let total = (channelBTTV[channelId]?.count ?? 0)
                  + (channelFFZ[channelId]?.count ?? 0)
                  + (channel7TV[channelId]?.count ?? 0)
        logger.success("EMOTES", "Emotes canal \(channelName) chargées",
                       "BTTV:\(channelBTTV[channelId]?.count ?? 0) " +
                       "FFZ:\(channelFFZ[channelId]?.count ?? 0) " +
                       "7TV:\(channel7TV[channelId]?.count ?? 0) — total:\(total)")
    }

    // MARK: – Register Twitch emote from chat tag
    func registerTwitchEmote(id: String, name: String) {
        if twitchById[id] == nil {
            twitchById[id] = TwitchEmote(
                id: id, name: name,
                url: "https://static-cdn.jtvnw.net/emoticons/v2/\(id)/default/dark/2.0",
                source: .twitch
            )
        }
    }

    // MARK: – Resolve emote by name (channel-first, toutes les sources par channelId)
    func resolve(name: String, channelId: String?) -> TwitchEmote? {
        if let cid = channelId {
            if let e = channelBTTV[cid]?[name] { return e }
            if let e = channelFFZ[cid]?[name]  { return e }   // fix : clé = channelId
            if let e = channel7TV[cid]?[name]  { return e }
        }
        if let e = globalBTTV[name] { return e }
        if let e = globalFFZ[name]  { return e }
        if let e = global7TV[name]  { return e }
        return nil
    }

    func resolveById(_ id: String) -> TwitchEmote? { twitchById[id] }

    // MARK: – Grouped emotes for the picker
    func groupedEmotes(channelId: String?) -> [(label: String, emotes: [TwitchEmote])] {
        var groups: [(label: String, emotes: [TwitchEmote])] = []

        // ── Emotes du canal (toutes sources) ────────────────────────
        if let cid = channelId {
            var canal: [TwitchEmote] = []
            canal += Array((channel7TV[cid]  ?? [:]).values)
            canal += Array((channelBTTV[cid] ?? [:]).values)
            canal += Array((channelFFZ[cid]  ?? [:]).values)   // fix : clé = channelId
            canal.sort { $0.name.lowercased() < $1.name.lowercased() }
            if !canal.isEmpty {
                groups.append(("⭐ Canal", canal))
            }
        }

        // ── Globaux par source ───────────────────────────────────────
        let g7tv  = Array(global7TV.values).sorted  { $0.name.lowercased() < $1.name.lowercased() }
        let gBttv = Array(globalBTTV.values).sorted { $0.name.lowercased() < $1.name.lowercased() }
        let gFfz  = Array(globalFFZ.values).sorted  { $0.name.lowercased() < $1.name.lowercased() }

        if !g7tv.isEmpty  { groups.append(("7TV",  g7tv))  }
        if !gBttv.isEmpty { groups.append(("BTTV", gBttv)) }
        if !gFfz.isEmpty  { groups.append(("FFZ",  gFfz))  }

        return groups
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: – BTTV
    private func loadBTTVGlobal() async {
        guard let url = URL(string: "https://api.betterttv.net/3/cached/emotes/global"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        for obj in arr { if let e = bttvEmote(obj) { globalBTTV[e.name] = e } }
    }

    private func loadBTTVChannel(channelId: String) async {
        guard let url = URL(string: "https://api.betterttv.net/3/cached/users/twitch/\(channelId)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var map: [String: TwitchEmote] = [:]
        for key in ["channelEmotes", "sharedEmotes"] {
            if let arr = json[key] as? [[String: Any]] {
                for obj in arr { if let e = bttvEmote(obj) { map[e.name] = e } }
            }
        }
        channelBTTV[channelId] = map
    }

    private func bttvEmote(_ obj: [String: Any]) -> TwitchEmote? {
        guard let id = obj["id"] as? String, let name = obj["code"] as? String else { return nil }
        return TwitchEmote(id: id, name: name,
                           url: "https://cdn.betterttv.net/emote/\(id)/2x", source: .bttv)
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: – FFZ
    private func loadFFZGlobal() async {
        guard let url = URL(string: "https://api.frankerfacez.com/v1/set/global"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sets = json["sets"] as? [String: Any] else { return }
        for (_, setValue) in sets {
            guard let setObj = setValue as? [String: Any],
                  let emoticons = setObj["emoticons"] as? [[String: Any]] else { continue }
            for obj in emoticons { if let e = ffzEmote(obj) { globalFFZ[e.name] = e } }
        }
    }

    // Fix : stockage par channelId (API appellée avec channelName)
    private func loadFFZChannel(channelId: String, channelName: String) async {
        guard let url = URL(string: "https://api.frankerfacez.com/v1/room/\(channelName)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sets = json["sets"] as? [String: Any] else { return }
        var map: [String: TwitchEmote] = [:]
        for (_, setValue) in sets {
            guard let setObj = setValue as? [String: Any],
                  let emoticons = setObj["emoticons"] as? [[String: Any]] else { continue }
            for obj in emoticons { if let e = ffzEmote(obj) { map[e.name] = e } }
        }
        channelFFZ[channelId] = map   // ← stocké par channelId, pas channelName
    }

    private func ffzEmote(_ obj: [String: Any]) -> TwitchEmote? {
        guard let id   = obj["id"] as? Int,
              let name = obj["name"] as? String,
              let urls = obj["urls"] as? [String: Any],
              let url  = (urls["2"] ?? urls["1"]) as? String else { return nil }
        let fullURL = url.hasPrefix("//") ? "https:\(url)" : url
        return TwitchEmote(id: "\(id)", name: name, url: fullURL, source: .ffz)
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: – 7TV
    private func load7TVGlobal() async {
        guard let url = URL(string: "https://7tv.io/v3/emote-sets/global"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let emotes = json["emotes"] as? [[String: Any]] else { return }
        for obj in emotes { if let e = stvEmote(obj) { global7TV[e.name] = e } }
    }

    private func load7TVChannel(channelId: String) async {
        guard let url = URL(string: "https://7tv.io/v3/users/twitch/\(channelId)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let setObj = json["emote_set"] as? [String: Any],
              let emotes = setObj["emotes"] as? [[String: Any]] else { return }
        var map: [String: TwitchEmote] = [:]
        for obj in emotes { if let e = stvEmote(obj) { map[e.name] = e } }
        channel7TV[channelId] = map
    }

    private func stvEmote(_ obj: [String: Any]) -> TwitchEmote? {
        guard let id   = obj["id"] as? String,
              let name = obj["name"] as? String,
              let data = obj["data"] as? [String: Any],
              let host = (data["host"] as? [String: Any])?["url"] as? String else { return nil }
        return TwitchEmote(id: id, name: name, url: "https:\(host)/2x.webp", source: .seventv)
    }
}
