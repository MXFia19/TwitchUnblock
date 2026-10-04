import Foundation
import Combine
import UIKit

final class AppStore: ObservableObject {

    // MARK: – Language
    /// L'anglais par défaut : l'app n'est pas réservée à un public français.
    @Published var lang: Lang = .en {
        didSet { UserDefaults.standard.set(lang.rawValue, forKey: "lang") }
    }

    // MARK: – Twitch Auth
    @Published var twitchToken: String? {
        didSet {
            Keychain.storeToken(twitchToken, for: "twitch_token")
        }
    }
    /// Gardé entre deux lancements : l'envoi de la sauvegarde au passage en
    /// arrière-plan doit savoir pour qui écrire, même avant que l'accueil
    /// n'ait rechargé le profil.
    @Published var twitchUserId: String? {
        didSet {
            if let id = twitchUserId { UserDefaults.standard.set(id, forKey: "twitch_user_id") }
            else { UserDefaults.standard.removeObject(forKey: "twitch_user_id") }
        }
    }

    /// Token de session web (cookie `auth-token` de twitch.tv).
    /// Distinct de `twitchToken` (OAuth/Helix) : indispensable pour l'API GQL
    /// « community points » (solde, coffres, rachats), qui rejette les tokens OAuth custom.
    @Published var twitchWebToken: String? {
        didSet {
            Keychain.storeToken(twitchWebToken, for: "twitch_web_token")
        }
    }

    /// La session web a été rejetée par Twitch : elle a été effacée, il faut
    /// se reconnecter. Distinct de « absente » — on ne veut pas harceler
    /// quelqu'un qui ne s'en est jamais servi.
    @Published var webSessionExpired = false

    /// Vérifie la session web et l'efface si Twitch la refuse. Une panne
    /// réseau ne l'efface pas : couper la session sur un wifi capricieux
    /// serait pire que de la laisser mourir en silence.
    @MainActor
    func validateWebSession() async {
        guard let token = twitchWebToken, !token.isEmpty else { return }
        if await isWebSessionValid(token: token) {
            webSessionExpired = false
        } else {
            twitchWebToken = nil
            webSessionExpired = true
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

    /// Lecteur immersif : commandes par-dessus l'image, comme sur Twitch.
    /// Désactivé = lecteur natif Apple (PiP et plein écran système).
    /// Activé par défaut : c'est le lecteur de l'app, le natif est le repli.
    @Published var immersivePlayer: Bool = true {
        didSet { UserDefaults.standard.set(immersivePlayer, forKey: "cfg_immersive") }
    }

    /// Recadrer la vidéo pour remplir l'écran, au lieu de laisser des bandes
    /// noires. Coupe le haut et le bas : du 16:9 dans un écran de téléphone en
    /// paysage (≈2.16) ne peut pas à la fois tout montrer et tout remplir.
    @Published var fillScreen: Bool = false {
        didSet { UserDefaults.standard.set(fillScreen, forKey: "cfg_fill_screen") }
    }

    /// Place du chat en paysage : colonne, superposé à l'image, ou replié.
    /// Mémorisé, parce qu'on choisit ça une fois puis on n'y revient plus.
    @Published var landscapeChat: LandscapeChat = .column {
        didSet { UserDefaults.standard.set(landscapeChat.rawValue, forKey: "cfg_landscape_chat") }
    }

    // MARK: – Apparence du chat
    // La bonne taille dépend de l'écran, de la distance de lecture et de la vue
    // de chacun : autant la laisser se régler plutôt que d'en imposer une.
    @Published var chatFontSize: Double = 13 {
        didSet { UserDefaults.standard.set(chatFontSize, forKey: "cfg_chat_font") }
    }
    /// Espace vertical entre deux messages, en points. Chaque message en porte
    /// la moitié en haut et en bas : 8 reproduit l'aspect d'origine.
    @Published var chatSpacing: Double = 8 {
        didSet { UserDefaults.standard.set(chatSpacing, forKey: "cfg_chat_spacing") }
    }
    @Published var chatBadgeScale: Double = 1 {
        didSet { UserDefaults.standard.set(chatBadgeScale, forKey: "cfg_chat_badge") }
    }
    @Published var chatEmoteScale: Double = 1 {
        didSet { UserDefaults.standard.set(chatEmoteScale, forKey: "cfg_chat_emote") }
    }
    @Published var chatTimestamps: Bool = true {
        didSet { UserDefaults.standard.set(chatTimestamps, forKey: "cfg_chat_time") }
    }
    /// Part de la largeur prise par le chat en paysage (colonne ou calque).
    @Published var chatWidthRatio: Double = 0.32 {
        didSet { UserDefaults.standard.set(chatWidthRatio, forKey: "cfg_chat_width") }
    }

    // MARK: – Comportement du chat
    /// Charger les derniers messages du canal à l'arrivée (API tierce
    /// recent-messages.robotty.de : Twitch n'envoie rien d'antérieur au JOIN).
    @Published var chatLoadRecent: Bool = true {
        didSet { UserDefaults.standard.set(chatLoadRecent, forKey: "cfg_chat_recent") }
    }
    /// Proposer emotes et pseudos pendant la frappe.
    @Published var chatAutocomplete: Bool = true {
        didSet { UserDefaults.standard.set(chatAutocomplete, forKey: "cfg_chat_autocomplete") }
    }
    /// Garder les messages supprimés, barrés, au lieu de les faire disparaître.
    @Published var chatShowDeleted: Bool = false {
        didSet { UserDefaults.standard.set(chatShowDeleted, forKey: "cfg_chat_deleted") }
    }

    /// Construit la présentation du chat : les réglages de l'utilisateur pour la
    /// taille, la disposition en cours pour le décor et la transparence.
    func chatStyle(chrome: Bool, translucent: Bool) -> ChatStyle {
        ChatStyle(showsChrome: chrome,
                  showsTimestamp: chatTimestamps,
                  fontSize: CGFloat(chatFontSize),
                  rowPadding: CGFloat(chatSpacing) / 2,
                  badgeScale: CGFloat(chatBadgeScale),
                  emoteScale: CGFloat(chatEmoteScale),
                  translucent: translucent)
    }

    // MARK: – Comptage d'utilisation
    /// Signaler anonymement que cette installation est active.
    /// Voir Sources/Services/UsageService.swift pour ce qui part réellement.
    @Published var shareUsage: Bool = true {
        didSet { UserDefaults.standard.set(shareUsage, forKey: "cfg_share_usage") }
    }

    /// Chaîne à ouvrir dans l'onglet Recherche (depuis le lecteur, l'accueil…).
    /// L'onglet la consomme puis la remet à nil.
    @Published var pendingChannel: String? = nil
    func openChannelPage(_ login: String) {
        let l = login.trimmingCharacters(in: .whitespaces).lowercased()
        guard !l.isEmpty else { return }
        pendingChannel = l
    }

    /// Catégories suivies sur cet appareil (id, nom, jaquette).
    @Published var followedCategories: [TwitchCategory] = [] {
        didSet {
            let list = followedCategories.map { ["id": $0.id, "name": $0.name, "box": $0.boxArtURL] }
            UserDefaults.standard.set(list, forKey: "followed_categories")
        }
    }
    func isCategoryFollowed(_ id: String) -> Bool { followedCategories.contains { $0.id == id } }
    func toggleCategoryFollow(_ c: TwitchCategory) {
        if let i = followedCategories.firstIndex(where: { $0.id == c.id }) { followedCategories.remove(at: i) }
        else { followedCategories.insert(TwitchCategory(id: c.id, name: c.name, boxArtURL: c.boxArtURL), at: 0) }
    }

    /// Chaînes suivies sans compte Twitch (sur cet appareil), en minuscules.
    @Published var localFollows: [String] = [] {
        didSet { UserDefaults.standard.set(localFollows, forKey: "local_follows") }
    }
    func isLocallyFollowed(_ login: String) -> Bool { localFollows.contains(login.lowercased()) }
    func toggleLocalFollow(_ login: String) {
        let l = login.lowercased()
        if let i = localFollows.firstIndex(of: l) { localFollows.remove(at: i) }
        else if !l.isEmpty { localFollows.insert(l, at: 0) }
    }

    /// Accueil : chaînes en grille (cartes) ou en liste (façon Twitch).
    @Published var homeListLayout: Bool = false {
        didSet { UserDefaults.standard.set(homeListLayout, forKey: "cfg_home_list") }
    }

    /// Langue du top des lives ; nil = celle de l'appareil.
    @Published var topLang: String? = nil {
        didSet { UserDefaults.standard.set(topLang, forKey: "cfg_top_lang") }
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
        didSet { persistHistory(); syncDirty = true }
    }

    // MARK: – VOD Progress
    @Published private(set) var vodProgress: [String: Double] = [:]

    // MARK: – Filtres du chat
    @Published var chatHideBots = false {
        didSet { UserDefaults.standard.set(chatHideBots, forKey: "chat_hide_bots") }
    }
    @Published var chatHideCommands = false {
        didSet { UserDefaults.standard.set(chatHideCommands, forKey: "chat_hide_commands") }
    }
    /// Mots masqués (minuscules) : les messages qui les contiennent disparaissent.
    @Published var chatMutedWords: [String] = [] {
        didSet { UserDefaults.standard.set(chatMutedWords, forKey: "chat_muted_words") }
    }
    /// Personnes masquées (logins en minuscules).
    @Published var chatBlockedUsers: [String] = [] {
        didSet { UserDefaults.standard.set(chatBlockedUsers, forKey: "chat_blocked_users") }
    }

    static let knownBots: Set<String> = ["nightbot", "streamelements", "moobot", "fossabot", "streamlabs",
        "wizebot", "soundalerts", "sery_bot", "botisimo", "own3d", "kofistreambot",
        "pokemoncommunitygame", "deepbot", "coebot", "phantombot", "creatisbot", "blerp"]

    /// Vrai si le message doit être masqué (réglages de filtres).
    func isChatFiltered(_ m: ChatMessage) -> Bool {
        let login = m.userName.lowercased()
        guard !login.isEmpty, m.userId != "system" else { return false }
        if login == twitchLogin?.lowercased() { return false }
        if chatBlockedUsers.contains(login) { return true }
        if chatHideBots && Self.knownBots.contains(login) { return true }
        guard chatHideCommands || !chatMutedWords.isEmpty else { return false }
        let text = m.tokens.map { t -> String in
            switch t {
            case .text(let s), .link(let s): return s
            case .mention(let s): return "@" + s
            case .emote(let e): return e.name
            }
        }.joined(separator: " ")
        if chatHideCommands && text.hasPrefix("!") { return true }
        let low = text.lowercased()
        return chatMutedWords.contains { low.contains($0) }
    }

    func toggleBlocked(_ login: String) {
        let l = login.lowercased()
        if let i = chatBlockedUsers.firstIndex(of: l) { chatBlockedUsers.remove(at: i) }
        else { chatBlockedUsers = Array((chatBlockedUsers + [l]).suffix(500)) }
    }

    /// Mots surlignés dans le chat (en plus des mentions), en minuscules.
    @Published var chatHighlightWords: [String] = [] {
        didSet { UserDefaults.standard.set(chatHighlightWords, forKey: "chat_highlight_words") }
    }

    // MARK: – Init
    init() {
        let ud = UserDefaults.standard
        chatHighlightWords = ud.stringArray(forKey: "chat_highlight_words") ?? []
        chatHideBots       = ud.bool(forKey: "chat_hide_bots")
        chatHideCommands   = ud.bool(forKey: "chat_hide_commands")
        chatMutedWords     = ud.stringArray(forKey: "chat_muted_words") ?? []
        chatBlockedUsers   = ud.stringArray(forKey: "chat_blocked_users") ?? []
        if let l = ud.string(forKey: "lang"), let parsed = Lang(rawValue: l) { lang = parsed }
        twitchToken = Keychain.loadToken("twitch_token")
        twitchUserId = ud.string(forKey: "twitch_user_id")
        twitchWebToken = Keychain.loadToken("twitch_web_token")
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
        immersivePlayer    = ud.object(forKey: "cfg_immersive")   as? Bool ?? true
        fillScreen         = ud.object(forKey: "cfg_fill_screen") as? Bool ?? false
        landscapeChat      = LandscapeChat(rawValue: ud.string(forKey: "cfg_landscape_chat") ?? "")
                             ?? .column
        chatFontSize       = ud.object(forKey: "cfg_chat_font")    as? Double ?? 13
        chatSpacing        = ud.object(forKey: "cfg_chat_spacing") as? Double ?? 8
        chatBadgeScale     = ud.object(forKey: "cfg_chat_badge")   as? Double ?? 1
        chatEmoteScale     = ud.object(forKey: "cfg_chat_emote")   as? Double ?? 1
        chatTimestamps     = ud.object(forKey: "cfg_chat_time")    as? Bool   ?? true
        chatWidthRatio     = ud.object(forKey: "cfg_chat_width")   as? Double ?? 0.32
        chatLoadRecent     = ud.object(forKey: "cfg_chat_recent")       as? Bool ?? true
        chatAutocomplete   = ud.object(forKey: "cfg_chat_autocomplete") as? Bool ?? true
        chatShowDeleted    = ud.object(forKey: "cfg_chat_deleted")      as? Bool ?? false
        shareUsage         = ud.object(forKey: "cfg_share_usage") as? Bool ?? true
        topLang            = ud.string(forKey: "cfg_top_lang")
        localFollows       = ud.stringArray(forKey: "local_follows") ?? []
        followedCategories = (ud.array(forKey: "followed_categories") as? [[String: String]] ?? []).compactMap { d in
            guard let id = d["id"] else { return nil }
            return TwitchCategory(id: id, name: d["name"] ?? "", boxArtURL: d["box"] ?? "")
        }
        // Le tutoriel est pour le tout premier lancement : une installation qui
        // a déjà servi (mise à jour) ne le voit pas.
        if ud.object(forKey: "onboarding_done") == nil && ud.integer(forKey: "launch_count") > 0 {
            ud.set(true, forKey: "onboarding_done")
        }
        homeListLayout     = ud.bool(forKey: "cfg_home_list")
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
        // Le chargement initial n'est pas un changement à envoyer.
        syncDirty = false
        // Filet de sécurité pendant une longue lecture : au plus un envoi par
        // `syncEvery`, et seulement s'il y a du neuf.
        syncTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushToCloud() }
        }
    }

    // MARK: – Translation
    func t(_ key: String) -> String { translate(key, lang) }

    // MARK: – Auth
    /// Nouveau jeton après une connexion. S'il change, l'identité gardée
    /// (id, pseudo, avatar) est oubliée : sinon, en se connectant à un autre
    /// compte, le nouveau jeton partait avec l'ancien id — sauvegarde et chat
    /// visaient le mauvais compte.
    func adoptToken(_ token: String) {
        if token != twitchToken {
            twitchUserId = nil
            twitchLogin  = nil
            twitchAvatar = nil
        }
        let isNew = token != twitchToken
        twitchToken = token
        // Compté tout de suite comme compte, sans attendre l'heure suivante :
        // le Worker reprend l'historique anonyme de l'appareil et l'efface.
        if isNew {
            let enabled = shareUsage
            Task { await UsageService.shared.ping(enabled: enabled, force: true) }
        }
    }

    func logout() {
        twitchToken    = nil
        twitchWebToken = nil
        Task { await TwitchWebSession.clear() }
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
        // Le lecteur appelle ceci toutes les 0,5 s : chaque appel réencodait
        // tout le dictionnaire dans UserDefaults et republiait le store (donc
        // redessinait l'interface). Écart de 5 s minimum, sauf saut (reprise
        // DVR, retour au début).
        if let old = vodProgress[vodId], abs(time - old) < 5 { return }
        vodProgress[vodId] = time
        // Borné aux 500 VODs les plus récentes (identifiants croissants).
        if vodProgress.count > 500 {
            let keep = Set(vodProgress.keys.sorted { (Int($0) ?? 0) > (Int($1) ?? 0) }.prefix(500))
            vodProgress = vodProgress.filter { keep.contains($0.key) }
        }
        persistProgress()
        syncDirty = true
    }

    private func persistProgress() {
        if let data = try? JSONEncoder().encode(vodProgress) {
            UserDefaults.standard.set(data, forKey: "vod_progress_all")
        }
    }

    // MARK: – Cloud Sync
    //
    // Sauvegarde partagée avec le site, sur le Worker (KV Cloudflare). Le KV
    // gratuit n'offre que 1 000 écritures par jour au total : un changement
    // ne fait que marquer la sauvegarde « à envoyer », et l'envoi part à la
    // fermeture d'une vidéo, au passage en arrière-plan, sinon au plus toutes
    // les 10 minutes — jamais si rien n'a changé depuis le dernier envoi.

    private var syncDirty = false
    private var lastSyncedBody: Data?
    private var lastSyncAt  = Date.distantPast
    private var lastPullAt  = Date.distantPast
    private var syncTimer: Timer?
    private let syncEvery: TimeInterval = 600
    private let pullEvery: TimeInterval = 600

    /// Relit la sauvegarde si la dernière lecture date de plus de 10 minutes.
    /// Une lecture ne coûte presque rien (100 000 par jour en gratuit).
    func refreshFromCloudIfStale(userId: String? = nil) async {
        guard let id = userId ?? twitchUserId, !id.isEmpty,
              Date().timeIntervalSince(lastPullAt) > pullEvery else { return }
        await pullFromCloud(userId: id)
    }

    func pullFromCloud(userId: String) async {
        lastPullAt = Date()
        // Le Worker exige le jeton Twitch du propriétaire de la sauvegarde.
        guard let token = twitchToken,
              let url = URL(string: "\(kAPIURL)/api/sync/get?userId=\(userId)") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        var remote: [HistoryItem] = []
        if let raw = json["history"],
           let histData = try? JSONSerialization.data(withJSONObject: raw),
           let items = try? JSONDecoder().decode([LossyDecodable<HistoryItem>].self, from: histData) {
            remote = items.compactMap(\.value)
        }
        var remoteProgress: [String: Double] = [:]
        for (id, value) in json["progress"] as? [String: Any] ?? [:] {
            // Borné : une valeur aberrante venue du serveur faisait planter
            // la conversion en Int de la bibliothèque.
            if let n = value as? NSNumber, n.doubleValue.isFinite, n.doubleValue > 0 {
                remoteProgress[id] = min(n.doubleValue, 7 * 24 * 3600)
            }
        }

        await MainActor.run {
            // Fusion, pas remplacement : ce qui a été vu ici depuis le dernier
            // envoi ne doit pas disparaître. Le plus récent d'abord ; les
            // éléments sans date (anciens, venus du site) en fin de liste.
            let known = Set(history.map { $0.term.lowercased() })
            let added = remote.filter { !known.contains($0.term.lowercased()) }
            if !added.isEmpty {
                let merged = (history + added).enumerated()
                    .sorted { a, b in
                        a.element.addedAt != b.element.addedAt
                            ? a.element.addedAt > b.element.addedAt
                            : a.offset < b.offset
                    }
                    .map(\.element)
                history = Array(merged.prefix(50))
            }
            // Progression : la position la plus avancée l'emporte.
            var changed = false
            for (id, t) in remoteProgress where t > (vodProgress[id] ?? 0) {
                vodProgress[id] = t
                changed = true
            }
            if changed { persistProgress() }
            logger.syncPull(items: added.count)
        }
    }

    /// Envoie la sauvegarde si elle a changé. `force` ignore l'intervalle
    /// minimal — pour la fermeture d'une vidéo et le passage en arrière-plan.
    func flushToCloud(force: Bool = false) {
        guard syncDirty, let userId = twitchUserId, !userId.isEmpty, let token = twitchToken else { return }
        guard force || Date().timeIntervalSince(lastSyncAt) >= syncEvery else { return }

        // Seule la progression des VODs de l'historique part : le Worker garde
        // déjà les autres (il fusionne), inutile d'alourdir chaque envoi.
        let vodIds = Set(history.filter { $0.type == .vod }.map(\.term))
        let progress = vodProgress.filter { vodIds.contains($0.key) }.mapValues { $0.rounded() }
        guard let histData = try? JSONEncoder().encode(history),
              let histJSON = try? JSONSerialization.jsonObject(with: histData),
              let body = try? JSONSerialization.data(
                  withJSONObject: ["userId": userId, "data": ["history": histJSON, "progress": progress]],
                  options: [.sortedKeys]),
              let url = URL(string: "\(kAPIURL)/api/sync/post") else { return }

        syncDirty = false
        guard body != lastSyncedBody else { return }
        lastSyncAt = Date()

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = body

        // Laisse à l'envoi le temps de finir si l'app vient de passer en
        // arrière-plan : sans ça, iOS peut la suspendre en pleine requête.
        // Boîte de référence plutôt qu'une `var` capturée : les deux blocs
        // sont `@Sendable` dans les SDK récents, où muter une variable
        // capturée ne compile pas.
        let request = req   // une `var` capturée par un Task ne compile pas
        let bg = BackgroundTaskBox()
        bg.id = UIApplication.shared.beginBackgroundTask(withName: "sync") { bg.end() }
        Task {
            let ok = ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)
                .map { (200..<300).contains($0.statusCode) } ?? false
            await MainActor.run {
                // Retenu comme envoyé seulement si le Worker l'a accepté :
                // sinon le prochain passage réessaie au lieu d'oublier.
                if ok { self.lastSyncedBody = body } else { self.syncDirty = true }
                bg.end()
            }
        }
        logger.syncPush(items: history.count)
    }
}

/// Tâche d'arrière-plan à clore une seule fois, quel que soit le premier
/// des deux à finir : la requête, ou le délai accordé par iOS.
private final class BackgroundTaskBox {
    var id: UIBackgroundTaskIdentifier = .invalid
    // Pas d'annotation d'acteur : appelé depuis le délai d'expiration d'iOS,
    // dont l'isolation varie selon la version du SDK. Toujours sur le fil
    // principal en pratique (délai d'expiration, MainActor.run).
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
