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

    /// Photo de profil du compte connecté, affichée dans l'en-tête.
    @Published var twitchAvatar: String? {
        didSet {
            if let a = twitchAvatar { UserDefaults.standard.set(a, forKey: "twitch_avatar") }
            else { UserDefaults.standard.removeObject(forKey: "twitch_avatar") }
        }
    }

    /// Login IRC (ex: "squeezie") — indispensable pour envoyer des messages en chat
    @Published var twitchLogin: String? {
        didSet {
            if let l = twitchLogin { UserDefaults.standard.set(l, forKey: "twitch_login") }
            else { UserDefaults.standard.removeObject(forKey: "twitch_login") }
        }
    }

    // MARK: – Points
    /// Réclamer automatiquement les coffres bonus dès qu'ils sont disponibles.
    @Published var autoClaimChest: Bool = true {
        didSet { UserDefaults.standard.set(autoClaimChest, forKey: "auto_claim_chest") }
    }

    // MARK: – Personnalisation chat / lecteur
    /// Afficher le bandeau des messages épinglés.
    @Published var showPinnedMessages: Bool = true {
        didSet { UserDefaults.standard.set(showPinnedMessages, forKey: "cfg_pinned") }
    }
    /// Afficher le bouton Suivre / Ne plus suivre.
    @Published var showFollowButton: Bool = true {
        didSet { UserDefaults.standard.set(showFollowButton, forKey: "cfg_follow") }
    }
    /// Afficher le badge de série de visionnage (streak).
    @Published var showWatchStreak: Bool = true {
        didSet { UserDefaults.standard.set(showWatchStreak, forKey: "cfg_streak") }
    }
    /// Afficher les événements live (sondages, prédictions, hype train).
    @Published var showLiveEvents: Bool = true {
        didSet { UserDefaults.standard.set(showLiveEvents, forKey: "cfg_events") }
    }
    /// Activer la détection des raids (bannière + auto-rejoindre).
    @Published var enableRaids: Bool = true {
        didSet { UserDefaults.standard.set(enableRaids, forKey: "cfg_raids") }
    }
    /// Vider le cache des emotes/badges en quittant le live (et l'app).
    @Published var autoPurgeImageCache: Bool = true {
        didSet { UserDefaults.standard.set(autoPurgeImageCache, forKey: "cfg_purge_cache") }
    }

    // MARK: – Lecteur
    /// Mode faible latence : demande le flux « low latency » à Twitch et garde
    /// la lecture au plus près du direct.
    @Published var lowLatency: Bool = false {
        didSet { UserDefaults.standard.set(lowLatency, forKey: "cfg_low_latency") }
    }

    // MARK: – Débogage (section temporaire)
    /// Afficher la latence du direct par-dessus le lecteur.
    @Published var showLatency: Bool = false {
        didSet { UserDefaults.standard.set(showLatency, forKey: "dbg_latency") }
    }
    /// Retarder le chat de la latence mesurée, pour qu'il colle à l'image.
    @Published var autoChatDelay: Bool = false {
        didSet { UserDefaults.standard.set(autoChatDelay, forKey: "dbg_chat_delay") }
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
        twitchAvatar = ud.string(forKey: "twitch_avatar")
        autoClaimChest = ud.object(forKey: "auto_claim_chest") as? Bool ?? true
        showPinnedMessages = ud.object(forKey: "cfg_pinned") as? Bool ?? true
        showFollowButton   = ud.object(forKey: "cfg_follow") as? Bool ?? true
        showWatchStreak    = ud.object(forKey: "cfg_streak") as? Bool ?? true
        showLiveEvents     = ud.object(forKey: "cfg_events") as? Bool ?? true
        enableRaids        = ud.object(forKey: "cfg_raids")  as? Bool ?? true
        autoPurgeImageCache = ud.object(forKey: "cfg_purge_cache") as? Bool ?? true
        lowLatency         = ud.object(forKey: "cfg_low_latency") as? Bool ?? false
        showLatency        = ud.object(forKey: "dbg_latency")    as? Bool ?? false
        autoChatDelay      = ud.object(forKey: "dbg_chat_delay") as? Bool ?? false
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
        twitchAvatar   = nil
    }

    // MARK: – History management
    func saveToHistory(_ item: HistoryItem) {
        var filtered = history.filter { $0.term.lowercased() != item.term.lowercased() }
        filtered.insert(item, at: 0)
        // 50 : l'historique mélange chaînes et VODs, 20 faisait disparaître les
        // VODs vues dès qu'on enchaînait quelques recherches de streamers.
        history = Array(filtered.prefix(50))
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
