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
    @Published var lastBalanceChange: Int = 0   // delta affiché brièvement (+50 pts)

    private var channelId    = ""
    private var channelLogin = ""
    private var token        = ""

    // Timer de polling (60 s balance / 10 s claim check)
    private var balanceTimer: Timer? = nil
    private var claimTimer:   Timer? = nil

    // MARK: – Load initial
    func load(channelLogin: String, channelId: String, token: String) async {
        guard !token.isEmpty, !channelId.isEmpty else { return }
        self.channelLogin = channelLogin
        self.channelId    = channelId
        self.token        = token
        isLoading = true; errorMsg = nil

        async let rewardsTask = fetchRewards()
        async let balanceTask = fetchBalance()
        let (r, b) = await (rewardsTask, balanceTask)

        rewards = r.sorted { $0.cost < $1.cost }
        if let b {
            balance        = b.balance
            pendingClaimId = b.claimId
        }
        isLoading = false
        logger.success("POINTS", "Canal \(channelLogin)",
                       "\(formatted(balance)) pts · \(rewards.count) récompenses")

        startPolling()
    }

    // MARK: – Polling
    private func startPolling() {
        stopPolling()

        // ── Balance : refresh toutes les 60 secondes ─────────────
        // Capture les points passifs (watching, raids, etc.)
        balanceTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.refreshBalance() }
        }

        // ── Claim check : toutes les 10 secondes ─────────────────
        // Le coffre bonus apparaît ~toutes les 15 min ; 10 s de polling
        // garantit qu'on ne le rate pas plus de 10 s.
        claimTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { await self?.checkForBonus() }
        }
    }

    func stopPolling() {
        balanceTimer?.invalidate(); balanceTimer = nil
        claimTimer?.invalidate();   claimTimer   = nil
    }

    // ─────────────────────────────────────────────────────────────
    // Refresh balance (points passifs accumulés en regardant)
    private func refreshBalance() async {
        guard let b = await fetchBalance() else { return }
        let delta = b.balance - balance
        if delta > 0 {
            balance = b.balance
            // Flash visuel du gain
            withAnimation { lastBalanceChange = delta }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation { lastBalanceChange = 0 }
            logger.debug("POINTS", "Balance mise à jour", "+\(delta) pts → \(formatted(balance))")
        }
        // Synchro claim sans déclencher la notif si déjà connu
        if pendingClaimId == nil, let claimId = b.claimId {
            pendingClaimId = claimId
            logger.success("POINTS", "🎁 Coffre bonus disponible !", channelLogin)
        }
    }

    // Vérifie uniquement si un coffre bonus est apparu
    // (requête légère, séparée du refresh balance complet)
    private func checkForBonus() async {
        guard pendingClaimId == nil else { return }   // déjà un bonus en attente
        let query = """
        {
          currentUser {
            communityPoints(channelID: "\(channelId)") {
              availableClaim { id }
            }
          }
        }
        """
        guard let json  = try? await gql(query)               as? [String: Any],
              let data  = json["data"]                         as? [String: Any],
              let user  = data["currentUser"]                  as? [String: Any],
              let pts   = user["communityPoints"]              as? [String: Any],
              let claim = pts["availableClaim"]                as? [String: Any],
              let cid   = claim["id"]                          as? String
        else { return }

        pendingClaimId = cid
        logger.success("POINTS", "🎁 Coffre bonus détecté !", channelLogin)
    }

    // MARK: – Claim bonus
    func claimBonus() async {
        guard let claimId = pendingClaimId else { return }
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
        guard let json  = try? await gql(mutation)           as? [String: Any],
              let data  = json["data"]                        as? [String: Any],
              let claim = data["claimCommunityPoints"]        as? [String: Any]
        else { return }

        if let pts = claim["currentPoints"] as? Int {
            let gained = pts - balance
            balance        = pts
            pendingClaimId = nil
            // Affiche le gain
            withAnimation { lastBalanceChange = gained }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation { lastBalanceChange = 0 }
            logger.success("POINTS", "Coffre réclamé 🎉", "+\(gained) pts → \(formatted(pts))")
        }
    }

    // MARK: – Redeem
    @discardableResult
    func redeem(reward: ChannelReward, userInput: String? = nil) async -> Bool {
        guard balance >= reward.cost else {
            errorMsg = "Pas assez de points (il te faut \(formatted(reward.cost)) pts)"
            return false
        }
        var extra = ""
        if let txt = userInput, !txt.isEmpty {
            let safe = txt
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"",  with: "\\\"")
            extra = ", userInput: \"\(safe)\""
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
        guard let json   = try? await gql(mutation)           as? [String: Any],
              let data   = json["data"]                        as? [String: Any],
              let result = data["redeemCommunityPoints"]       as? [String: Any]
        else { errorMsg = "Erreur réseau"; return false }

        if let err  = result["error"] as? [String: Any],
           let code = err["code"]     as? String {
            errorMsg = redeemErrorLabel(code)
            logger.warn("POINTS", "Rédemption échouée", code)
            return false
        }

        balance  = max(0, balance - reward.cost)
        errorMsg = nil
        logger.success("POINTS", "Récompense réclamée ✓", reward.title)
        return true
    }

    // MARK: – Fetch rewards
    private func fetchRewards() async -> [ChannelReward] {
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
        guard let json     = try? await gql(query)             as? [String: Any],
              let data     = json["data"]                       as? [String: Any],
              let comm     = data["community"]                  as? [String: Any],
              let chan     = comm["channel"]                    as? [String: Any],
              let settings = chan["communityPointsSettings"]    as? [String: Any],
              settings["isEnabled"] as? Bool == true,
              let raw      = settings["customRewards"]          as? [[String: Any]]
        else { return [] }

        return raw.compactMap { r -> ChannelReward? in
            guard let id    = r["id"]    as? String,
                  let title = r["title"] as? String,
                  let cost  = r["cost"]  as? Int else { return nil }

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
        .filter { $0.isEnabled }
    }

    // MARK: – Fetch balance + claim
    private func fetchBalance() async -> (balance: Int, claimId: String?)? {
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
        guard let json = try? await gql(query)                 as? [String: Any],
              let data = json["data"]                           as? [String: Any],
              let user = data["currentUser"]                    as? [String: Any],
              let pts  = user["communityPoints"]                as? [String: Any],
              let bal  = pts["balance"]                         as? Int
        else { return nil }

        let claimId = (pts["availableClaim"] as? [String: Any])?["id"] as? String
        return (bal, claimId)
    }

    // MARK: – GQL authentifié
    private func gql(_ query: String) async throws -> Any {
        guard let url = URL(string: "https://gql.twitch.tv/gql") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(kGQLClientID,       forHTTPHeaderField: "Client-ID")
        req.setValue("Bearer \(token)",  forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
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
