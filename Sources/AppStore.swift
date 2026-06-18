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
        twitchLogin = ud.string(forKey: "twitch_login")
        useProxy = ud.object(forKey: "twitch_use_proxy") as? Bool ?? false
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
        twitchToken  = nil
        twitchUserId = nil
        twitchLogin  = nil   // ← nettoyage complet
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
