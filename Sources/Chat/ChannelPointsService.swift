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
    func load(channelLogin: String, channelId: String, token: String,
              userLogin: String? = nil) async {
        guard !token.isEmpty, !channelId.isEmpty else {
            logger.warn("POINTS", "Chargement annulé",
                        "token ou channelId manquant — utilisateur non connecté ?")
            return
        }
        self.channelLogin = channelLogin
        self.channelId    = channelId
        self.token        = token

        if let login = userLogin {
            logger.info("POINTS", "Requêtes effectuées en tant que @\(login)",
                        "canal: \(channelLogin) · token: \(String(token.prefix(8)))…")
        } else {
            logger.info("POINTS", "Initialisation canal \(channelLogin)",
                        "channelId: \(channelId)")
        }

        isLoading = true; errorMsg = nil
        let start = Date()

        async let rewardsTask = fetchRewards()
        async let balanceTask = fetchBalance()
        let (r, b) = await (rewardsTask, balanceTask)
        let elapsed = String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000)

        rewards = r.sorted { $0.cost < $1.cost }
        balance        = b?.balance  ?? 0
        pendingClaimId = b?.claimId

        logger.success("POINTS", "Chargement terminé (\(elapsed))",
                       "\(formatted(balance)) pts · \(rewards.count) récompenses"
                       + (pendingClaimId != nil ? " · 🎁 coffre dispo" : ""))

        if b == nil {
            logger.warn("POINTS", "Balance non récupérée", "0 pts par défaut")
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

    // MARK: – Refresh balance
    private func refreshBalance() async {
        logger.debug("POINTS", "Refresh balance…", "canal: \(channelLogin)")
        let b = await fetchBalance()
        let newBalance = b?.balance ?? balance

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
            logger.success("POINTS", "🎁 Coffre détecté via refresh",
                           "claimId: \(cid.prefix(8))…")
        }
    }

    // MARK: – Check bonus
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
            logger.error("POINTS", "Claim refusé", "code: \(code)")
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

    // MARK: – Redeem
    @discardableResult
    func redeem(reward: ChannelReward, userInput: String? = nil) async -> Bool {
        logger.info("POINTS", "Tentative rachat « \(reward.title) »",
                    "coût: \(formatted(reward.cost)) · balance: \(formatted(balance))")
        guard balance >= reward.cost else {
            let missing = reward.cost - balance
            logger.warn("POINTS", "Rachat refusé (solde insuffisant)",
                        "manque \(formatted(missing)) pts pour « \(reward.title) »")
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
        guard let json   = try? await gql(mutation, tag: "redeem") as? [String: Any],
              let data   = json["data"]                              as? [String: Any],
              let result = data["redeemCommunityPoints"]             as? [String: Any]
        else {
            logger.error("POINTS", "Rachat réseau échoué", "GQL invalide")
            errorMsg = "Erreur réseau"; return false
        }
        if let err = result["error"] as? [String: Any], let code = err["code"] as? String {
            let label = redeemErrorLabel(code)
            logger.warn("POINTS", "Rachat refusé par Twitch",
                        "« \(reward.title) » · \(code) · \(label)")
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
              let channel = data["channel"]                             as? [String: Any],
              let settings = channel["communityPointsSettings"]         as? [String: Any]
        else {
            logger.error("POINTS", "fetchRewards : parsing échoué",
                         "channel ou communityPointsSettings absent")
            return []
        }
        guard settings["isEnabled"] as? Bool == true else {
            logger.warn("POINTS", "Points de chaîne désactivés", "canal: \(channelLogin)")
            return []
        }
        guard let raw = settings["customRewards"] as? [[String: Any]] else {
            logger.warn("POINTS", "customRewards absent", "aucune récompense")
            return []
        }
        logger.debug("POINTS", "customRewards brut", "\(raw.count) entrées")

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

    // MARK: – Fetch balance
    // ─────────────────────────────────────────────────────────────
    // PROBLÈME IDENTIFIÉ : token émis par kHelixClientID mais requêtes
    // GQL envoyées avec kGQLClientID → mismatch → communityPoints = null
    //
    // FIX : on utilise kHelixClientID pour les requêtes de points
    // (le token a été émis par notre app, pas par le web Twitch)
    // ─────────────────────────────────────────────────────────────
    private func fetchBalance() async -> (balance: Int, claimId: String?)? {
        logger.debug("POINTS", "fetchBalance → channel(name:\(channelLogin)).self", nil)

        // Essai 1 : channel(name:).self.communityPoints avec notre Client-ID
        let query = """
        { channel(name: "\(channelLogin)") {
            self {
                communityPoints {
                    balance
                    availableClaim { id }
                }
            }
        } }
        """
        if let result = await fetchBalanceWith(query: query,
                                               clientId: kHelixClientID,
                                               tag: "fetchBalance[helixClientId]") {
            return result
        }

        // Essai 2 : même query avec le Client-ID GQL Twitch web
        logger.warn("POINTS", "Essai 2 avec kGQLClientID…", nil)
        if let result = await fetchBalanceWith(query: query,
                                               clientId: kGQLClientID,
                                               tag: "fetchBalance[gqlClientId]") {
            return result
        }

        // Essai 3 : path alternatif via user(login:).channel.self
        let altQuery = """
        { user(login: "\(channelLogin)") {
            channel {
                self {
                    communityPoints {
                        balance
                        availableClaim { id }
                    }
                }
            }
        } }
        """
        logger.warn("POINTS", "Essai 3 via user(login:).channel.self…", nil)
        if let result = await fetchBalanceWith(query: altQuery,
                                               clientId: kHelixClientID,
                                               tag: "fetchBalance[user.channel.self]") {
            return result
        }

        logger.error("POINTS", "Balance introuvable après 3 tentatives",
                     "Le schéma GQL Twitch pour les points a peut-être changé")
        return nil
    }

    private func fetchBalanceWith(query: String, clientId: String,
                                  tag: String) async -> (balance: Int, claimId: String?)? {
        guard let json = try? await gqlWith(query, clientId: clientId, tag: tag)
                         as? [String: Any],
              let data = json["data"] as? [String: Any]
        else { return nil }

        // Log brut pour diagnostic
        if let rawData = try? JSONSerialization.data(withJSONObject: data),
           let rawStr  = String(data: rawData, encoding: .utf8) {
            logger.debug("POINTS", "[\(tag)] data JSON", String(rawStr.prefix(300)))
        }

        // Chemins possibles selon la query
        let selfObj: [String: Any]?
        if let channel = data["channel"] as? [String: Any] {
            selfObj = channel["self"] as? [String: Any]
                   ?? (channel["channel"] as? [String: Any])?["self"] as? [String: Any]
        } else if let user = data["user"] as? [String: Any],
                  let chan = user["channel"] as? [String: Any] {
            selfObj = chan["self"] as? [String: Any]
        } else {
            selfObj = nil
        }

        guard let selfObj else {
            logger.warn("POINTS", "[\(tag)] self null", "chemin introuvable dans la réponse")
            return nil
        }

        guard let pts = selfObj["communityPoints"] as? [String: Any] else {
            logger.warn("POINTS", "[\(tag)] communityPoints null",
                        "self clés: \(selfObj.keys.sorted().joined(separator: ", "))")
            return nil
        }

        // Log brut de communityPoints
        if let rawData = try? JSONSerialization.data(withJSONObject: pts),
           let rawStr  = String(data: rawData, encoding: .utf8) {
            logger.debug("POINTS", "[\(tag)] communityPoints JSON", rawStr)
        }

        let bal     = pts["balance"]         as? Int
                   ?? pts["availablePoints"] as? Int
                   ?? 0
        let claimId = (pts["availableClaim"] as? [String: Any])?["id"] as? String

        logger.success("POINTS", "[\(tag)] ✅ Balance trouvée !",
                       "\(formatted(bal)) pts · claim: \(claimId != nil ? "OUI" : "non")")
        return (bal, claimId)
    }

    // MARK: – GQL (Client-ID Twitch web — pour les requêtes publiques)
    private func gql(_ query: String, tag: String) async throws -> Any {
        return try await gqlWith(query, clientId: kGQLClientID, tag: tag)
    }

    // MARK: – GQL avec Client-ID paramétrable
    private func gqlWith(_ query: String, clientId: String,
                          tag: String) async throws -> Any {
        logger.debug("POINTS/GQL", "→ \(tag)", "clientId: \(clientId.prefix(8))…")
        guard let url = URL(string: "https://gql.twitch.tv/gql") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(clientId,           forHTTPHeaderField: "Client-ID")
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
        case "CHANNEL_POINTS_DISABLED": return "Points désactivés"
        case "REWARD_NOT_IN_STOCK":     return "Rupture de stock"
        case "ALREADY_CLAIMED":         return "Déjà réclamé"
        case "ON_COOLDOWN":             return "Attends un peu"
        default:                         return "Erreur : \(code)"
        }
    }
}
