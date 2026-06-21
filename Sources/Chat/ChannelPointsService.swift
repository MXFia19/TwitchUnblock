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

    // MARK: – Load initial
    func load(channelLogin: String, channelId: String, token: String) async {
        guard !token.isEmpty, !channelId.isEmpty else {
            logger.warn("POINTS", "Chargement annulé", "token vide ou channelId manquant")
            return
        }
        self.channelLogin = channelLogin
        self.channelId    = channelId
        self.token        = token

        logger.info("POINTS", "Initialisation canal \(channelLogin)",
                    "channelId: \(channelId)")

        isLoading = true; errorMsg = nil

        let start = Date()

        async let rewardsTask = fetchRewards()
        async let balanceTask = fetchBalance()
        let (r, b) = await (rewardsTask, balanceTask)

        let elapsed = String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000)

        rewards = r.sorted { $0.cost < $1.cost }

        if let b {
            balance        = b.balance
            pendingClaimId = b.claimId
            let claimStatus = b.claimId != nil ? "🎁 Coffre disponible !" : "Pas de coffre"
            logger.success("POINTS", "Balance récupérée",
                           "\(formatted(b.balance)) pts · \(claimStatus) · \(elapsed)")
        } else {
            logger.warn("POINTS", "Balance non disponible",
                        "GQL currentUser null ou token insuffisant (\(elapsed))")
        }

        if r.isEmpty {
            logger.warn("POINTS", "Aucune récompense",
                        "Canal sans custom rewards ou points désactivés")
        } else {
            let titles = r.prefix(3).map { "\($0.title) (\(formatted($0.cost)) pts)" }.joined(separator: ", ")
            let extra  = r.count > 3 ? " +\(r.count - 3) autres" : ""
            logger.success("POINTS", "\(r.count) récompenses chargées", titles + extra)
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

        guard let b = await fetchBalance() else {
            logger.warn("POINTS", "Refresh balance échoué", "GQL sans résultat")
            return
        }

        let delta = b.balance - balance

        if delta > 0 {
            logger.success("POINTS", "Points gagnés passifs",
                           "+\(delta) pts · nouveau total: \(formatted(b.balance))")
            balance = b.balance
            withAnimation { lastBalanceChange = delta }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation { lastBalanceChange = 0 }
        } else if delta < 0 {
            // Balance diminuée (rachat depuis un autre appareil ?)
            logger.warn("POINTS", "Balance diminuée hors-app",
                        "\(formatted(balance)) → \(formatted(b.balance)) (\(delta) pts)")
            balance = b.balance
        } else {
            logger.debug("POINTS", "Balance inchangée", "\(formatted(balance)) pts")
        }

        // Coffre apparu entre deux refreshs de balance
        if pendingClaimId == nil, let claimId = b.claimId {
            pendingClaimId = claimId
            logger.success("POINTS", "🎁 Coffre bonus détecté via balance refresh",
                           "claimId: \(claimId.prefix(8))…")
        }
    }

    // MARK: – Check bonus (requête légère)
    private func checkForBonus() async {
        guard pendingClaimId == nil else {
            logger.debug("POINTS", "Check coffre ignoré", "coffre déjà en attente")
            return
        }

        logger.debug("POINTS", "Check coffre bonus…", "canal: \(channelLogin)")

        let query = """
        {
          currentUser {
            communityPoints(channelID: "\(channelId)") {
              availableClaim { id }
            }
          }
        }
        """

        guard let json  = try? await gql(query, tag: "checkBonus") as? [String: Any],
              let data  = json["data"]                              as? [String: Any],
              let user  = data["currentUser"]                       as? [String: Any],
              let pts   = user["communityPoints"]                   as? [String: Any]
        else {
            logger.debug("POINTS", "Check coffre : pas de claim actif", nil)
            return
        }

        if let claim = pts["availableClaim"] as? [String: Any],
           let cid   = claim["id"] as? String {
            pendingClaimId = cid
            logger.success("POINTS", "🎁 Coffre bonus disponible !",
                           "claimId: \(cid.prefix(8))… · canal: \(channelLogin)")
        } else {
            logger.debug("POINTS", "Pas de coffre disponible", "prochain check dans \(Int(claimPollInterval))s")
        }
    }

    // MARK: – Claim bonus
    func claimBonus() async {
        guard let claimId = pendingClaimId else {
            logger.warn("POINTS", "Claim coffre ignoré", "aucun pendingClaimId")
            return
        }

        logger.info("POINTS", "Réclamation du coffre…",
                    "claimId: \(claimId.prefix(8))… · canal: \(channelLogin)")

        let mutation = """
        mutation {
          claimCommunityPoints(input: {
            claimID:   "\(claimId)"
            channelID: "\(channelId)"
          }) {
            currentPoints
            error { code }
          }
        }
        """

        guard let json  = try? await gql(mutation, tag: "claimBonus") as? [String: Any],
              let data  = json["data"]                                 as? [String: Any],
              let claim = data["claimCommunityPoints"]                 as? [String: Any]
        else {
            logger.error("POINTS", "Claim coffre échoué", "réponse GQL invalide")
            return
        }

        if let err  = claim["error"] as? [String: Any],
           let code = err["code"]    as? String {
            logger.error("POINTS", "Claim coffre refusé", "code: \(code)")
            pendingClaimId = nil
            return
        }

        if let pts = claim["currentPoints"] as? Int {
            let gained = pts - balance
            logger.success("POINTS", "🎉 Coffre réclamé !",
                           "+\(gained) pts · total: \(formatted(pts))")
            balance        = pts
            pendingClaimId = nil
            withAnimation { lastBalanceChange = gained }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation { lastBalanceChange = 0 }
        }
    }

    // MARK: – Redeem reward
    @discardableResult
    func redeem(reward: ChannelReward, userInput: String? = nil) async -> Bool {
        logger.info("POINTS", "Tentative de rachat",
                    "« \(reward.title) » · coût: \(formatted(reward.cost)) pts · balance: \(formatted(balance)) pts")

        guard balance >= reward.cost else {
            let missing = reward.cost - balance
            logger.warn("POINTS", "Rachat refusé localement",
                        "manque \(formatted(missing)) pts pour « \(reward.title) »")
            errorMsg = "Il te manque \(formatted(missing)) pts"
            return false
        }

        var extra = ""
        if let txt = userInput, !txt.isEmpty {
            let safe = txt
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"",  with: "\\\"")
            extra = ", userInput: \"\(safe)\""
            logger.debug("POINTS", "Récompense avec saisie utilisateur",
                         "input: \"\(txt.prefix(50))\"")
        }

        let mutation = """
        mutation {
          redeemCommunityPoints(input: {
            channelID: "\(channelId)"
            rewardID:  "\(reward.id)"
            \(extra)
          }) {
            reward     { id title cost }
            redemption { id }
            error      { code }
          }
        }
        """

        guard let json   = try? await gql(mutation, tag: "redeem") as? [String: Any],
              let data   = json["data"]                             as? [String: Any],
              let result = data["redeemCommunityPoints"]            as? [String: Any]
        else {
            logger.error("POINTS", "Rachat réseau échoué",
                         "réponse GQL invalide pour « \(reward.title) »")
            errorMsg = "Erreur réseau"
            return false
        }

        if let err  = result["error"] as? [String: Any],
           let code = err["code"]     as? String {
            let label = redeemErrorLabel(code)
            logger.warn("POINTS", "Rachat refusé par Twitch",
                        "« \(reward.title) » · code: \(code) · \(label)")
            errorMsg = label
            return false
        }

        let newBalance = max(0, balance - reward.cost)
        logger.success("POINTS", "✅ Rachat confirmé !",
                       "« \(reward.title) » · -\(formatted(reward.cost)) pts · reste: \(formatted(newBalance)) pts")
        balance  = newBalance
        errorMsg = nil
        return true
    }

    // MARK: – Fetch rewards (GQL)
    private func fetchRewards() async -> [ChannelReward] {
        logger.debug("POINTS", "Chargement des récompenses…", "canal: \(channelLogin)")

        let query = """
        {
          community(login: "\(channelLogin)") {
            channel {
              communityPointsSettings {
                isEnabled
                customRewards {
                  id title cost
                  isEnabled isPaused isInStock
                  isUserInputRequired prompt backgroundColor
                  image        { url2x }
                  defaultImage { url2x }
                }
              }
            }
          }
        }
        """

        guard let json     = try? await gql(query, tag: "fetchRewards") as? [String: Any],
              let data     = json["data"]                                as? [String: Any],
              let comm     = data["community"]                           as? [String: Any],
              let chan     = comm["channel"]                             as? [String: Any],
              let settings = chan["communityPointsSettings"]             as? [String: Any]
        else {
            logger.error("POINTS", "fetchRewards GQL échoué", "réponse inattendue")
            return []
        }

        guard settings["isEnabled"] as? Bool == true else {
            logger.warn("POINTS", "Points de chaîne désactivés", "canal: \(channelLogin)")
            return []
        }

        guard let raw = settings["customRewards"] as? [[String: Any]] else {
            logger.warn("POINTS", "customRewards absent", "champ manquant dans GQL")
            return []
        }

        let parsed: [ChannelReward] = raw.compactMap { r in
            guard let id    = r["id"]    as? String,
                  let title = r["title"] as? String,
                  let cost  = r["cost"]  as? Int else {
                logger.debug("POINTS", "Récompense ignorée", "champs id/title/cost manquants")
                return nil
            }
            let imageURL = (r["image"]        as? [String: Any])?["url2x"] as? String
                        ?? (r["defaultImage"] as? [String: Any])?["url2x"] as? String

            return ChannelReward(
                id: id, title: title, cost: cost,
                isEnabled:           r["isEnabled"]           as? Bool ?? false,
                isInStock:           r["isInStock"]           as? Bool ?? true,
                isPaused:            r["isPaused"]            as? Bool ?? false,
                isUserInputRequired: r["isUserInputRequired"] as? Bool ?? false,
                prompt:              r["prompt"]              as? String,
                backgroundColor:    (r["backgroundColor"]    as? String ?? "9147FF")
                                        .trimmingCharacters(in: CharacterSet(charactersIn: "#")),
                imageURL: imageURL
            )
        }
        .filter { r in
            if !r.isEnabled {
                logger.debug("POINTS", "Récompense filtrée (désactivée)", r.title)
            }
            return r.isEnabled
        }

        let paused  = parsed.filter { $0.isPaused  }.count
        let noStock = parsed.filter { !$0.isInStock }.count
        logger.debug("POINTS", "Récompenses parsées",
                     "\(parsed.count) actives · \(paused) en pause · \(noStock) rupture")

        return parsed
    }

    // MARK: – Fetch balance + claim
    private func fetchBalance() async -> (balance: Int, claimId: String?)? {
        logger.debug("POINTS", "Fetch balance…", "channelId: \(channelId)")

        let query = """
        {
          currentUser {
            communityPoints(channelID: "\(channelId)") {
              balance
              availableClaim { id }
            }
          }
        }
        """

        guard let json = try? await gql(query, tag: "fetchBalance") as? [String: Any],
              let data = json["data"]                                as? [String: Any]
        else {
            logger.error("POINTS", "fetchBalance GQL échoué", "réponse invalide")
            return nil
        }

        guard let user = data["currentUser"] as? [String: Any] else {
            logger.warn("POINTS", "fetchBalance : currentUser null",
                        "token invalide ou scope insuffisant")
            return nil
        }

        guard let pts = user["communityPoints"] as? [String: Any],
              let bal = pts["balance"]           as? Int
        else {
            logger.warn("POINTS", "fetchBalance : communityPoints null",
                        "channelId inconnu ou feature non activée")
            return nil
        }

        let claimId = (pts["availableClaim"] as? [String: Any])?["id"] as? String
        logger.debug("POINTS", "Balance parsée",
                     "\(formatted(bal)) pts · claim: \(claimId != nil ? "OUI" : "non")")
        return (bal, claimId)
    }

    // MARK: – GQL authentifié
    private func gql(_ query: String, tag: String) async throws -> Any {
        logger.debug("POINTS/GQL", "→ \(tag)", "channelId: \(channelId.isEmpty ? "–" : channelId)")

        guard let url = URL(string: "https://gql.twitch.tv/gql") else {
            logger.error("POINTS/GQL", "URL invalide", tag)
            throw URLError(.badURL)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(kGQLClientID,       forHTTPHeaderField: "Client-ID")
        req.setValue("Bearer \(token)",  forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])

        let start = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        let ms = String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0

        guard status == 200 else {
            logger.error("POINTS/GQL", "HTTP \(status) pour \(tag)", "\(ms)")
            throw URLError(.badServerResponse)
        }

        // Log des erreurs GQL éventuelles dans la réponse
        if let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errors = json["errors"] as? [[String: Any]] {
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
        f.numberStyle       = .decimal
        f.groupingSeparator = " "
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
