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
        if integrityTok != nil, integrityExpiry > Date().addingTimeInterval(60), !integrityDevice.isEmpty {
            return true
        }
        guard let mint = await TwitchWebGQL.shared.mintIntegrity(token: token) else { return false }
        integrityTok    = mint.token
        integrityDevice = mint.deviceId.isEmpty ? deviceId : mint.deviceId
        integrityExpiry = mint.expiry
        return true
    }

    /// Mutation persisted-query avec Client-Integrity (comme claim/redeem).
    func mutation(_ op: String, variables: [String: Any], sha256: String,
                  token: String) async -> [String: Any]? {
        guard await validIntegrity(token: token), let it = integrityTok,
              let url = URL(string: "https://gql.twitch.tv/gql"),
              let payload = persistedBody(op, variables, sha256) else { return nil }
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
            if msgs.lowercased().contains("integrity") { integrityTok = nil; integrityExpiry = .distantPast }
        }
        return first
    }
}

// MARK: – Suivre / Ne plus suivre
@MainActor
final class FollowService: ObservableObject {
    @Published var isFollowing: Bool? = nil   // nil = inconnu / en cours
    @Published var busy = false

    private var channelId = ""
    private var login = ""

    private static let hashStatus   = "1131e2a2138f219d96db8deda8eb06b217c0669e4fd33b8bed47623fc9764b33"
    private static let hashFollow   = "800e7346bdf7e5278a3c1d3f21b2b56e2639928f86815677a7126b093b2fdd08"
    private static let hashUnfollow = "f7dae976ebf41c755ae2d758546bfd176b4eeb856656098bb40e0a672ca0d880"

    func load(login: String, channelId: String, token: String?) async {
        self.login = login.lowercased(); self.channelId = channelId
        isFollowing = nil
        guard let token = token, !login.isEmpty else { return }
        guard let res  = await TwitchGQL.shared.query("FollowButton_User",
                            variables: ["login": self.login], sha256: Self.hashStatus, token: token),
              let data = res["data"] as? [String: Any],
              let user = data["user"] as? [String: Any] else { return }
        // user.self.follower est non-null si on suit la chaîne.
        let follower = (user["self"] as? [String: Any])?["follower"]
        isFollowing = follower != nil && !(follower is NSNull)
        logger.debug("FOLLOW", "Statut @\(self.login)", isFollowing == true ? "suivi" : "non suivi")
    }

    func toggle(token: String?) async {
        guard let token = token, let current = isFollowing, !busy, !channelId.isEmpty else { return }
        busy = true; defer { busy = false }
        if current {
            let res = await TwitchGQL.shared.mutation("FollowButton_UnfollowUser",
                        variables: ["input": ["targetID": channelId]],
                        sha256: Self.hashUnfollow, token: token)
            if let d = res?["data"] as? [String: Any], d["unfollowUser"] != nil, res?["errors"] == nil {
                isFollowing = false
                logger.success("FOLLOW", "Ne suit plus @\(login)", nil)
            } else { logger.warn("FOLLOW", "Unfollow échoué @\(login)", nil) }
        } else {
            let res = await TwitchGQL.shared.mutation("FollowButton_FollowUser",
                        variables: ["input": ["disableNotifications": false, "targetID": channelId]],
                        sha256: Self.hashFollow, token: token)
            if let d = res?["data"] as? [String: Any], d["followUser"] != nil, res?["errors"] == nil {
                isFollowing = true
                logger.success("FOLLOW", "Suit @\(login)", nil)
            } else { logger.warn("FOLLOW", "Follow échoué @\(login)", nil) }
        }
    }
}
