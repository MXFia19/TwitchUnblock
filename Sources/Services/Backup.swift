import SwiftUI
import UniformTypeIdentifiers

// ═══════════════════════════════════════════════════════════════════════════
//  Sauvegarde : export / import des chaînes, des réglages et de « Continuer à
//  regarder » dans un fichier.
//
//  Sert à passer de l'app à « TU Test » (une autre app, autre identifiant,
//  autres données) et inversement, à une réinstallation, ou au site. Même
//  format que le site : les chaînes et catégories suivies passent d'un
//  appareil à l'autre. Les réglages communs aux deux (langue, filtres du
//  chat, thème, épinglées…) portent le nom du site ; ceux propres à l'app
//  sont préfixés « ios_ » et ignorés par le site. La synchro des réglages
//  entre appareils (SettingsSync.swift) en reprend une partie, sous les mêmes
//  noms.
//
//  JAMAIS dans le fichier : jetons et sessions Twitch, jeton d'intégrité,
//  identifiant d'installation, sujet ntfy, Worker personnel (un fichier
//  piégé ferait passer le jeton chez un tiers). Seules les clés listées
//  ci-dessous partent, et seules elles sont relues.
//
//  Version 1 (jusqu'à la 1.6.0) : chaînes suivies et masquées, catégories,
//  une partie des réglages. Version 2 : en plus les chaînes épinglées,
//  l'apparence, les notifications, les drops, l'ordre des sources et
//  « Continuer à regarder ». Un fichier plus ancien, ou du site, s'importe
//  toujours : ce qui y manque ne change rien.
// ═══════════════════════════════════════════════════════════════════════════

/// Fichier JSON pour `fileExporter`.
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum Backup {
    static let format = "twitchunblock-backup"
    /// Version écrite par cette app (voir l'en-tête).
    static let version = 2

    enum ImportError: Error { case invalid }

    /// Ce que reprend un import : tout, ou les chaînes seulement (suivies,
    /// épinglées, masquées, et les catégories suivies).
    enum Scope { case all, channelsOnly }

    /// Sauvegarde lue et reconnue, en attente du choix « Tout » ou
    /// « Chaînes seulement ».
    struct File {
        fileprivate let root: [String: Any]
        /// 1 pour les anciennes sauvegardes de l'app et celles du site.
        let version: Int
    }

    /// Ce qu'un import a repris, pour son résumé.
    struct Summary {
        var follows = 0
        /// Laissées de côté : 300 chaînes suivies au plus sur l'appareil.
        var followsSkipped = 0
        var categories = 0
        var pinned = 0
        /// Chaînes et catégories masquées ajoutées.
        var hidden = 0
        var settings = 0
        /// Réglages inconnus de cette version (ou propres au site) ou
        /// invalides : ignorés.
        var settingsIgnored = 0
        var continueWatching = 0
        /// Notifications de live de la sauvegarde (nil : pas dites, ou
        /// chaînes seulement) : leur activation demande l'autorisation
        /// d'iOS, faite par l'écran des réglages.
        var liveNotifications: Bool? = nil
    }

    static func fileName() -> String {
        // Date grégorienne quel que soit le calendrier de l'appareil : sinon
        // « twitchunblock-2569-10-13 » sur un iPhone en calendrier bouddhiste.
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return "twitchunblock-\(df.string(from: Date()))"
    }

    /// Langue du top écrite comme le site (« zh_hk » là où l'app dit « zh-hk »).
    private static func siteTopLang(_ code: String) -> String {
        code.replacingOccurrences(of: "-", with: "_")
    }

    /// Langue venue d'une sauvegarde (« zh_hk » du site ramené à « zh-hk »),
    /// seulement si l'app la connaît.
    private static func appTopLang(_ raw: String) -> String? {
        let code = raw.lowercased().replacingOccurrences(of: "_", with: "-")
        return TopLanguage.codes.contains(code) ? code : nil
    }

    /// Textes d'une liste JSON (les autres éléments sont écartés).
    private static func strings(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { $0 as? String }
    }

    /// Réglages de la sauvegarde (`settings`) : ceux communs avec le site
    /// sous le nom du site, ceux propres à l'app préfixés « ios_ ». La synchro
    /// des réglages (SettingsSync) en tire ses sections : ses listes de clés
    /// décident de ce qui en part, pas ce dictionnaire.
    static func settingsJSON(_ store: AppStore) -> [String: Any] {
        // Réglages → Personnaliser : l'objet tel quel, relu par UICustomization.
        let customization: Any = (try? JSONEncoder().encode(store.customization))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
        // Deux dictionnaires plutôt qu'un seul très long, plus lent à
        // vérifier pour le compilateur.
        let common: [String: Any] = [
            // Communs avec le site (mêmes noms)
            "lang": store.lang.rawValue,
            "topLang": store.topLang.map { siteTopLang($0) as Any } ?? NSNull(),
            "catLang": store.categoryLang.map { siteTopLang($0) as Any } ?? NSNull(),
            "homeList": store.homeListLayout,
            "showRecent": store.showRecentChannels,
            "pinned": store.pinnedStreamers,
            "pinnedByViewers": store.customization.pinnedByViewers,
            "themeAccent": store.accent.rawValue,
            "themeBg": store.background.rawValue,
            "ios_showDiscoverTab": store.showDiscoverTab,
            "ios_customization": customization,
            "timestamps": store.chatTimestamps,
            "timeFormat": store.timeFormat,
            "keepDeleted": store.chatShowDeleted,
            "loadHistory": store.chatLoadRecent,
            "hideBots": store.chatHideBots,
            "hideCommands": store.chatHideCommands,
            "mutedWords": store.chatMutedWords,
            "blockedUsers": store.chatBlockedUsers,
            "highlightWords": store.chatHighlightWords,
            "hiddenEmotes": store.hiddenEmotes,
            "shareUsage": store.shareUsage,
            "vodSpeed": store.vodSpeed,
            "qualityPref": store.preferredQuality,
            "liveSourceOrder": store.liveSourceOrder,
            "multiChat": store.multiLiveChat,
        ]
        let app: [String: Any] = [
            // Propres à l'app
            "ios_autoClaimChest": store.autoClaimChest,
            "ios_showPinned": store.showPinnedMessages,
            "ios_showDropsNotice": store.showDropsNotice,
            "ios_showSpecialEvents": store.showSpecialEvents,
            "ios_showFollowButton": store.showFollowButton,
            "ios_showChatBell": store.showChatBell,
            "ios_showChatModes": store.showChatModes,
            "ios_showChatPoints": store.showChatPoints,
            "ios_showWatchStreak": store.showWatchStreak,
            "ios_showLiveEvents": store.showLiveEvents,
            "ios_showPolls": store.showPolls,
            "ios_showPredictions": store.showPredictions,
            "ios_showHypeTrain": store.showHypeTrain,
            "ios_enableRaids": store.enableRaids,
            "ios_landNoticesHidden": store.landscapeNoticesHidden,
            "ios_autoPurgeCache": store.autoPurgeImageCache,
            "ios_lowLatency": store.lowLatency,
            "ios_subAdFree": store.subAdFree,
            "ios_immersivePlayer": store.immersivePlayer,
            "ios_liveActivity": store.liveActivity,
            "ios_cellularQuality": store.cellularQuality,
            "ios_higherQualities": store.higherQualities,
            "ios_fillScreen": store.fillScreen,
            "ios_pipOnLeave": store.pipOnLeave,
            "ios_landscapeChat": store.landscapeChat.rawValue,
            "ios_spatialAudio": store.spatialAudio,
            "ios_restoreMuted": store.restoreMutedAudio,
            "ios_chatFontSize": store.chatFontSize,
            "ios_chatSpacing": store.chatSpacing,
            "ios_chatBadgeScale": store.chatBadgeScale,
            "ios_chatEmoteScale": store.chatEmoteScale,
            "ios_chatWidthRatio": store.chatWidthRatio,
            "ios_chatAutocomplete": store.chatAutocomplete,
            "ios_chatKeyboardSuggestions": store.chatKeyboardSuggestions,
            "ios_chatReturnSends": store.chatReturnSends,
            "ios_chatShowInput": store.chatShowInput,
            "ios_chatSync": store.chatSync,
            "ios_chatSyncNudge": store.chatSyncNudge,
            "ios_showLatency": store.showLatency,
            "ios_liquidGlass": store.liquidGlass,
            "ios_dropsProgress": store.dropsProgress,
            "ios_autoClaimDrops": store.autoClaimDrops,
            "ios_dropsNotify": store.dropsNotify,
            // Notifications de live : l'état et les chaînes coupées, jamais
            // le sujet ntfy (secret, propre à chaque installation).
            "ios_liveNotif": LiveNotifier.isEnabled,
            "ios_notifMuted": NotifChannels.muted.sorted(),
            "ios_downloadWifiOnly": store.downloadWifiOnly,
            "ios_syncSettings": store.syncSettings,
            // Pour les versions d'avant « qualityPref » (audio seul retenu).
            "ios_preferAudioOnly": store.preferAudioOnly,
        ]
        return common.merging(app) { first, _ in first }
    }

    /// « Continuer à regarder » : les VODs de l'historique entamées (plus de
    /// 30 s), avec leur position. L'accueil n'en montre que celles qui ne sont
    /// pas finies, une fois leur durée connue.
    static func continueJSON(_ store: AppStore) -> [[String: Any]] {
        store.history
            .filter { $0.type == .vod && store.getVodProgress($0.term) > 30 }
            .prefix(50)
            .map { item -> [String: Any] in
                var o: [String: Any] = ["id": item.term, "title": item.display,
                                        "position": store.getVodProgress(item.term).rounded(),
                                        "addedAt": item.addedAt]
                if let t = item.thumb, !t.isEmpty { o["thumb"] = t }
                if let s = item.streamer, !s.isEmpty { o["streamer"] = s }
                return o
            }
    }

    static func export(store: AppStore) -> Data {
        let info = Bundle.main.infoDictionary ?? [:]
        let root: [String: Any] = [
            "format": format,
            "version": version,
            "platform": "ios",
            // D'où vient le fichier (l'app ou « TU Test »), pour qui le lit.
            "app": info["CFBundleDisplayName"] as? String ?? "TwitchUnblock",
            "appVersion": info["CFBundleShortVersionString"] as? String ?? "",
            "appBuild": info["CFBundleVersion"] as? String ?? "",
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "follows": store.localFollows,
            "accountFollows": store.accountFollowLogins,
            "followedCategories": store.followedCategories.map { ["id": $0.id, "name": $0.name, "box": $0.boxArtURL] },
            // Chaînes et catégories masquées, même format que le site (`at`
            // en millisecondes). Clé ignorée par les versions d'avant.
            "hidden": store.hidden.backupJSON(),
            "settings": settingsJSON(store),
            "continueWatching": continueJSON(store),
        ]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// Lit un fichier sans rien appliquer ; refusé s'il n'est pas une
    /// sauvegarde TwitchUnblock (app ou site, toute version).
    static func read(_ data: Data) throws -> File {
        guard data.count < 2_000_000,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["format"] as? String == format else { throw ImportError.invalid }
        return File(root: root, version: max(1, root["version"] as? Int ?? 1))
    }

    /// Applique une sauvegarde lue : chaînes suivies, épinglées et masquées,
    /// et catégories suivies, ajoutées aux nôtres (rien n'est retiré) ; pour
    /// « Tout », en plus les réglages connus et valides (les autres sont
    /// ignorés et comptés) et « Continuer à regarder ».
    @discardableResult
    static func apply(_ file: File, scope: Scope, store: AppStore) -> Summary {
        let root = file.root
        let settings = root["settings"] as? [String: Any]
        var summary = Summary()

        // Suivis. Comptés après la limite : avant, « 400 chaînes ajoutées »
        // quand 100 tombaient en silence. Les suivis déjà là restent tous.
        let incoming = (strings(root["follows"]) + strings(root["accountFollows"]))
            .map { $0.lowercased() }.filter(HiddenContent.validLogin)
        var follows = store.localFollows
        var fresh = 0
        for l in incoming where !follows.contains(l) { follows.append(l); fresh += 1 }
        let before = store.localFollows.count
        let kept = Array(follows.prefix(max(300, before)))
        summary.follows = kept.count - before
        summary.followsSkipped = fresh - summary.follows
        if kept != store.localFollows { store.localFollows = kept }

        // Catégories suivies : identifiant numérique, jaquette en https.
        var cats = store.followedCategories
        for c in root["followedCategories"] as? [[String: Any]] ?? [] {
            guard let id = c["id"] as? String, HiddenContent.validCategoryId(id),
                  let name = c["name"] as? String,
                  !cats.contains(where: { $0.id == id }) else { continue }
            let box = c["box"] as? String ?? ""
            cats.append(TwitchCategory(id: id, name: String(name.prefix(100)),
                                       boxArtURL: box.hasPrefix("https://") && box.count <= 500 ? box : ""))
        }
        cats = Array(cats.prefix(200))
        summary.categories = max(0, cats.count - store.followedCategories.count)
        if summary.categories > 0 { store.followedCategories = cats }

        // Épinglées : dans les réglages, sous le nom du site (« pinned »),
        // ajoutées après les nôtres.
        var pins = store.pinnedStreamers
        for l in strings(settings?["pinned"]).map({ $0.lowercased() })
            where HiddenContent.validLogin(l) && !pins.contains(l) { pins.append(l) }
        pins = Array(pins.prefix(300))
        summary.pinned = max(0, pins.count - store.pinnedStreamers.count)
        if summary.pinned > 0 { store.pinnedStreamers = pins }

        // Masquées : ajoutées aux nôtres, validées (pseudo, identifiant).
        let hiddenChannels = Set(store.hidden.channels.map(\.login))
        let hiddenCategories = Set(store.hidden.categories.map(\.id))
        var hidden = store.hidden
        hidden.merge(backup: root["hidden"])
        summary.hidden = hidden.channels.filter { !hiddenChannels.contains($0.login) }.count
            + hidden.categories.filter { !hiddenCategories.contains($0.id) }.count
        if hidden != store.hidden { store.hidden = hidden }

        guard scope == .all else { return summary }

        if let settings {
            let result = applySettings(settings, to: store)
            summary.settings = result.applied
            summary.settingsIgnored = result.ignored
            // Chaînes dont les notifications de live sont coupées.
            if settings["ios_notifMuted"] != nil {
                NotifChannels.setMuted(Set(strings(settings["ios_notifMuted"])
                    .map { $0.lowercased() }.filter(HiddenContent.validLogin).prefix(500)))
                summary.settings += 1
            }
            if let on = settings["ios_liveNotif"] as? Bool {
                summary.liveNotifications = on
                summary.settings += 1
            }
        }
        summary.continueWatching = importContinue(root["continueWatching"], store: store)
        return summary
    }

    /// VODs entamées d'une sauvegarde : identifiant numérique, position de
    /// plus de 30 s ; titre, image et chaîne bornés. Rend le nombre de VODs
    /// ajoutées à l'historique ou avancées.
    private static func importContinue(_ raw: Any?, store: AppStore) -> Int {
        var items: [HistoryItem] = []
        var progress: [String: Double] = [:]
        for o in (raw as? [[String: Any]] ?? []).prefix(50) {
            guard let id = o["id"] as? String, !id.isEmpty, id.count <= 20,
                  id.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let position = o["position"] as? Double, position.isFinite,
                  position > 30, position < 7 * 24 * 3600,
                  progress[id] == nil else { continue }
            let title = String((o["title"] as? String ?? "").prefix(300))
            let thumb = (o["thumb"] as? String).flatMap { $0.hasPrefix("https://") && $0.count <= 500 ? $0 : nil }
            let streamer = (o["streamer"] as? String).map { String($0.prefix(60)) }.flatMap { $0.isEmpty ? nil : $0 }
            let added = (o["addedAt"] as? Double).flatMap { $0.isFinite && $0 > 0 && $0 < 1e14 ? $0 : nil } ?? 0
            items.append(HistoryItem(term: id, type: .vod, display: title.isEmpty ? "VOD \(id)" : title,
                                     thumb: thumb, streamer: streamer, addedAt: added))
            progress[id] = position
        }
        return store.importContinueWatching(items, progress: progress)
    }

    /// Réglages d'une sauvegarde — ou d'une section reçue par la synchro des
    /// réglages — repris : chaque valeur validée ; une clé absente, inconnue
    /// ou invalide ne change rien. Rend le nombre de réglages repris, et
    /// celui des clés ignorées (inconnues, propres au site, invalides).
    @discardableResult
    static func applySettings(_ s: [String: Any], to store: AppStore) -> (applied: Int, ignored: Int) {
        var applied = Set<String>()
        func ok(_ k: String) { applied.insert(k) }
        func bool(_ k: String, _ apply: (Bool) -> Void) {
            if let v = s[k] as? Bool { apply(v); ok(k) }
        }
        func num(_ k: String, _ range: ClosedRange<Double>, _ apply: (Double) -> Void) {
            if let v = s[k] as? Double, range.contains(v) { apply(v); ok(k) }
        }
        // Tailles du chat : ramenées dans les bornes des curseurs des Réglages.
        func size(_ k: String, _ range: ClosedRange<Double>, _ apply: (Double) -> Void) {
            if let v = s[k] as? Double, v.isFinite { apply(AppStore.clamped(v, to: range)); ok(k) }
        }
        func words(_ k: String, _ max: Int, _ apply: ([String]) -> Void) {
            if let v = s[k] as? [String] { apply(Array(v.map { $0.lowercased() }.prefix(max))); ok(k) }
        }

        if let l = s["lang"] as? String, let lang = Lang(rawValue: l) { store.lang = lang; ok("lang") }
        // Langue du top : « zh_hk » du site ramené à « zh-hk », et seulement
        // une langue que l'app connaît (sinon aucune case n'était cochée).
        if s["topLang"] is NSNull { store.topLang = nil; ok("topLang") }
        else if let t = s["topLang"] as? String, let code = appTopLang(t) { store.topLang = code; ok("topLang") }
        // Langue des lives dans les catégories ; null = toutes.
        if s["catLang"] is NSNull { store.categoryLang = nil; ok("catLang") }
        else if let t = s["catLang"] as? String, let code = appTopLang(t) { store.categoryLang = code; ok("catLang") }
        bool("homeList") { store.homeListLayout = $0 }
        bool("showRecent") { store.showRecentChannels = $0 }
        bool("ios_showDiscoverTab") { store.showDiscoverTab = $0 }
        // Après l'ancien réglage de Découvrir, qu'elle contient aussi.
        if let o = s["ios_customization"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: o),
           let c = try? JSONDecoder().decode(UICustomization.self, from: data) {
            store.customization = c
            ok("ios_customization")
        } else {
            // Sauvegarde du site : seul ce choix de la personnalisation y est.
            bool("pinnedByViewers") { store.customization.pinnedByViewers = $0 }
        }
        // Apparence (noms du site) : un fond que l'app n'a pas (« auto »,
        // « light » du site) est ignoré.
        if let v = s["themeAccent"] as? String, let a = AccentTheme(rawValue: v) { store.accent = a; ok("themeAccent") }
        if let v = s["themeBg"] as? String, let b = BackgroundTheme(rawValue: v) { store.background = b; ok("themeBg") }
        bool("ios_liquidGlass") { store.liquidGlass = $0 }
        bool("timestamps") { store.chatTimestamps = $0 }
        if let v = s["timeFormat"] as? String, ["auto", "12", "24"].contains(v) { store.timeFormat = v; ok("timeFormat") }
        bool("keepDeleted") { store.chatShowDeleted = $0 }
        bool("loadHistory") { store.chatLoadRecent = $0 }
        bool("hideBots") { store.chatHideBots = $0 }
        bool("hideCommands") { store.chatHideCommands = $0 }
        words("mutedWords", 50) { store.chatMutedWords = $0 }
        words("blockedUsers", 500) { store.chatBlockedUsers = $0 }
        words("highlightWords", 30) { store.chatHighlightWords = $0 }
        // Emotes masquées (nom du site) : codes exacts, la casse compte —
        // pas de mise en minuscules comme les mots.
        if let v = s["hiddenEmotes"] as? [String] {
            store.hiddenEmotes = AppStore.emoteCodes(v)
            ok("hiddenEmotes")
        }
        bool("shareUsage") { store.shareUsage = $0 }
        num("vodSpeed", 0.25...2) { store.vodSpeed = VodSpeed.nearestSafe($0) }
        // Ordre des sources du direct (nom du site) : sources connues, sans
        // doublon, celles qui manquent juste après celle qu'elles secourent.
        if let v = s["liveSourceOrder"] as? [String], v.contains(where: { kLiveSources.contains($0) }) {
            store.liveSourceOrder = completeLiveSourceOrder(v)
            ok("liveSourceOrder")
        }
        bool("multiChat") { store.multiLiveChat = $0 }

        bool("ios_autoClaimChest") { store.autoClaimChest = $0 }
        bool("ios_showPinned") { store.showPinnedMessages = $0 }
        bool("ios_showDropsNotice") { store.showDropsNotice = $0 }
        bool("ios_showSpecialEvents") { store.showSpecialEvents = $0 }
        bool("ios_showFollowButton") { store.showFollowButton = $0 }
        bool("ios_showChatBell") { store.showChatBell = $0 }
        bool("ios_showChatModes") { store.showChatModes = $0 }
        bool("ios_showChatPoints") { store.showChatPoints = $0 }
        bool("ios_showWatchStreak") { store.showWatchStreak = $0 }
        bool("ios_showLiveEvents") { store.showLiveEvents = $0 }
        bool("ios_showPolls") { store.showPolls = $0 }
        bool("ios_showPredictions") { store.showPredictions = $0 }
        bool("ios_showHypeTrain") { store.showHypeTrain = $0 }
        bool("ios_enableRaids") { store.enableRaids = $0 }
        bool("ios_landNoticesHidden") { store.landscapeNoticesHidden = $0 }
        bool("ios_autoPurgeCache") { store.autoPurgeImageCache = $0 }
        bool("ios_lowLatency") { store.lowLatency = $0 }
        bool("ios_subAdFree") { store.subAdFree = $0 }
        bool("ios_immersivePlayer") { store.immersivePlayer = $0 }
        bool("ios_liveActivity") { store.liveActivity = $0 }
        if let q = s["ios_cellularQuality"] as? String, kCellularQualityPrefs.contains(q) {
            store.cellularQuality = q
            ok("ios_cellularQuality")
        }
        bool("ios_higherQualities") { store.higherQualities = $0 }
        bool("ios_fillScreen") { store.fillScreen = $0 }
        bool("ios_pipOnLeave") { store.pipOnLeave = $0 }
        if let v = s["ios_landscapeChat"] as? String, let lc = LandscapeChat(rawValue: v) {
            store.landscapeChat = lc
            ok("ios_landscapeChat")
        }
        if let v = s["ios_spatialAudio"] as? String, ["auto", "off"].contains(v) {
            store.spatialAudio = v
            ok("ios_spatialAudio")
        }
        bool("ios_restoreMuted") { store.restoreMutedAudio = $0 }
        size("ios_chatFontSize", AppStore.chatFontRange) { store.chatFontSize = $0 }
        size("ios_chatSpacing", AppStore.chatSpacingRange) { store.chatSpacing = $0 }
        size("ios_chatBadgeScale", AppStore.chatScaleRange) { store.chatBadgeScale = $0 }
        size("ios_chatEmoteScale", AppStore.chatScaleRange) { store.chatEmoteScale = $0 }
        size("ios_chatWidthRatio", AppStore.chatWidthRange) { store.chatWidthRatio = $0 }
        bool("ios_chatAutocomplete") { store.chatAutocomplete = $0 }
        bool("ios_chatKeyboardSuggestions") { store.chatKeyboardSuggestions = $0 }
        bool("ios_chatReturnSends") { store.chatReturnSends = $0 }
        bool("ios_chatShowInput") { store.chatShowInput = $0 }
        bool("ios_chatSync") { store.chatSync = $0 }
        // Bornes du réglage fin de la synchro du chat (ChatSync).
        num("ios_chatSyncNudge", -20...20) { store.chatSyncNudge = $0 }
        bool("ios_showLatency") { store.showLatency = $0 }
        bool("ios_dropsProgress") { store.dropsProgress = $0 }
        bool("ios_autoClaimDrops") { store.autoClaimDrops = $0 }
        bool("ios_dropsNotify") { store.dropsNotify = $0 }
        bool("ios_downloadWifiOnly") { store.downloadWifiOnly = $0 }
        bool("ios_syncSettings") { store.syncSettings = $0 }
        // Qualité préférée (nom du site). « auto » du site devient « source »
        // tant que l'app n'a pas d'Auto ; une hauteur hors paliers retenue
        // par le lecteur du site (« 1440 », « 936 ») prend le palier le plus
        // proche, « source » au-dessus de 1080 ; sans elle (sauvegarde d'une
        // version d'avant), seul l'audio seul était retenu.
        if let q = s["qualityPref"] as? String {
            if kQualityPrefs.contains(q) { store.preferredQuality = q; ok("qualityPref") }
            else if q == "auto" { store.preferredQuality = "source"; ok("qualityPref") }
            else if let h = Int(q), h > 0 {
                store.preferredQuality = h > 1080 ? "source"
                    : String([1080, 720, 480, 360, 160].min { abs($0 - h) < abs($1 - h) } ?? 1080)
                ok("qualityPref")
            }
        } else if let audio = s["ios_preferAudioOnly"] as? Bool {
            if audio { store.preferredQuality = "audio" }
            else if store.preferAudioOnly { store.preferredQuality = "source" }
            ok("ios_preferAudioOnly")
        }

        // Ni reprises ni ignorées : lues ailleurs (chaînes épinglées,
        // notifications : `apply`), ou doublons d'un réglage déjà repris
        // (audio seul et Découvrir, déjà dans la qualité et la
        // personnalisation ; ordre d'épinglage, dans la personnalisation).
        let elsewhere: Set<String> = ["pinned", "pinnedByViewers", "ios_liveNotif", "ios_notifMuted",
                                      "ios_preferAudioOnly", "ios_showDiscoverTab"]
        let ignored = s.keys.filter { !applied.contains($0) && !elsewhere.contains($0) }.count
        return (applied.count, ignored)
    }
}
