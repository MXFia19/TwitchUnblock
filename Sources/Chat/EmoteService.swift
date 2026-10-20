import Foundation

/// Emotes et badges du chat : 10 s au plus par requête (60 s par défaut). Un
/// service tiers bloqué (réseau filtré, VPN) ne doit pas tenir le chat sur
/// « Connecting… ».
let chatAssetSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 10
    config.timeoutIntervalForResource = 20
    return URLSession(configuration: config)
}()

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
    /// Nom affiché de la chaîne (« Trymacs »), donné par FFZ ou 7TV : BTTV ne
    /// le donne pas pour les emotes mises en ligne par la chaîne.
    private var channelDisplayNames: [String: String] = [:]

    /// Emotes personnelles BTTV Pro, par identifiant Twitch de leur
    /// propriétaire (annoncées par BTTVLive) ; 500 personnes au plus.
    private var personalBTTV: [String: [String: TwitchEmote]] = [:]
    private var personalOrder: [String] = []

    /// Emote Twitch d'une chaîne pour le sélecteur, avec son jeu d'emotes
    /// (nil pour une emote de follower : jamais grisée).
    private struct ChannelTwitchEmote {
        let emote: TwitchEmote
        let setId: String?
    }
    /// Emotes Twitch des chaînes (followers, puis abonnés par niveau), dans
    /// l'ordre de Twitch. Jamais dans resolve() : dans un message, une emote
    /// Twitch n'en est une que si le tag IRC le dit.
    private var channelTwitch: [String: [ChannelTwitchEmote]] = [:]
    /// Chargements en cours, et essais par chaîne : deux au plus par séance
    /// (une coupure se rattrape, une panne ne fait pas de boucle).
    private var twitchLoading: Set<String> = []
    private var twitchAttempts: [String: Int] = [:]
    /// Jeux d'emotes du compte connecté au chat (tag IRC `emote-sets`) : ceux
    /// d'un autre compte ne comptent pas.
    private var userEmoteSets: (login: String, sets: Set<String>)? = nil

    // MARK: – Load globals once
    /// Emotes globales : une fois par séance et par service (reset() les
    /// oublie). Un service encore vide (délai dépassé, réseau) est retenté au
    /// prochain chat, sans recharger ceux qui ont répondu.
    func loadGlobals() async {
        let bttv = globalBTTV.isEmpty, ffz = globalFFZ.isEmpty, stv = global7TV.isEmpty
        guard bttv || ffz || stv else { return }
        await withTaskGroup(of: Void.self) { group in
            if bttv { group.addTask { await self.loadBTTVGlobal() } }
            if ffz  { group.addTask { await self.loadFFZGlobal() } }
            if stv  { group.addTask { await self.load7TVGlobal() } }
        }
        logger.success("EMOTES", "Emotes globales chargées",
                       "BTTV:\(globalBTTV.count) FFZ:\(globalFFZ.count) 7TV:\(global7TV.count)")
    }

    // MARK: – Load per channel
    func loadChannel(channelId: String, channelName: String) async {
        guard !loadedChannels.contains(channelId) else { return }
        loadedChannels.insert(channelId)
        await loadChannelSources(channelId: channelId, channelName: channelName, onlyMissing: false)
        // Un service sans réponse (coupure, erreur 5xx) : nouvel essai 30 s plus
        // tard, une seule fois — « catJAM » restait en texte jusqu'au
        // redémarrage. Une chaîne sans compte FFZ ou 7TV ne répond pas non
        // plus : un essai de plus, pas une boucle.
        if channelBTTV[channelId] == nil || channelFFZ[channelId] == nil || channel7TV[channelId] == nil {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await self?.loadChannelSources(channelId: channelId, channelName: channelName, onlyMissing: true)
            }
        }
    }

    private func loadChannelSources(channelId: String, channelName: String, onlyMissing: Bool) async {
        let bttv = !onlyMissing || channelBTTV[channelId] == nil
        let ffz  = !onlyMissing || channelFFZ[channelId] == nil
        let stv  = !onlyMissing || channel7TV[channelId] == nil
        guard bttv || ffz || stv else { return }
        await withTaskGroup(of: Void.self) { group in
            if bttv { group.addTask { await self.loadBTTVChannel(channelId: channelId, channelName: channelName) } }
            // FFZ reçoit maintenant les deux : channelId pour stocker, channelName pour l'API
            if ffz { group.addTask { await self.loadFFZChannel(channelId: channelId, channelName: channelName) } }
            if stv { group.addTask { await self.load7TVChannel(channelId: channelId) } }
        }
        // Auteur des emotes BTTV de la chaîne : le login passé en repli
        // (« trymacs ») devient le nom affiché, comme pour les emotes partagées.
        if let shown = channelDisplayNames[channelId], shown != channelName,
           var map = channelBTTV[channelId] {
            for (key, e) in map where e.author == channelName { map[key]?.author = shown }
            channelBTTV[channelId] = map
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
    /// Vide les emotes chargées pour forcer un rechargement complet
    /// (action « Recharger emotes et badges » du menu du chat).
    func reset() {
        globalBTTV.removeAll(); globalFFZ.removeAll(); global7TV.removeAll()
        channelBTTV.removeAll(); channelFFZ.removeAll(); channel7TV.removeAll()
        loadedChannels.removeAll(); channelDisplayNames.removeAll()
        channelTwitch.removeAll(); twitchAttempts.removeAll()
        // twitchById est alimenté au fil des messages reçus : on le garde,
        // sinon les emotes Twitch des messages déjà affichés disparaîtraient.
    }

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
    /// `userId` : auteur du message, pour ses emotes personnelles BTTV Pro
    /// (après celles de la chaîne, avant les globales).
    func resolve(name: String, channelId: String?, userId: String? = nil) -> TwitchEmote? {
        if let cid = channelId {
            if let e = channelBTTV[cid]?[name] { return e }
            if let e = channelFFZ[cid]?[name]  { return e }   // fix : clé = channelId
            if let e = channel7TV[cid]?[name]  { return e }
        }
        if let uid = userId, let e = personalBTTV[uid]?[name] { return e }
        if let e = globalBTTV[name] { return e }
        if let e = globalFFZ[name]  { return e }
        if let e = global7TV[name]  { return e }
        return nil
    }

    func resolveById(_ id: String) -> TwitchEmote? { twitchById[id] }

    /// Emote Twitch par son nom, parmi celles déjà vues dans ce chat (celles
    /// que les suggestions proposent) : pour l'écho de nos propres messages,
    /// qui n'a pas de balises d'emotes.
    func twitchEmote(named name: String) -> TwitchEmote? {
        twitchById.values.first { $0.name == name }
    }

    // MARK: – Grouped emotes for the picker
    /// `login` : compte du sélecteur. Ses jeux d'emotes (tag IRC) grisent les
    /// emotes d'abonné de la chaîne qu'il n'a pas ; inconnus (pas encore de
    /// USERSTATE, autre compte), aucune n'est grisée.
    func groupedEmotes(channelId: String?, login: String? = nil) -> [(label: String, emotes: [TwitchEmote])] {
        var groups: [(label: String, emotes: [TwitchEmote])] = []

        // ── Emotes du canal (toutes sources) ────────────────────────
        if let cid = channelId {
            var canal: [TwitchEmote] = []
            canal += Array((channel7TV[cid]  ?? [:]).values)
            canal += Array((channelBTTV[cid] ?? [:]).values)
            canal += Array((channelFFZ[cid]  ?? [:]).values)   // fix : clé = channelId
            canal.sort { $0.name.lowercased() < $1.name.lowercased() }
            // Emotes Twitch de la chaîne (une chaîne sans 7TV, BTTV ni FFZ
            // n'avait pas d'onglet) : celles du compte d'abord, puis les
            // tierces, puis les emotes d'abonné hors de ses jeux, grisées.
            var sets: Set<String>? = nil
            if let known = userEmoteSets, known.login == login?.lowercased() { sets = known.sets }
            var usable: [TwitchEmote] = [], locked: [TwitchEmote] = []
            for item in channelTwitch[cid] ?? [] {
                if let sets, let setId = item.setId, !sets.contains(setId) {
                    var e = item.emote
                    e.locked = true
                    locked.append(e)
                } else {
                    usable.append(item.emote)
                }
            }
            canal = usable + canal + locked
            if !canal.isEmpty {
                // Clé de traduction : le sélecteur l'affiche dans la langue de
                // l'app (les autres onglets sont des noms de marque).
                groups.append(("emotes_channel", canal))
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

    // MARK: – Emotes Twitch de la chaîne (sélecteur)
    /// Jeux d'emotes du compte, lus dans GLOBALUSERSTATE et USERSTATE.
    func setUserEmoteSets(_ sets: Set<String>, login: String) {
        userEmoteSets = (login: login, sets: sets)
    }

    /// Emotes Twitch de la chaîne (followers, abonnés par niveau) : une
    /// requête GQL publique par chaîne et par séance, gardée même vide. Sans
    /// réponse, un second essai au prochain appel, pas plus.
    func loadTwitchChannel(channelId: String) async {
        guard !channelId.isEmpty, channelTwitch[channelId] == nil, !twitchLoading.contains(channelId),
              twitchAttempts[channelId, default: 0] < 2 else { return }
        twitchLoading.insert(channelId)
        twitchAttempts[channelId, default: 0] += 1
        let list = await fetchTwitchChannel(channelId)
        twitchLoading.remove(channelId)
        guard let list else {
            logger.debug("EMOTES", "Emotes Twitch de la chaîne indisponibles", channelId)
            return
        }
        channelTwitch[channelId] = list
        logger.success("EMOTES", "Emotes Twitch de la chaîne chargées", "\(list.count)")
    }

    private static let twitchChannelQuery = """
    query($id: ID!) { user(id: $id) { subscriptionProducts { tier emotes { id token setID } } } \
    channel(id: $id) { localEmoteSets { emotes { id token setID } } } }
    """

    /// nil : pas de réponse lisible de Twitch (réseau, GQL en panne).
    private func fetchTwitchChannel(_ channelId: String) async -> [ChannelTwitchEmote]? {
        // Les valeurs passent en variables, jamais collées dans le texte.
        guard let url = URL(string: "https://gql.twitch.tv/gql"),
              let body = try? JSONSerialization.data(withJSONObject: ["query": Self.twitchChannelQuery,
                                                                      "variables": ["id": channelId]]) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(kGQLClientID, forHTTPHeaderField: "Client-ID")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        guard let (data, resp) = try? await chatAssetSession.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = json["data"] as? [String: Any] else { return nil }
        var out: [ChannelTwitchEmote] = []
        var seen = Set<String>()
        func add(_ list: Any?, follower: Bool) {
            for e in list as? [[String: Any]] ?? [] {
                guard let id = e["id"] as? String, !id.isEmpty,
                      let token = e["token"] as? String, !token.isEmpty,
                      seen.insert(id).inserted else { continue }
                let emote = TwitchEmote(id: id, name: token,
                                        url: "https://static-cdn.jtvnw.net/emoticons/v2/\(id)/default/dark/2.0",
                                        source: .twitch, scope: .channel)
                out.append(ChannelTwitchEmote(emote: emote, setId: follower ? nil : (e["setID"] as? String)))
            }
        }
        // Followers d'abord, puis les niveaux d'abonnement dans l'ordre
        // (« 1000 », « 2000 », « 3000 »).
        let local = (d["channel"] as? [String: Any])?["localEmoteSets"] as? [[String: Any]] ?? []
        for group in local { add(group["emotes"], follower: true) }
        let products = (d["user"] as? [String: Any])?["subscriptionProducts"] as? [[String: Any]] ?? []
        let tier = { (p: [String: Any]) -> Int in Int(p["tier"] as? String ?? "") ?? Int.max }
        for p in products.sorted(by: { tier($0) < tier($1) }) { add(p["emotes"], follower: false) }
        // Erreur partielle sans rien d'utilisable (« service timeout »…) : pas
        // gardée, l'essai suivant redemandera.
        if out.isEmpty, (json["errors"] as? [Any])?.isEmpty == false { return nil }
        return out
    }

    // MARK: – Autocomplétion
    /// Emotes dont le nom commence par `prefix`, puis celles qui le contiennent.
    /// Le préfixe l'emporte : en tapant « Kappa » on veut Kappa avant KappaPride.
    func suggest(prefix: String, channelId: String?, limit: Int = 24) -> [TwitchEmote] {
        let kw = prefix.lowercased()
        guard !kw.isEmpty else { return [] }

        var pool: [String: TwitchEmote] = [:]
        if let cid = channelId {
            for dict in [channel7TV[cid], channelBTTV[cid], channelFFZ[cid]] {
                for (k, v) in dict ?? [:] { pool[k] = v }
            }
        }
        for dict in [global7TV, globalBTTV, globalFFZ, twitchById] {
            for (_, v) in dict where pool[v.name] == nil { pool[v.name] = v }
        }

        var starts: [TwitchEmote] = [], contains: [TwitchEmote] = []
        for emote in pool.values {
            let name = emote.name.lowercased()
            if name.hasPrefix(kw) { starts.append(emote) }
            else if name.contains(kw) { contains.append(emote) }
        }
        let byName: (TwitchEmote, TwitchEmote) -> Bool = { $0.name.lowercased() < $1.name.lowercased() }
        return Array((starts.sorted(by: byName) + contains.sorted(by: byName)).prefix(limit))
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: – BTTV
    private func loadBTTVGlobal() async {
        guard let url = URL(string: "https://api.betterttv.net/3/cached/emotes/global"),
              let (data, _) = try? await chatAssetSession.data(from: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        for obj in arr { if let e = bttvEmote(obj, scope: .global) { globalBTTV[e.name] = e } }
    }

    private func loadBTTVChannel(channelId: String, channelName: String) async {
        guard let url = URL(string: "https://api.betterttv.net/3/cached/users/twitch/\(channelId)"),
              let (data, _) = try? await chatAssetSession.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var map: [String: TwitchEmote] = [:]
        // channelEmotes : mises en ligne par la chaîne ; sharedEmotes : leur
        // créateur est dans `user`.
        for key in ["channelEmotes", "sharedEmotes"] {
            if let arr = json[key] as? [[String: Any]] {
                for obj in arr {
                    if let e = bttvEmote(obj, scope: .channel, author: channelName) { map[e.name] = e }
                }
            }
        }
        channelBTTV[channelId] = map
    }

    // MARK: – BTTV en direct (BTTVLive)
    func removePersonalBTTV(userId: String) {
        guard personalBTTV.removeValue(forKey: userId) != nil else { return }
        personalOrder.removeAll { $0 == userId }
    }

    func setPersonalBTTV(userId: String, emotes: [[String: Any]]) {
        var map: [String: TwitchEmote] = [:]
        for obj in emotes {
            if var e = bttvEmote(obj, scope: .personal) { e.personal = true; map[e.name] = e }
        }
        guard !map.isEmpty else { removePersonalBTTV(userId: userId); return }
        if personalBTTV[userId] == nil { personalOrder.append(userId) }
        personalBTTV[userId] = map
        if personalOrder.count > 500 { personalBTTV[personalOrder.removeFirst()] = nil }
    }

    /// Emote ajoutée ou modifiée (renommée) sur la chaîne pendant le live.
    func upsertChannelBTTV(channelId: String, emote obj: [String: Any]) {
        guard let id = obj["id"] as? String else { return }
        var map = channelBTTV[channelId] ?? [:]
        let old = map.first { $0.value.id == id }
        guard let code = (obj["code"] as? String) ?? old?.key, !code.isEmpty else { return }
        if let old { map[old.key] = nil }
        // Renommage : l'événement ne porte que l'id et le nom, l'auteur connu
        // est gardé.
        map[code] = TwitchEmote(id: id, name: code,
                                url: "https://cdn.betterttv.net/emote/\(id)/2x", source: .bttv,
                                scope: .channel,
                                author: ((obj["user"] as? [String: Any])?["displayName"] as? String) ?? old?.value.author,
                                isModifier: (obj["modifier"] as? Bool) ?? old?.value.isModifier ?? false,
                                largeURL: "https://cdn.betterttv.net/emote/\(id)/3x")
        channelBTTV[channelId] = map
    }

    func removeChannelBTTV(channelId: String, emoteId: String) {
        guard var map = channelBTTV[channelId],
              let key = map.first(where: { $0.value.id == emoteId })?.key else { return }
        map[key] = nil
        channelBTTV[channelId] = map
    }

    /// `author` : repli quand l'emote ne nomme pas son créateur (emotes mises
    /// en ligne par la chaîne elle-même).
    private func bttvEmote(_ obj: [String: Any], scope: EmoteScope, author: String? = nil) -> TwitchEmote? {
        guard let id = obj["id"] as? String, let name = obj["code"] as? String else { return nil }
        let user = obj["user"] as? [String: Any]
        return TwitchEmote(id: id, name: name,
                           url: "https://cdn.betterttv.net/emote/\(id)/2x", source: .bttv,
                           scope: scope,
                           author: (user?["displayName"] as? String) ?? (user?["name"] as? String) ?? author,
                           // c!, w!… : modificateurs, pas des emotes qui se superposent.
                           isModifier: obj["modifier"] as? Bool ?? false,
                           largeURL: "https://cdn.betterttv.net/emote/\(id)/3x")
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: – FFZ
    private func loadFFZGlobal() async {
        guard let url = URL(string: "https://api.frankerfacez.com/v1/set/global"),
              let (data, _) = try? await chatAssetSession.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sets = json["sets"] as? [String: Any] else { return }
        for (_, setValue) in sets {
            guard let setObj = setValue as? [String: Any],
                  let emoticons = setObj["emoticons"] as? [[String: Any]] else { continue }
            for obj in emoticons { if let e = ffzEmote(obj, scope: .global) { globalFFZ[e.name] = e } }
        }
    }

    // Fix : stockage par channelId (API appellée avec channelName)
    private func loadFFZChannel(channelId: String, channelName: String) async {
        guard let url = URL(string: "https://api.frankerfacez.com/v1/room/\(channelName)"),
              let (data, _) = try? await chatAssetSession.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sets = json["sets"] as? [String: Any] else { return }
        if let shown = (json["room"] as? [String: Any])?["display_name"] as? String, !shown.isEmpty {
            channelDisplayNames[channelId] = shown
        }
        var map: [String: TwitchEmote] = [:]
        for (_, setValue) in sets {
            guard let setObj = setValue as? [String: Any],
                  let emoticons = setObj["emoticons"] as? [[String: Any]] else { continue }
            for obj in emoticons { if let e = ffzEmote(obj, scope: .channel) { map[e.name] = e } }
        }
        channelFFZ[channelId] = map   // ← stocké par channelId, pas channelName
    }

    /// Les emotes animées sont dans `animated` (WebP) : `urls` n'en garde
    /// qu'une image fixe. `animated` vaut null pour les autres.
    private func ffzEmote(_ obj: [String: Any], scope: EmoteScope) -> TwitchEmote? {
        let urls = obj["urls"] as? [String: Any] ?? [:]
        let anim = obj["animated"] as? [String: Any] ?? [:]
        func link(_ d: [String: Any], _ size: String) -> String? {
            guard let u = d[size] as? String, !u.isEmpty else { return nil }
            return u.hasPrefix("//") ? "https:\(u)" : u
        }
        guard let id   = obj["id"] as? Int,
              let name = obj["name"] as? String,
              let url  = link(anim, "2") ?? link(urls, "2") ?? link(urls, "1") else { return nil }
        return TwitchEmote(id: "\(id)", name: name, url: url, source: .ffz,
                           scope: scope,
                           author: (obj["owner"] as? [String: Any])?["display_name"] as? String,
                           // ffzW, ffzHyper… : effets appliqués à une autre emote.
                           isModifier: obj["modifier"] as? Bool ?? false,
                           largeURL: link(anim, "4") ?? link(urls, "4"))
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: – 7TV
    private func load7TVGlobal() async {
        guard let url = URL(string: "https://7tv.io/v3/emote-sets/global"),
              let (data, _) = try? await chatAssetSession.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let emotes = json["emotes"] as? [[String: Any]] else { return }
        for obj in emotes { if let e = stvEmote(obj, scope: .global) { global7TV[e.name] = e } }
    }

    private func load7TVChannel(channelId: String) async {
        guard let url = URL(string: "https://7tv.io/v3/users/twitch/\(channelId)"),
              let (data, _) = try? await chatAssetSession.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let setObj = json["emote_set"] as? [String: Any],
              let emotes = setObj["emotes"] as? [[String: Any]] else { return }
        if channelDisplayNames[channelId] == nil,
           let shown = json["display_name"] as? String, !shown.isEmpty {
            channelDisplayNames[channelId] = shown
        }
        var map: [String: TwitchEmote] = [:]
        for obj in emotes { if let e = stvEmote(obj, scope: .channel) { map[e.name] = e } }
        channel7TV[channelId] = map
    }

    private func stvEmote(_ obj: [String: Any], scope: EmoteScope) -> TwitchEmote? {
        guard let id   = obj["id"] as? String,
              let name = obj["name"] as? String,
              let data = obj["data"] as? [String: Any],
              let host = (data["host"] as? [String: Any])?["url"] as? String else { return nil }
        // `name` : nom choisi par la chaîne ; `data.name` : nom d'origine.
        let original = data["name"] as? String
        return TwitchEmote(id: id, name: name, url: "https:\(host)/2x.webp", source: .seventv,
                           scope: scope,
                           author: (data["owner"] as? [String: Any])?["display_name"] as? String,
                           originalName: original.flatMap { $0.isEmpty || $0 == name ? nil : $0 },
                           // Drapeau actif dans ce jeu d'emotes (data.flags n'est
                           // qu'une recommandation).
                           zeroWidth: ((obj["flags"] as? Int) ?? 0) & 1 != 0,
                           largeURL: "https:\(host)/4x.webp")
    }
}
