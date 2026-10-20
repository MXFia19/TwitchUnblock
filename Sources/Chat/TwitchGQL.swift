import Foundation

// MARK: – Utilitaire GQL persisted-query (lectures + mutations avec integrity)
// Réutilise le minteur d'integrity (TwitchWebGQL) pour les mutations Kasada-gated.
@MainActor
final class TwitchGQL {
    static let shared = TwitchGQL()
    private init() {}

    private static let webUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"

    private var integrityTok:    String? = nil
    private var integrityDevice: String  = ""
    private var integrityExpiry: Date    = .distantPast
    /// Jeton web pour lequel il a été généré : après un changement de compte,
    /// celui de l'ancien était servi et le premier Suivre/pari/vote échouait.
    private var integrityFor:    String  = ""

    private var deviceId: String {
        if let d = UserDefaults.standard.string(forKey: "twitch_device_id") { return d }
        let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let d = String((0..<32).map { _ in chars.randomElement()! })
        UserDefaults.standard.set(d, forKey: "twitch_device_id")
        return d
    }

    private func persistedBody(_ op: String, _ vars: [String: Any], _ hash: String) -> Data? {
        let body: [[String: Any]] = [[
            "operationName": op,
            "variables": vars,
            "extensions": ["persistedQuery": ["version": 1, "sha256Hash": hash]]
        ]]
        return try? JSONSerialization.data(withJSONObject: body)
    }

    /// Lecture (persisted query). `token` optionnel (nécessaire pour les champs `self`).
    func query(_ op: String, variables: [String: Any], sha256: String,
               token: String? = nil) async -> [String: Any]? {
        guard let url = URL(string: "https://gql.twitch.tv/gql"),
              let payload = persistedBody(op, variables, sha256) else { return nil }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue(kGQLClientID,        forHTTPHeaderField: "Client-ID")
        req.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        req.setValue(deviceId,            forHTTPHeaderField: "X-Device-Id")
        req.setValue(Self.webUA,          forHTTPHeaderField: "User-Agent")
        if let t = token { req.setValue("OAuth \(t)", forHTTPHeaderField: "Authorization") }
        req.httpBody = payload
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return arr.first
    }

    private func validIntegrity(token: String) async -> Bool {
        if integrityTok != nil, integrityFor == token, integrityExpiry > Date().addingTimeInterval(60),
           !integrityDevice.isEmpty {
            return true
        }
        guard let mint = await TwitchWebGQL.shared.mintIntegrity(token: token) else { return false }
        integrityTok    = mint.token
        integrityDevice = mint.deviceId.isEmpty ? deviceId : mint.deviceId
        integrityExpiry = mint.expiry
        integrityFor    = token
        return true
    }

    /// Mutation persisted-query avec Client-Integrity (comme claim/redeem).
    /// Jeton d'intégrité refusé : régénéré et requête renvoyée une fois (mêmes
    /// variables, donc même transaction) — le premier Suivre/pari/vote
    /// échouait, et le second arrivait trop tard pour un pari qui fermait.
    func mutation(_ op: String, variables: [String: Any], sha256: String,
                  token: String, retried: Bool = false) async -> [String: Any]? {
        guard let payload = persistedBody(op, variables, sha256) else { return nil }
        return await send(op, payload: payload, token: token, retried: retried)
    }

    /// Mutation écrite en toutes lettres, faute de requête enregistrée connue
    /// (création d'un clip) : même jeton d'intégrité, même nouvel essai.
    func rawMutation(_ op: String, query: String, variables: [String: Any],
                     token: String) async -> [String: Any]? {
        let body: [[String: Any]] = [["operationName": op, "query": query, "variables": variables]]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return await send(op, payload: payload, token: token)
    }

    private func send(_ op: String, payload: Data, token: String,
                      retried: Bool = false) async -> [String: Any]? {
        guard await validIntegrity(token: token), let it = integrityTok,
              let url = URL(string: "https://gql.twitch.tv/gql") else { return nil }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue(kGQLClientID,               forHTTPHeaderField: "Client-ID")
        req.setValue("OAuth \(token)",           forHTTPHeaderField: "Authorization")
        req.setValue(integrityDevice,            forHTTPHeaderField: "X-Device-Id")
        req.setValue(it,                         forHTTPHeaderField: "Client-Integrity")
        req.setValue(Self.webUA,                 forHTTPHeaderField: "User-Agent")
        req.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = arr.first else { return nil }
        if let errors = first["errors"] as? [[String: Any]], !errors.isEmpty {
            let msgs = errors.compactMap { $0["message"] as? String }.joined(separator: " · ")
            logger.warn("GQL", "Erreurs \(op)", msgs)
            if msgs.lowercased().contains("integrity") {
                integrityTok = nil
                integrityExpiry = .distantPast
                if !retried {
                    return await send(op, payload: payload, token: token, retried: true)
                }
            }
        }
        return first
    }
}

// MARK: – Suivre / Ne plus suivre
extension Notification.Name {
    /// Chaîne suivie ou retirée sur Twitch (session web) : l'accueil relit
    /// ses suivis, qu'il ne relisait qu'au changement de jeton.
    static let twitchFollowsChanged = Notification.Name("TwitchFollowsChanged")
}

@MainActor
final class FollowService: ObservableObject {
    @Published var isFollowing: Bool? = nil   // nil = inconnu / en cours
    @Published var busy = false
    /// Dernier refus de Twitch pour la chaîne affichée (nil : aucun) : son
    /// code (« TOO_MANY_FOLLOWS »…), vide quand Twitch n'en donne pas.
    @Published var lastError: String? = nil
    /// Sans session web : suivi gardé sur cet appareil (AppStore.localFollows).
    private(set) var localStore: AppStore? = nil

    /// Pas de compte (ou pas de session web) : on suit la chaîne localement.
    func loadLocal(login: String, store: AppStore) {
        self.login = login.lowercased()
        localStore = store
        lastError = nil
        isFollowing = store.isLocallyFollowed(login)
    }

    private var channelId = ""
    private var login = ""

    private static let hashStatus   = "1131e2a2138f219d96db8deda8eb06b217c0669e4fd33b8bed47623fc9764b33"
    private static let hashFollow   = "800e7346bdf7e5278a3c1d3f21b2b56e2639928f86815677a7126b093b2fdd08"
    private static let hashUnfollow = "f7dae976ebf41c755ae2d758546bfd176b4eeb856656098bb40e0a672ca0d880"

    /// Autre chaîne (page de chaîne) : plus rien d'affiché ni de modifiable
    /// tant que son statut n'est pas lu.
    func reset() {
        isFollowing = nil
        lastError = nil
        login = ""; channelId = ""
        localStore = nil
    }

    func load(login: String, channelId: String, token: String?) async {
        let wanted = login.lowercased()
        self.login = wanted; self.channelId = channelId
        localStore = nil
        isFollowing = nil
        lastError = nil
        guard let token = token, !login.isEmpty else { return }
        guard let res  = await TwitchGQL.shared.query("FollowButton_User",
                            variables: ["login": wanted], sha256: Self.hashStatus, token: token),
              // Réponse d'une chaîne quittée entre-temps : ignorée.
              self.login == wanted, localStore == nil,
              let data = res["data"] as? [String: Any],
              let user = data["user"] as? [String: Any] else { return }
        // user.self.follower est non-null si on suit la chaîne.
        let follower = (user["self"] as? [String: Any])?["follower"]
        isFollowing = follower != nil && !(follower is NSNull)
        logger.debug("FOLLOW", "Statut @\(self.login)", isFollowing == true ? "suivi" : "non suivi")
    }

    /// Ne plus suivre, après confirmation : jamais un abonnement, même si le
    /// statut a été relu entre le toucher et la confirmation. Selon le mode
    /// chargé : suivi de l'appareil, ou compte Twitch (session web).
    func unfollow(token: String?) async {
        if let localStore {
            guard localStore.isLocallyFollowed(login) else { isFollowing = false; return }
            localStore.toggleLocalFollow(login)
            isFollowing = localStore.isLocallyFollowed(login)
            logger.info("FOLLOW", "Suivi local retiré @\(login)", nil)
            return
        }
        guard let token, !token.isEmpty, !channelId.isEmpty, isFollowing == true, !busy else { return }
        busy = true; defer { busy = false }
        await sendUnfollow(token: token)
    }

    private func sendUnfollow(token: String) async {
        let target = channelId, who = login
        lastError = nil
        let res = await TwitchGQL.shared.mutation("FollowButton_UnfollowUser",
                    variables: ["input": ["targetID": target]],
                    sha256: Self.hashUnfollow, token: token)
        if let code = Self.refusal(res, "unfollowUser", needsFollow: false) {
            logger.warn("FOLLOW", "Unfollow échoué @\(who)", code.isEmpty ? nil : code)
            if isCurrent(target) { lastError = code }
            return
        }
        logger.success("FOLLOW", "Ne suit plus @\(who)", nil)
        // Réponse arrivée après un changement de chaîne : pas sur son état.
        if isCurrent(target) { isFollowing = false }
        NotificationCenter.default.post(name: .twitchFollowsChanged, object: nil)
    }

    /// La chaîne visée par une mutation est-elle toujours celle affichée ?
    private func isCurrent(_ target: String) -> Bool {
        channelId == target && localStore == nil
    }

    /// Refus d'une mutation de suivi (nil : réussie). Réussie seulement si
    /// `field` (followUser, unfollowUser) est un objet sans `error` (limite
    /// de suivis, chaîne qui bloque…), sans `follow` nul pour un suivi, et
    /// sans erreur GQL : sa seule présence, NSNull compris, passait pour un
    /// succès (cœur plein alors que rien n'était suivi). Le code du refus,
    /// vide si Twitch n'en donne pas.
    private static func refusal(_ res: [String: Any]?, _ field: String, needsFollow: Bool) -> String? {
        let payload = (res?["data"] as? [String: Any])?[field] as? [String: Any]
        let error = payload?["error"] as? [String: Any]
        if let payload, error == nil, res?["errors"] == nil,
           !(needsFollow && payload["follow"] is NSNull) {
            return nil
        }
        return error?["code"] as? String ?? ""
    }

    func toggle(token: String?) async {
        if let localStore, token == nil {
            localStore.toggleLocalFollow(login)
            isFollowing = localStore.isLocallyFollowed(login)
            logger.info("FOLLOW", isFollowing == true ? "Suivi local @\(login)" : "Suivi local retiré @\(login)", nil)
            return
        }
        guard let token = token, let current = isFollowing, !busy, !channelId.isEmpty else { return }
        busy = true; defer { busy = false }
        if current {
            await sendUnfollow(token: token)
        } else {
            let target = channelId, who = login
            lastError = nil
            let res = await TwitchGQL.shared.mutation("FollowButton_FollowUser",
                        variables: ["input": ["disableNotifications": false, "targetID": target]],
                        sha256: Self.hashFollow, token: token)
            if let code = Self.refusal(res, "followUser", needsFollow: true) {
                // État gardé : le cœur ne se remplit pas pour un suivi refusé.
                logger.warn("FOLLOW", "Follow échoué @\(who)", code.isEmpty ? nil : code)
                if isCurrent(target) { lastError = code }
                return
            }
            logger.success("FOLLOW", "Suit @\(who)", nil)
            if isCurrent(target) { isFollowing = true }
            NotificationCenter.default.post(name: .twitchFollowsChanged, object: nil)
        }
    }
}

// MARK: – Catégorie suivie sur Twitch
/// Ne plus suivre une catégorie sur le compte Twitch (session web), comme le
/// cœur de twitch.tv (même requête enregistrée). Vrai si Twitch l'a fait.
@MainActor
func unfollowCategoryOnTwitch(gameId: String, token: String) async -> Bool {
    let res = await TwitchGQL.shared.mutation("FollowGameButton_UnfollowGame",
                variables: ["input": ["gameID": gameId]],
                sha256: "811e02e396ebba0664f21ff002f2eff3c6f57e8af9aedb4f4dfa77cefd0db43d",
                token: token)
    let payload = (res?["data"] as? [String: Any])?["unfollowGame"] as? [String: Any]
    guard let payload, (payload["error"] as? [String: Any]) == nil, res?["errors"] == nil else {
        logger.warn("FOLLOW", "Catégorie pas retirée des suivis Twitch", gameId)
        return false
    }
    logger.success("FOLLOW", "Catégorie retirée des suivis Twitch", gameId)
    return true
}
