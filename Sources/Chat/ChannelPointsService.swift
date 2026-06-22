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

    private var channelId    = ""
    private var channelLogin = ""
    private var token        = ""
    private var balanceTimer: Timer? = nil
    private var claimTimer:   Timer? = nil
    private let balancePollInterval: TimeInterval = 60
    private let claimPollInterval:   TimeInterval = 10

    // MARK: – Load
    func load(channelLogin: String, channelId: String, token: String, userLogin: String? = nil) async {
        guard !token.isEmpty, !channelId.isEmpty else {
            logger.warn("POINTS", "Chargement annulé",
                        "token ou channelId manquant — utilisateur non connecté ?")
            return
        }
        self.channelLogin = channelLogin
        self.channelId    = channelId
        self.token        = token

        // ✅ Confirmation explicite du compte utilisé pour TOUTES les requêtes de points
        if let login = userLogin {
            logger.info("POINTS", "Requêtes effectuées en tant que @\(login)",
                        "canal: \(channelLogin) · token: \(String(token.prefix(8)))…")
        } else {
            logger.info("POINTS", "Initialisation canal \(channelLogin)",
                        "channelId: \(channelId) · token: \(String(token.prefix(8)))…")
        }
        isLoading = true; errorMsg = nil

        let start = Date()
        async let rewardsTask = fetchRewards()
        async let balanceTask = fetchBalance()
        let (r, b) = await (rewardsTask, balanceTask)
        let elapsed = String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000)

        rewards = r.sorted { $0.cost < $1.cost }

        // ✅ balance = 0 si null (nouveau viewer sans historique de points)
        balance        = b?.balance  ?? 0
        pendingClaimId = b?.claimId
        logger.success("POINTS", "Chargement terminé (\(elapsed))",
                       "\(formatted(balance)) pts · \(rewards.count) récompenses · coffre: \(pendingClaimId != nil ? "OUI 🎁" : "non")")

        if b == nil {
            logger.warn("POINTS", "Balance non récupérée",
                        "0 pts par défaut (viewer sans historique ou feature non activée)")
        }
        if rewards.isEmpty {
            logger.info("POINTS", "Aucune récompense", "canal sans custom rewards configurées")
        }

        isLoading = false
        startPolling()
    }

    // MARK: – Polling
    private func startPolling() {
        stopPolling()
        logger.debug("POINTS", "Polling démarré",
                     "balance toutes les \(Int(balancePollInterval))s · claim toutes les \(Int(claimPollInterval))s")
        balanceTimer = Timer.scheduledTimer(withTimeInterval: balancePollInterval, repeats: true) { [weak self] _ in
            Task { await self?.refreshBalance() }
        }
        claimTimer = Timer.scheduledTimer(withTimeInterval: claimPollInterval, repeats: true) { [weak self] _ in
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
        let newBalance = b?.balance ?? balance  // garde l'ancienne valeur si null

        let delta = newBalance - balance
        if delta > 0 {
            logger.success("POINTS", "Points passifs gagnés",
                           "+\(delta) pts · total: \(formatted(newBalance))")
            balance = newBalance
            withAnimation { lastBalanceChange = delta }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation { lastBalanceChange = 0 }
        } else if delta < 0 {
            logger.warn("POINTS", "Balance diminuée hors-app",
                        "\(formatted(balance)) → \(formatted(newBalance)) (\(delta) pts)")
            balance = newBalance
        } else {
            logger.debug("POINTS", "Balance inchangée", "\(formatted(balance)) pts")
        }
        if pendingClaimId == nil, let cid = b?.claimId {
            pendingClaimId = cid
            logger.success("POINTS", "🎁 Coffre détecté via refresh", "claimId: \(cid.prefix(8))…")
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
        guard let json    = try? await gql(query, tag: "checkBonus") as? [String: Any],
              let data    = json["data"]                              as? [String: Any],
              let channel = data["channel"]                           as? [String: Any],
              let selfObj = channel["self"]                           as? [String: Any],
              let pts     = selfObj["communityPoints"]                as? [String: Any],
              let claim   = pts["availableClaim"]                     as? [String: Any],
              let cid     = claim["id"]                               as? String
        else {
            logger.debug("POINTS", "Pas de coffre disponible",
                         "prochain check dans \(Int(claimPollInterval))s")
            return
        }
        pendingClaimId = cid
        logger.success("POINTS", "🎁 Coffre bonus disponible !",
                       "claimId: \(cid.prefix(8))… · canal: \(channelLogin)")
    }

    // MARK: – Claim bonus
    func claimBonus() async {
        guard let claimId = pendingClaimId else {
            logger.warn("POINTS", "Claim ignoré", "aucun pendingClaimId")
            return
        }
        logger.info("POINTS", "Réclamation du coffre…",
                    "claimId: \(claimId.prefix(8))… · channelId: \(channelId)")
        let mutation = """
        mutation { claimCommunityPoints(input: {
            claimID: "\(claimId)" channelID: "\(channelId)"
        }) { currentPoints error { code } } }
        """
        guard let json  = try? await gql(mutation, tag: "claimBonus") as? [String: Any],
              let data  = json["data"]                                 as? [String: Any],
              let claim = data["claimCommunityPoints"]                 as? [String: Any]
        else { logger.error("POINTS", "Claim coffre échoué", "réponse GQL invalide"); return }

        if let err = claim["error"] as? [String: Any], let code = err["code"] as? String {
            logger.error("POINTS", "Claim refusé par Twitch", "code: \(code)")
            pendingClaimId = nil; return
        }
        if let pts = claim["currentPoints"] as? Int {
            let gained = pts - balance
            logger.success("POINTS", "🎉 Coffre réclamé !",
                           "+\(gained) pts · total: \(formatted(pts))")
            balance = pts; pendingClaimId = nil
            withAnimation { lastBalanceChange = gained }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation { lastBalanceChange = 0 }
        }
    }

    // MARK: – Redeem reward
    @discardableResult
    func redeem(reward: ChannelReward, userInput: String? = nil) async -> Bool {
        logger.info("POINTS", "Tentative rachat « \(reward.title) »",
                    "coût: \(formatted(reward.cost)) · balance: \(formatted(balance))")
        guard balance >= reward.cost else {
            let missing = reward.cost - balance
            logger.warn("POINTS", "Rachat refusé (solde insuffisant)",
                        "manque \(formatted(missing)) pts pour « \(reward.title) »")
            errorMsg = "Il te manque \(formatted(missing)) pts"
            return false
        }
        var extra = ""
        if let txt = userInput, !txt.isEmpty {
            let safe = txt.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\"",  with: "\\\"")
            extra = ", userInput: \"\(safe)\""
            logger.debug("POINTS", "Input utilisateur", "\"\(txt.prefix(60))\"")
        }
        let mutation = """
        mutation { redeemCommunityPoints(input: {
            channelID: "\(channelId)" rewardID: "\(reward.id)" \(extra)
        }) { reward { id title cost } redemption { id } error { code } } }
        """
        guard let json   = try? await gql(mutation, tag: "redeem(\(reward.title))") as? [String: Any],
              let data   = json["data"]                                               as? [String: Any],
              let result = data["redeemCommunityPoints"]                              as? [String: Any]
        else {
            logger.error("POINTS", "Rachat réseau échoué", "GQL invalide pour « \(reward.title) »")
            errorMsg = "Erreur réseau"; return false
        }
        if let err = result["error"] as? [String: Any], let code = err["code"] as? String {
            let label = redeemErrorLabel(code)
            logger.warn("POINTS", "Rachat refusé par Twitch",
                        "« \(reward.title) » · code: \(code) · \(label)")
            errorMsg = label; return false
        }
        let newBalance = max(0, balance - reward.cost)
        logger.success("POINTS", "✅ Rachat confirmé !",
                       "« \(reward.title) » · -\(formatted(reward.cost)) pts · reste: \(formatted(newBalance))")
        balance = newBalance; errorMsg = nil
        return true
    }

    // MARK: – Fetch rewards
    private func fetchRewards() async -> [ChannelReward] {
        logger.debug("POINTS", "fetchRewards → channel(name:\(channelLogin))", nil)
        let query = """
        { channel(name: "\(channelLogin)") {
            communityPointsSettings {
                isEnabled
                customRewards {
                    id title cost
                    isEnabled isPaused isInStock
                    isUserInputRequired prompt backgroundColor
                    image { url2x } defaultImage { url2x }
                }
            }
        } }
        """
        guard let json    = try? await gql(query, tag: "fetchRewards") as? [String: Any],
              let data    = json["data"]                                as? [String: Any],
              let channel = data["channel"]                             as? [String: Any]
        else {
            logger.error("POINTS", "fetchRewards : réponse GQL invalide", "channel absent")
            return []
        }

        // ── Debug brut ─────────────────────────────────────────────
        logger.debug("POINTS", "fetchRewards : clés channel",
                     channel.keys.sorted().joined(separator: ", "))

        guard let settings = channel["communityPointsSettings"] as? [String: Any] else {
            logger.warn("POINTS", "communityPointsSettings absent",
                        "le canal n'a peut-être pas de points activés")
            return []
        }

        logger.debug("POINTS", "communityPointsSettings reçu",
                     "isEnabled: \(settings["isEnabled"] ?? "nil")")

        guard settings["isEnabled"] as? Bool == true else {
            logger.warn("POINTS", "Points de chaîne désactivés", "canal: \(channelLogin)")
            return []
        }
        guard let raw = settings["customRewards"] as? [[String: Any]] else {
            logger.warn("POINTS", "customRewards null ou absent", "aucune récompense dans la réponse")
            return []
        }

        logger.debug("POINTS", "customRewards brut", "\(raw.count) entrées")

        let parsed: [ChannelReward] = raw.compactMap { r in
            guard let id    = r["id"]    as? String,
                  let title = r["title"] as? String,
                  let cost  = r["cost"]  as? Int else {
                logger.debug("POINTS", "Entrée reward ignorée",
                             "id/title/cost manquant: \(r.keys.joined(separator: ","))")
                return nil
            }
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
        }

        let active  = parsed.filter {  $0.isEnabled && !$0.isPaused }
        let paused  = parsed.filter {  $0.isPaused  }
        let noStock = parsed.filter { !$0.isInStock }

        logger.debug("POINTS", "Récompenses parsées",
                     "\(active.count) actives · \(paused.count) en pause · \(noStock.count) rupture de stock")

        let filtered = parsed.filter { $0.isEnabled }
        if filtered.isEmpty && !raw.isEmpty {
            logger.warn("POINTS", "Toutes les récompenses sont désactivées/en pause",
                        "\(raw.count) entrées ignorées")
        }
        return filtered
    }

    // MARK: – Fetch balance + claim
    private func fetchBalance() async -> (balance: Int, claimId: String?)? {
        logger.debug("POINTS", "fetchBalance → channel(name:\\(channelLogin)).self", nil)

        // On essaie plusieurs noms de champs car le schéma GQL de Twitch varie
        let query = """
        { channel(name: "\\(channelLogin)") {
            self {
                communityPoints {
                    balance
                    availablePoints
                    earnedTotal
                    availableClaim { id }
                    lastViewedContent { id contentType }
                }
            }
        } }
        """
        guard let json    = try? await gql(query, tag: "fetchBalance") as? [String: Any],
              let data    = json["data"]                                as? [String: Any],
              let channel = data["channel"]                             as? [String: Any]
        else {
            logger.error("POINTS", "fetchBalance : réponse GQL invalide", nil)
            return nil
        }

        logger.debug("POINTS", "fetchBalance : clés channel",
                     channel.keys.sorted().joined(separator: ", "))

        guard let selfObj = channel["self"] as? [String: Any] else {
            logger.warn("POINTS", "channel.self null",
                        "utilisateur non authentifié ou token insuffisant")
            return nil
        }

        logger.debug("POINTS", "channel.self clés",
                     selfObj.keys.sorted().joined(separator: ", "))

        // ── Log du JSON brut pour voir ce que Twitch renvoie réellement ──
        if let rawData = try? JSONSerialization.data(withJSONObject: selfObj),
           let rawStr  = String(data: rawData, encoding: .utf8) {
            logger.debug("POINTS", "channel.self JSON brut", String(rawStr.prefix(400)))
        }

        guard let pts = selfObj["communityPoints"] as? [String: Any] else {
            logger.warn("POINTS", "communityPoints null dans channel.self",
                        "Twitch renvoie null — problème de scope ou de token")
            return (0, nil)
        }

        // ── Log brut de communityPoints ───────────────────────────
        if let rawData = try? JSONSerialization.data(withJSONObject: pts),
           let rawStr  = String(data: rawData, encoding: .utf8) {
            logger.debug("POINTS", "communityPoints JSON brut", rawStr)
        }

        // Tente plusieurs noms de champs car le schéma change selon la version
        let bal = pts["balance"]        as? Int
               ?? pts["availablePoints"] as? Int
               ?? pts["earnedTotal"]     as? Int
               ?? 0

        let claimId = (pts["availableClaim"] as? [String: Any])?["id"] as? String

        if bal == 0 && pts["balance"] == nil {
            logger.warn("POINTS", "Champ 'balance' absent de communityPoints",
                        "champs disponibles: \\(pts.keys.sorted().joined(separator: ", "))")
        } else {
            logger.debug("POINTS", "Balance parsée",
                         "\\(formatted(bal)) pts · champ utilisé: \\(pts["balance"] != nil ? "balance" : pts["availablePoints"] != nil ? "availablePoints" : "earnedTotal") · claim: \\(claimId != nil ? "OUI" : "non")")
        }

        return (bal, claimId)
    }

    // MARK: – GQL authentifié
    private func gql(_ query: String, tag: String) async throws -> Any {
        logger.debug("POINTS/GQL", "→ \(tag)", nil)
        guard let url = URL(string: "https://gql.twitch.tv/gql") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(kGQLClientID,       forHTTPHeaderField: "Client-ID")
        req.setValue("Bearer \(token)",  forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])

        let start = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        let ms     = String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0

        guard status == 200 else {
            logger.error("POINTS/GQL", "HTTP \(status) — \(tag)", ms)
            throw URLError(.badServerResponse)
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
        case "CHANNEL_POINTS_DISABLED": return "Points désactivés sur cette chaîne"
        case "REWARD_NOT_IN_STOCK":     return "Rupture de stock"
        case "ALREADY_CLAIMED":         return "Déjà réclamé"
        case "ON_COOLDOWN":             return "Attends un peu avant de réessayer"
        default:                         return "Erreur : \(code)"
        }
    }
}
