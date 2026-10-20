import SwiftUI
import UniformTypeIdentifiers

// ═══════════════════════════════════════════════════════════════════════════
//  Sauvegarde : export / import des suivis et des réglages dans un fichier.
//
//  Même format que le site : les chaînes et catégories suivies passent d'un
//  appareil à l'autre. Les réglages communs aux deux (langue, filtres du
//  chat…) portent le nom du site ; ceux propres à l'app sont préfixés
//  « ios_ » et ignorés par le site. La synchro des réglages entre appareils
//  (SettingsSync.swift) en reprend une partie, sous les mêmes noms.
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

    enum ImportError: Error { case invalid }

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

    /// Réglages de la sauvegarde (`settings`) : ceux communs avec le site
    /// sous le nom du site, ceux propres à l'app préfixés « ios_ ». La synchro
    /// des réglages (SettingsSync) en tire ses sections.
    static func settingsJSON(_ store: AppStore) -> [String: Any] {
        // Réglages → Personnaliser : l'objet tel quel, relu par UICustomization.
        let customization: Any = (try? JSONEncoder().encode(store.customization))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
        return [
            // Communs avec le site (mêmes noms)
            "lang": store.lang.rawValue,
            "topLang": store.topLang.map { siteTopLang($0) as Any } ?? NSNull(),
            "homeList": store.homeListLayout,
            "showRecent": store.showRecentChannels,
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
            "shareUsage": store.shareUsage,
            "vodSpeed": store.vodSpeed,
            "qualityPref": store.preferredQuality,
            // Propres à l'app
            "ios_autoClaimChest": store.autoClaimChest,
            "ios_showPinned": store.showPinnedMessages,
            "ios_showDropsNotice": store.showDropsNotice,
            "ios_showFollowButton": store.showFollowButton,
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
            "ios_landscapeChat": store.landscapeChat.rawValue,
            "ios_chatFontSize": store.chatFontSize,
            "ios_chatSpacing": store.chatSpacing,
            "ios_chatBadgeScale": store.chatBadgeScale,
            "ios_chatEmoteScale": store.chatEmoteScale,
            "ios_chatWidthRatio": store.chatWidthRatio,
            "ios_chatAutocomplete": store.chatAutocomplete,
            "ios_chatKeyboardSuggestions": store.chatKeyboardSuggestions,
            "ios_chatReturnSends": store.chatReturnSends,
            "ios_chatSync": store.chatSync,
            "ios_downloadWifiOnly": store.downloadWifiOnly,
            "ios_syncSettings": store.syncSettings,
            // Pour les versions d'avant « qualityPref » (audio seul retenu).
            "ios_preferAudioOnly": store.preferAudioOnly,
        ]
    }

    static func export(store: AppStore) -> Data {
        let root: [String: Any] = [
            "format": format,
            "version": 1,
            "platform": "ios",
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "follows": store.localFollows,
            "accountFollows": store.accountFollowLogins,
            "followedCategories": store.followedCategories.map { ["id": $0.id, "name": $0.name, "box": $0.boxArtURL] },
            // Chaînes et catégories masquées, même format que le site (`at`
            // en millisecondes). Clé ignorée par les versions d'avant.
            "hidden": store.hidden.backupJSON(),
            "settings": settingsJSON(store),
        ]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// Fusionne la sauvegarde : suivis ajoutés (rien n'est retiré), réglages
    /// connus repris. Renvoie le nombre de chaînes ajoutées, et celui des
    /// chaînes laissées de côté (300 suivis au plus sur l'appareil).
    static func importData(_ data: Data, store: AppStore) throws -> (added: Int, skipped: Int) {
        guard data.count < 2_000_000,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["format"] as? String == format else { throw ImportError.invalid }

        let validLogin = { (s: String) -> Bool in
            !s.isEmpty && s.count <= 25 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        }
        let incoming = ((root["follows"] as? [String] ?? []) + (root["accountFollows"] as? [String] ?? []))
            .map { $0.lowercased() }.filter(validLogin)
        var follows = store.localFollows
        var fresh = 0
        for l in incoming where !follows.contains(l) { follows.append(l); fresh += 1 }
        // Comptées après la limite : avant, « 400 chaînes ajoutées » quand
        // 100 tombaient en silence. Les suivis déjà là restent tous.
        let before = store.localFollows.count
        let kept = Array(follows.prefix(max(300, before)))
        let added = kept.count - before
        store.localFollows = kept
        let skipped = fresh - added

        var cats = store.followedCategories
        for c in root["followedCategories"] as? [[String: Any]] ?? [] {
            guard let id = c["id"] as? String, let name = c["name"] as? String,
                  !cats.contains(where: { $0.id == id }) else { continue }
            cats.append(TwitchCategory(id: id, name: name, boxArtURL: c["box"] as? String ?? ""))
        }
        store.followedCategories = Array(cats.prefix(200))

        // Masqués : ajoutés aux nôtres, validés (pseudo, identifiant).
        var hidden = store.hidden
        hidden.merge(backup: root["hidden"])
        store.hidden = hidden

        if let s = root["settings"] as? [String: Any] { applySettings(s, to: store) }
        return (added, skipped)
    }

    /// Réglages d'une sauvegarde — ou d'une section reçue par la synchro des
    /// réglages — repris : chaque valeur validée ; une clé absente, inconnue
    /// ou invalide ne change rien.
    static func applySettings(_ s: [String: Any], to store: AppStore) {
        func bool(_ k: String, _ apply: (Bool) -> Void) { if let v = s[k] as? Bool { apply(v) } }
        func num(_ k: String, _ range: ClosedRange<Double>, _ apply: (Double) -> Void) {
            if let v = s[k] as? Double, range.contains(v) { apply(v) }
        }
        // Tailles du chat : ramenées dans les bornes des curseurs des Réglages.
        func size(_ k: String, _ range: ClosedRange<Double>, _ apply: (Double) -> Void) {
            if let v = s[k] as? Double, v.isFinite { apply(AppStore.clamped(v, to: range)) }
        }
        func words(_ k: String, _ max: Int, _ apply: ([String]) -> Void) {
            if let v = s[k] as? [String] { apply(Array(v.map { $0.lowercased() }.prefix(max))) }
        }

        if let l = s["lang"] as? String, let lang = Lang(rawValue: l) { store.lang = lang }
        // Langue du top : « zh_hk » du site ramené à « zh-hk », et seulement
        // une langue que l'app connaît (sinon aucune case n'était cochée).
        if s["topLang"] is NSNull { store.topLang = nil }
        else if let t = s["topLang"] as? String {
            let code = t.lowercased().replacingOccurrences(of: "_", with: "-")
            if TopLanguage.codes.contains(code) { store.topLang = code }
        }
        bool("homeList") { store.homeListLayout = $0 }
        bool("showRecent") { store.showRecentChannels = $0 }
        bool("ios_showDiscoverTab") { store.showDiscoverTab = $0 }
        // Après l'ancien réglage de Découvrir, qu'elle contient aussi.
        if let o = s["ios_customization"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: o),
           let c = try? JSONDecoder().decode(UICustomization.self, from: data) {
            store.customization = c
        }
        bool("timestamps") { store.chatTimestamps = $0 }
        if let v = s["timeFormat"] as? String, ["auto", "12", "24"].contains(v) { store.timeFormat = v }
        bool("keepDeleted") { store.chatShowDeleted = $0 }
        bool("loadHistory") { store.chatLoadRecent = $0 }
        bool("hideBots") { store.chatHideBots = $0 }
        bool("hideCommands") { store.chatHideCommands = $0 }
        words("mutedWords", 50) { store.chatMutedWords = $0 }
        words("blockedUsers", 500) { store.chatBlockedUsers = $0 }
        words("highlightWords", 30) { store.chatHighlightWords = $0 }
        bool("shareUsage") { store.shareUsage = $0 }
        num("vodSpeed", 0.25...2) { store.vodSpeed = VodSpeed.nearest($0) }

        bool("ios_autoClaimChest") { store.autoClaimChest = $0 }
        bool("ios_showPinned") { store.showPinnedMessages = $0 }
        bool("ios_showDropsNotice") { store.showDropsNotice = $0 }
        bool("ios_showFollowButton") { store.showFollowButton = $0 }
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
        if let q = s["ios_cellularQuality"] as? String, kCellularQualityPrefs.contains(q) { store.cellularQuality = q }
        bool("ios_higherQualities") { store.higherQualities = $0 }
        bool("ios_fillScreen") { store.fillScreen = $0 }
        if let v = s["ios_landscapeChat"] as? String, let lc = LandscapeChat(rawValue: v) { store.landscapeChat = lc }
        size("ios_chatFontSize", AppStore.chatFontRange) { store.chatFontSize = $0 }
        size("ios_chatSpacing", AppStore.chatSpacingRange) { store.chatSpacing = $0 }
        size("ios_chatBadgeScale", AppStore.chatScaleRange) { store.chatBadgeScale = $0 }
        size("ios_chatEmoteScale", AppStore.chatScaleRange) { store.chatEmoteScale = $0 }
        size("ios_chatWidthRatio", AppStore.chatWidthRange) { store.chatWidthRatio = $0 }
        bool("ios_chatAutocomplete") { store.chatAutocomplete = $0 }
        bool("ios_chatKeyboardSuggestions") { store.chatKeyboardSuggestions = $0 }
        bool("ios_chatReturnSends") { store.chatReturnSends = $0 }
        bool("ios_chatSync") { store.chatSync = $0 }
        bool("ios_downloadWifiOnly") { store.downloadWifiOnly = $0 }
        bool("ios_syncSettings") { store.syncSettings = $0 }
        // Qualité préférée (nom du site). « auto » du site devient « source »
        // tant que l'app n'a pas d'Auto ; une hauteur hors paliers retenue
        // par le lecteur du site (« 1440 », « 936 ») prend le palier le plus
        // proche, « source » au-dessus de 1080 ; sans elle (sauvegarde d'une
        // version d'avant), seul l'audio seul était retenu.
        if let q = s["qualityPref"] as? String {
            if kQualityPrefs.contains(q) { store.preferredQuality = q }
            else if q == "auto" { store.preferredQuality = "source" }
            else if let h = Int(q), h > 0 {
                store.preferredQuality = h > 1080 ? "source"
                    : String([1080, 720, 480, 360, 160].min { abs($0 - h) < abs($1 - h) } ?? 1080)
            }
        } else if let audio = s["ios_preferAudioOnly"] as? Bool {
            if audio { store.preferredQuality = "audio" }
            else if store.preferAudioOnly { store.preferredQuality = "source" }
        }
    }
}
