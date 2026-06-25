import Foundation
import SwiftUI

// MARK: – Models
struct ChannelReward: Identifiable, Equatable {
    let id: String
    let title: String
    let cost: Int
    let isEnabled: Bool
    let isInStock: Bool
    let isPaused: Bool
    let isUserInputRequired: Bool
    let prompt: String?
    let backgroundColor: String
    let imageURL: String?
    var canRedeem: Bool { isEnabled && isInStock && !isPaused }
}

// MARK: – Service
@MainActor
final class ChannelPointsService: ObservableObject {
    @Published var balance: Int = 0
    @Published var rewards: [ChannelReward] = []
    @Published var isLoading = false
    @Published var errorMsg: String? = nil
    @Published var pendingClaimId: String? = nil
    @Published var lastBalanceChange: Int = 0
    @Published var needsReauth = false   // observé par ChatView pour déclencher le re-login

    private var channelId    = ""
    private var channelLogin = ""
    private var token        = ""
    private var balanceTimer: Timer? = nil
    private var claimTimer:   Timer? = nil
    private let balancePollInterval: TimeInterval = 60
    private let claimPollInterval:   TimeInterval = 10

    // MARK: – Load
    func load(channelLogin: String, channelId: String, token: String,
              userLogin: String? = nil) async {
        guard !token.isEmpty, !channelId.isEmpty else {
            logger.warn("POINTS", "Chargement annulé", "token ou channelId manquant")
            return
        }
        self.channelLogin = channelLogin
        self.channelId    = channelId
        self.token        = token
        needsReauth       = false

        logger.info("POINTS", "Chargement canal \(channelLogin)",
                    "compte: @\(userLogin ?? "?") · token: \(String(token.prefix(8)))… · auth: OAuth")

        isLoading = true; errorMsg = nil
        let start = Date()

        // fetchRewards = public (pas d'auth)
        // fetchBalance = privé (OAuth requis)
        async let rewardsTask = fetchRewards()
        async let balanceTask = fetchBalance()
        let (r, b) = await (rewardsTask, balanceTask)
        let elapsed = String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000)

        rewards        = r.sorted { $0.cost < $1.cost }
        balance        = b.balance
        pendingClaimId = b.claimId

        logger.success("POINTS", "Chargement terminé (\(elapsed))",
                       "\(formatted(balance)) pts · \(rewards.count) récompenses"
                       + (pendingClaimId != nil ? " · 🎁 coffre dispo" : ""))

        if rewards.isEmpty {
            logger.info("POINTS", "Aucune récompense", "canal sans custom rewards")
        }
        isLoading = false
        startPolling()
    }

    // MARK: – Polling
    private func startPolling() {
        stopPolling()
        logger.debug("POINTS", "Polling démarré",
                     "balance: \(Int(balancePollInterval))s · claim: \(Int(claimPollInterval))s")
        balanceTimer = Timer.scheduledTimer(withTimeInterval: balancePollInterval,
                                            repeats: true) { [weak self] _ in
            Task { await self?.refreshBalance() }
        }
        claimTimer = Timer.scheduledTimer(withTimeInterval: claimPollInterval,
                                           repeats: true) { [weak self] _ in
            Task { await self?.checkForBonus() }
        }
    }

    func stopPolling() {
        if balanceTimer != nil || claimTimer != nil {
            logger.debug("POINTS", "Polling arrêté", "canal: \(channelLogin)")
        }
        balanceTimer?.invalidate(); balanceTimer = nil
        claimTimer?.invalidate();   claimTimer   = nil
    }

    // MARK: – Refresh balance (60s)
    private func refreshBalance() async {
        logger.debug("POINTS", "Refresh balance…", "canal: \(channelLogin)")
        let b = await fetchBalance()
        let delta = b.balance - balance
        if delta > 0 {
            logger.success("POINTS", "Points passifs gagnés",
                           "+\(delta) pts · total: \(formatted(b.balance))")
            balance = b.balance
            withAnimation { lastBalanceChange = delta }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation { lastBalanceChange = 0 }
        } else if delta < 0 {
            logger.warn("POINTS", "Balance diminuée", "\(formatted(balance)) → \(formatted(b.balance))")
            balance = b.balance
        } else {
            logger.debug("POINTS", "Balance inchangée", "\(formatted(balance)) pts")
        }
        if pendingClaimId == nil, let cid = b.claimId {
            pendingClaimId = cid
            logger.success("POINTS", "🎁 Coffre détecté", "claimId: \(cid.prefix(8))…")
        }
    }

    // MARK: – Check bonus (10s)
    private func checkForBonus() async {
        guard pendingClaimId == nil else { return }
        let query = """
        { channel(name: "\(channelLogin)") {
            self { communityPoints { availableClaim { id } } }
        } }
        """
        guard let json    = try? await gqlAuth(query, tag: "checkBonus") as? [String: Any],
              let data    = json["data"]                                   as? [String: Any],
              let channel = data["channel"]                                as? [String: Any],
              let selfObj = channel["self"]                                as? [String: Any],
              let pts     = selfObj["communityPoints"]                     as? [String: Any],
              let claim   = pts["availableClaim"]                          as? [String: Any],
              let cid     = claim["id"]                                    as? String
        else {
            logger.debug("POINTS", "Pas de coffre disponible", nil)
            return
        }
        pendingClaimId = cid
        logger.success("POINTS", "🎁 Coffre bonus disponible !",
                       "claimId: \(cid.prefix(8))… · canal: \(channelLogin)")
    }

    // MARK: – Claim bonus
    func claimBonus() async {
        guard let claimId = pendingClaimId else { return }
        logger.info("POINTS", "Réclamation du coffre…", "claimId: \(claimId.prefix(8))…")
        let mutation = """
        mutation { claimCommunityPoints(input: {
            claimID: "\(claimId)" channelID: "\(channelId)"
        }) { currentPoints error { code } } }
        """
        guard let json  = try? await gqlAuth(mutation, tag: "claimBonus") as? [String: Any],
              let data  = json["data"]                                     as? [String: Any],
              let claim = data["claimCommunityPoints"]                     as? [String: Any]
        else { logger.error("POINTS", "Claim coffre échoué", nil); return }

        if let err = claim["error"] as? [String: Any], let code = err["code"] as? String {
            logger.error("POINTS", "Claim refusé", "code: \(code)")
            pendingClaimId = nil; return
        }
        if let pts = claim["currentPoints"] as? Int {
            let gained = pts - balance
            logger.success("POINTS", "🎉 Coffre réclamé !", "+\(gained) pts · total: \(formatted(pts))")
            balance = pts; pendingClaimId = nil
            withAnimation { lastBalanceChange = gained }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation { lastBalanceChange = 0 }
        }
    }

    // MARK: – Redeem
    @discardableResult
    func redeem(reward: ChannelReward, userInput: String? = nil) async -> Bool {
        logger.info("POINTS", "Tentative rachat « \(reward.title) »",
                    "coût: \(formatted(reward.cost)) · balance: \(formatted(balance))")
        guard balance >= reward.cost else {
            let missing = reward.cost - balance
            logger.warn("POINTS", "Solde insuffisant", "manque \(formatted(missing)) pts")
            errorMsg = "Il te manque \(formatted(missing)) pts"; return false
        }
        var extra = ""
        if let txt = userInput, !txt.isEmpty {
            let safe = txt.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\"",  with: "\\\"")
            extra = ", userInput: \"\(safe)\""
        }
        let mutation = """
        mutation { redeemCommunityPoints(input: {
            channelID: "\(channelId)" rewardID: "\(reward.id)" \(extra)
        }) { reward { id title cost } redemption { id } error { code } } }
        """
        guard let json   = try? await gqlAuth(mutation, tag: "redeem") as? [String: Any],
              let data   = json["data"]                                   as? [String: Any],
              let result = data["redeemCommunityPoints"]                  as? [String: Any]
        else { logger.error("POINTS", "Rachat réseau échoué", nil); errorMsg = "Erreur réseau"; return false }

        if let err = result["error"] as? [String: Any], let code = err["code"] as? String {
            logger.warn("POINTS", "Rachat refusé", "\(code)")
            errorMsg = redeemErrorLabel(code); return false
        }
        let newBalance = max(0, balance - reward.cost)
        logger.success("POINTS", "✅ Rachat confirmé !",
                       "« \(reward.title) » · reste: \(formatted(newBalance)) pts")
        balance = newBalance; errorMsg = nil
        return true
    }

    // MARK: – Fetch rewards (SANS auth — données publiques)
    private func fetchRewards() async -> [ChannelReward] {
        logger.debug("POINTS", "fetchRewards → channel(name:\(channelLogin))", nil)
        let query = """
        { channel(name: "\(channelLogin)") {
            communityPointsSettings {
                isEnabled
                customRewards {
                    id title cost isEnabled isPaused isInStock
                    isUserInputRequired prompt backgroundColor
                    image { url2x } defaultImage { url2x }
                }
            }
        } }
        """
        // ✅ Pas d'Authorization ici — données publiques, pas de 401 possible
        guard let json     = try? await gqlPublic(query, tag: "fetchRewards") as? [String: Any],
              let data     = json["data"]                                      as? [String: Any],
              let channel  = data["channel"]                                   as? [String: Any],
              let settings = channel["communityPointsSettings"]                as? [String: Any]
        else { logger.warn("POINTS", "fetchRewards : parsing échoué", nil); return [] }

        guard settings["isEnabled"] as? Bool == true else {
            logger.info("POINTS", "Points désactivés", nil); return []
        }
        guard let raw = settings["customRewards"] as? [[String: Any]] else {
            logger.info("POINTS", "Aucune custom reward", nil); return []
        }
        let parsed: [ChannelReward] = raw.compactMap { r in
            guard let id    = r["id"]    as? String,
                  let title = r["title"] as? String,
                  let cost  = r["cost"]  as? Int else { return nil }
            return ChannelReward(
                id: id, title: title, cost: cost,
                isEnabled:           r["isEnabled"]           as? Bool ?? false,
                isInStock:           r["isInStock"]           as? Bool ?? true,
                isPaused:            r["isPaused"]            as? Bool ?? false,
                isUserInputRequired: r["isUserInputRequired"] as? Bool ?? false,
                prompt:              r["prompt"]              as? String,
                backgroundColor:    (r["backgroundColor"]    as? String ?? "9147FF")
                                        .trimmingCharacters(in: CharacterSet(charactersIn: "#")),
                imageURL: (r["image"]        as? [String: Any])?["url2x"] as? String
                       ?? (r["defaultImage"] as? [String: Any])?["url2x"] as? String
            )
        }.filter { $0.isEnabled }
        logger.debug("POINTS", "Récompenses parsées",
                     "\(parsed.count) actives · \(parsed.filter { $0.isPaused }.count) en pause")
        return parsed
    }

    // MARK: – Fetch balance (AVEC auth OAuth)
    private func fetchBalance() async -> (balance: Int, claimId: String?) {
        logger.debug("POINTS", "fetchBalance → channel(name:\(channelLogin)).self", nil)
        let query = """
        { channel(name: "\(channelLogin)") {
            self { communityPoints { balance availableClaim { id } } }
        } }
        """
        guard let json    = try? await gqlAuth(query, tag: "fetchBalance") as? [String: Any],
              let data    = json["data"]                                    as? [String: Any],
              let channel = data["channel"]                                 as? [String: Any],
              let selfObj = channel["self"]                                 as? [String: Any]
        else {
            logger.warn("POINTS", "fetchBalance : parsing échoué", nil)
            return (0, nil)
        }
        guard let pts = selfObj["communityPoints"] as? [String: Any] else {
            logger.info("POINTS", "communityPoints null — premier visionnage ou token incompatible",
                        "balance = 0")
            return (0, nil)
        }
        let bal     = pts["balance"] as? Int ?? 0
        let claimId = (pts["availableClaim"] as? [String: Any])?["id"] as? String
        logger.success("POINTS", "Balance récupérée",
                       "\(formatted(bal)) pts · claim: \(claimId != nil ? "🎁 OUI" : "non")")
        return (bal, claimId)
    }

    // MARK: – GQL public (sans Authorization — pour les données publiques)
    private func gqlPublic(_ query: String, tag: String) async throws -> Any {
        return try await makeGQLRequest(query, tag: tag, withAuth: false)
    }

    // MARK: – GQL authentifié (avec Authorization: OAuth — pour les données privées)
    // ✅ OAuth confirmé fonctionnel sur IMG_0373 (balance: 9317)
    // ❌ Bearer → communityPoints null (pas d'erreur mais données vides)
    private func gqlAuth(_ query: String, tag: String) async throws -> Any {
        return try await makeGQLRequest(query, tag: tag, withAuth: true)
    }

    private func makeGQLRequest(_ query: String, tag: String,
                                 withAuth: Bool) async throws -> Any {
        logger.debug("POINTS/GQL", "→ \(tag)", withAuth ? "OAuth" : "public")
        guard let url = URL(string: "https://gql.twitch.tv/gql") else { throw URLError(.badURL) }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(kGQLClientID,       forHTTPHeaderField: "Client-ID")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if withAuth {
            req.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])

        let start = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        let ms     = String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0

        guard status == 200 else {
            if status == 401 && withAuth {
                logger.warn("POINTS/GQL", "401 — token incompatible avec GQL Twitch",
                            "tag: \(tag) · token: \(String(token.prefix(8)))… · \(ms)")
                stopPolling()
                needsReauth = true   // déclenche le re-login dans ChatView
            } else {
                logger.error("POINTS/GQL", "HTTP \(status) — \(tag)", ms)
            }
            throw URLError(.userAuthenticationRequired)
        }

        if let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
            let msgs = errors.compactMap { $0["message"] as? String }.joined(separator: " · ")
            logger.warn("POINTS/GQL", "Erreurs GQL dans \(tag)", msgs + " (\(ms))")
        } else {
            logger.debug("POINTS/GQL", "← \(tag) OK", ms)
        }

        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: – Helpers
    func formatted(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal; f.groupingSeparator = " "
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func redeemErrorLabel(_ code: String) -> String {
        switch code {
        case "NOT_ENOUGH_POINTS":       return "Pas assez de points"
        case "REWARD_NOT_FOUND":        return "Récompense introuvable"
        case "CHANNEL_POINTS_DISABLED": return "Points désactivés"
        case "REWARD_NOT_IN_STOCK":     return "Rupture de stock"
        case "ALREADY_CLAIMED":         return "Déjà réclamé"
        case "ON_COOLDOWN":             return "Attends un peu"
        default:                         return "Erreur : \(code)"
        }
    }
}
