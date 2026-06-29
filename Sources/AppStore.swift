import Foundation
import Combine

final class AppStore: ObservableObject {

    // MARK: – Language
    @Published var lang: Lang = .fr {
        didSet { UserDefaults.standard.set(lang.rawValue, forKey: "lang") }
    }

    // MARK: – Twitch Auth
    @Published var twitchToken: String? {
        didSet {
            if let t = twitchToken { UserDefaults.standard.set(t, forKey: "twitch_token") }
            else { UserDefaults.standard.removeObject(forKey: "twitch_token") }
        }
    }
    @Published var twitchUserId: String?

    /// Token de session web (cookie `auth-token` de twitch.tv).
    /// Distinct de `twitchToken` (OAuth/Helix) : indispensable pour l'API GQL
    /// « community points » (solde, coffres, rachats), qui rejette les tokens OAuth custom.
    @Published var twitchWebToken: String? {
        didSet {
            if let t = twitchWebToken { UserDefaults.standard.set(t, forKey: "twitch_web_token") }
            else { UserDefaults.standard.removeObject(forKey: "twitch_web_token") }
        }
    }

    /// Login IRC (ex: "squeezie") — indispensable pour envoyer des messages en chat
    @Published var twitchLogin: String? {
        didSet {
            if let l = twitchLogin { UserDefaults.standard.set(l, forKey: "twitch_login") }
            else { UserDefaults.standard.removeObject(forKey: "twitch_login") }
        }
    }

    // MARK: – Proxy
    @Published var useProxy: Bool = true {
        didSet { UserDefaults.standard.set(useProxy, forKey: "twitch_use_proxy") }
    }

    // MARK: – Points
    /// Réclamer automatiquement les coffres bonus dès qu'ils sont disponibles.
    @Published var autoClaimChest: Bool = true {
        didSet { UserDefaults.standard.set(autoClaimChest, forKey: "auto_claim_chest") }
    }

    // MARK: – Lecteur
    /// Style du lecteur vidéo : natif (AVPlayerViewController) ou custom (contrôles maison).
    @Published var playerStyle: PlayerStyle = .native {
        didSet { UserDefaults.standard.set(playerStyle.rawValue, forKey: "player_style") }
    }
    /// Autorise le rembobinage des lives (DVR) dans la fenêtre fournie par Twitch.
    @Published var liveDVR: Bool = true {
        didSet { UserDefaults.standard.set(liveDVR, forKey: "live_dvr") }
    }

    // MARK: – History
    @Published var history: [HistoryItem] = [] {
        didSet { persistHistory() }
    }

    // MARK: – VOD Progress
    @Published private(set) var vodProgress: [String: Double] = [:]

    // MARK: – Init
    init() {
        let ud = UserDefaults.standard
        if let l = ud.string(forKey: "lang"), let parsed = Lang(rawValue: l) { lang = parsed }
        twitchToken = ud.string(forKey: "twitch_token")
        twitchWebToken = ud.string(forKey: "twitch_web_token")
        twitchLogin = ud.string(forKey: "twitch_login")
        useProxy = ud.object(forKey: "twitch_use_proxy") as? Bool ?? false
        autoClaimChest = ud.object(forKey: "auto_claim_chest") as? Bool ?? true
        if let ps = ud.string(forKey: "player_style"), let parsed = PlayerStyle(rawValue: ps) { playerStyle = parsed }
        liveDVR = ud.object(forKey: "live_dvr") as? Bool ?? true
        if let data = ud.data(forKey: "twitch_vod_history"),
           let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            history = decoded
        }
        if let data = ud.data(forKey: "vod_progress_all"),
           let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
            vodProgress = decoded
        }
    }

    // MARK: – Translation
    func t(_ key: String) -> String { translate(key, lang) }

    // MARK: – Auth
    func logout() {
        twitchToken    = nil
        twitchWebToken = nil
        twitchUserId   = nil
        twitchLogin    = nil   // ← nettoyage complet
    }

    // MARK: – History management
    func saveToHistory(_ item: HistoryItem) {
        var filtered = history.filter { $0.term.lowercased() != item.term.lowercased() }
        filtered.insert(item, at: 0)
        history = Array(filtered.prefix(20))
    }

    func removeFromHistory(term: String) {
        history.removeAll { $0.term == term }
    }

    func clearChannelHistory() {
        history = history.filter { $0.type == .vod }
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: "twitch_vod_history")
        }
    }

    // MARK: – VOD progress
    func getVodProgress(_ vodId: String) -> Double { vodProgress[vodId] ?? 0 }

    func setVodProgress(_ vodId: String, time: Double) {
        vodProgress[vodId] = time
        if let data = try? JSONEncoder().encode(vodProgress) {
            UserDefaults.standard.set(data, forKey: "vod_progress_all")
        }
    }

    // MARK: – Cloud Sync
    func pullFromCloud(userId: String) async {
        guard let url = URL(string: "\(kAPIURL)/api/sync/get?userId=\(userId)") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let histData = try? JSONSerialization.data(withJSONObject: json["history"] ?? []),
               let items = try? JSONDecoder().decode([HistoryItem].self, from: histData) {
                await MainActor.run { self.history = items }
            }
        } catch {}
    }

    func pushToCloud() {
        guard let userId = twitchUserId,
              let histData = try? JSONEncoder().encode(history),
              let histJSON = try? JSONSerialization.jsonObject(with: histData),
              let url = URL(string: "\(kAPIURL)/api/sync/post") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["userId": userId, "data": ["history": histJSON]])
        URLSession.shared.dataTask(with: req).resume()
    }
}
