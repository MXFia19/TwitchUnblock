import SwiftUI
import UniformTypeIdentifiers

// ═══════════════════════════════════════════════════════════════════════════
//  Sauvegarde : export / import des suivis et des réglages dans un fichier.
//
//  Même format que le site : les chaînes et catégories suivies passent d'un
//  appareil à l'autre. Les réglages communs aux deux (langue, filtres du
//  chat…) portent le nom du site ; ceux propres à l'app sont préfixés
//  « ios_ » et ignorés par le site.
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
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return "twitchunblock-\(df.string(from: Date()))"
    }

    static func export(store: AppStore) -> Data {
        let settings: [String: Any] = [
            // Communs avec le site (mêmes noms)
            "lang": store.lang.rawValue,
            "topLang": store.topLang.map { $0 as Any } ?? NSNull(),
            "homeList": store.homeListLayout,
            "showRecent": store.showRecentChannels,
            "timestamps": store.chatTimestamps,
            "keepDeleted": store.chatShowDeleted,
            "loadHistory": store.chatLoadRecent,
            "hideBots": store.chatHideBots,
            "hideCommands": store.chatHideCommands,
            "mutedWords": store.chatMutedWords,
            "blockedUsers": store.chatBlockedUsers,
            "highlightWords": store.chatHighlightWords,
            "shareUsage": store.shareUsage,
            // Propres à l'app
            "ios_autoClaimChest": store.autoClaimChest,
            "ios_showPinned": store.showPinnedMessages,
            "ios_showFollowButton": store.showFollowButton,
            "ios_showWatchStreak": store.showWatchStreak,
            "ios_showLiveEvents": store.showLiveEvents,
            "ios_enableRaids": store.enableRaids,
            "ios_autoPurgeCache": store.autoPurgeImageCache,
            "ios_lowLatency": store.lowLatency,
            "ios_immersivePlayer": store.immersivePlayer,
            "ios_fillScreen": store.fillScreen,
            "ios_landscapeChat": store.landscapeChat.rawValue,
            "ios_chatFontSize": store.chatFontSize,
            "ios_chatSpacing": store.chatSpacing,
            "ios_chatBadgeScale": store.chatBadgeScale,
            "ios_chatEmoteScale": store.chatEmoteScale,
            "ios_chatWidthRatio": store.chatWidthRatio,
            "ios_chatAutocomplete": store.chatAutocomplete,
            "ios_preferAudioOnly": store.preferAudioOnly,
        ]
        let root: [String: Any] = [
            "format": format,
            "version": 1,
            "platform": "ios",
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "follows": store.localFollows,
            "accountFollows": store.accountFollowLogins,
            "followedCategories": store.followedCategories.map { ["id": $0.id, "name": $0.name, "box": $0.boxArtURL] },
            "settings": settings,
        ]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// Fusionne la sauvegarde : suivis ajoutés (rien n'est retiré), réglages
    /// connus repris. Renvoie le nombre de chaînes ajoutées.
    static func importData(_ data: Data, store: AppStore) throws -> Int {
        guard data.count < 2_000_000,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["format"] as? String == format else { throw ImportError.invalid }

        let validLogin = { (s: String) -> Bool in
            !s.isEmpty && s.count <= 25 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        }
        let incoming = ((root["follows"] as? [String] ?? []) + (root["accountFollows"] as? [String] ?? []))
            .map { $0.lowercased() }.filter(validLogin)
        var follows = store.localFollows
        var added = 0
        for l in incoming where !follows.contains(l) { follows.append(l); added += 1 }
        store.localFollows = Array(follows.prefix(300))

        var cats = store.followedCategories
        for c in root["followedCategories"] as? [[String: Any]] ?? [] {
            guard let id = c["id"] as? String, let name = c["name"] as? String,
                  !cats.contains(where: { $0.id == id }) else { continue }
            cats.append(TwitchCategory(id: id, name: name, boxArtURL: c["box"] as? String ?? ""))
        }
        store.followedCategories = Array(cats.prefix(200))

        guard let s = root["settings"] as? [String: Any] else { return added }
        func bool(_ k: String, _ apply: (Bool) -> Void) { if let v = s[k] as? Bool { apply(v) } }
        func num(_ k: String, _ range: ClosedRange<Double>, _ apply: (Double) -> Void) {
            if let v = s[k] as? Double, range.contains(v) { apply(v) }
        }
        func words(_ k: String, _ max: Int, _ apply: ([String]) -> Void) {
            if let v = s[k] as? [String] { apply(Array(v.map { $0.lowercased() }.prefix(max))) }
        }

        if let l = s["lang"] as? String, let lang = Lang(rawValue: l) { store.lang = lang }
        if s["topLang"] is NSNull { store.topLang = nil }
        else if let t = s["topLang"] as? String, t.count <= 8 { store.topLang = t }
        bool("homeList") { store.homeListLayout = $0 }
        bool("showRecent") { store.showRecentChannels = $0 }
        bool("timestamps") { store.chatTimestamps = $0 }
        bool("keepDeleted") { store.chatShowDeleted = $0 }
        bool("loadHistory") { store.chatLoadRecent = $0 }
        bool("hideBots") { store.chatHideBots = $0 }
        bool("hideCommands") { store.chatHideCommands = $0 }
        words("mutedWords", 50) { store.chatMutedWords = $0 }
        words("blockedUsers", 500) { store.chatBlockedUsers = $0 }
        words("highlightWords", 30) { store.chatHighlightWords = $0 }
        bool("shareUsage") { store.shareUsage = $0 }

        bool("ios_autoClaimChest") { store.autoClaimChest = $0 }
        bool("ios_showPinned") { store.showPinnedMessages = $0 }
        bool("ios_showFollowButton") { store.showFollowButton = $0 }
        bool("ios_showWatchStreak") { store.showWatchStreak = $0 }
        bool("ios_showLiveEvents") { store.showLiveEvents = $0 }
        bool("ios_enableRaids") { store.enableRaids = $0 }
        bool("ios_autoPurgeCache") { store.autoPurgeImageCache = $0 }
        bool("ios_lowLatency") { store.lowLatency = $0 }
        bool("ios_immersivePlayer") { store.immersivePlayer = $0 }
        bool("ios_fillScreen") { store.fillScreen = $0 }
        if let v = s["ios_landscapeChat"] as? String, let lc = LandscapeChat(rawValue: v) { store.landscapeChat = lc }
        num("ios_chatFontSize", 8...30) { store.chatFontSize = $0 }
        num("ios_chatSpacing", 0...30) { store.chatSpacing = $0 }
        num("ios_chatBadgeScale", 0.3...3) { store.chatBadgeScale = $0 }
        num("ios_chatEmoteScale", 0.3...3) { store.chatEmoteScale = $0 }
        num("ios_chatWidthRatio", 0.1...0.9) { store.chatWidthRatio = $0 }
        bool("ios_chatAutocomplete") { store.chatAutocomplete = $0 }
        bool("ios_preferAudioOnly") { store.preferAudioOnly = $0 }
        return added
    }
}
