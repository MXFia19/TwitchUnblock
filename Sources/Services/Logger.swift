import Foundation
import Combine

final class AppLogger: ObservableObject {
    static let shared = AppLogger()
    private init() {}

    @Published private(set) var logs: [LogEntry] = []
    private var counter = 0
    private let maxLogs = 500

    // ─── Core add ───────────────────────────────────────────────
    private func add(_ level: LogLevel, _ category: String, _ message: String, _ detail: String? = nil) {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let ms = Calendar.current.component(.nanosecond, from: now) / 1_000_000
        let timestamp = formatter.string(from: now) + String(format: ".%03d", ms)
        let entry = LogEntry(id: counter, timestamp: timestamp, level: level,
                             category: category, message: message, detail: detail)
        counter += 1
        DispatchQueue.main.async {
            self.logs.insert(entry, at: 0)
            if self.logs.count > self.maxLogs {
                self.logs = Array(self.logs.prefix(self.maxLogs))
            }
        }
        let icons = ["info": "ℹ️", "success": "✅", "warn": "⚠️", "error": "❌", "debug": "🔍"]
        let icon = icons[level.rawValue] ?? "•"
        print("\(icon) [\(category)] \(message)\(detail.map { " → \($0)" } ?? "")")
    }

    func info   (_ c: String, _ m: String, _ d: String? = nil) { add(.info,    c, m, d) }
    func success(_ c: String, _ m: String, _ d: String? = nil) { add(.success, c, m, d) }
    func warn   (_ c: String, _ m: String, _ d: String? = nil) { add(.warn,    c, m, d) }
    func error  (_ c: String, _ m: String, _ d: String? = nil) { add(.error,   c, m, d) }
    func debug  (_ c: String, _ m: String, _ d: String? = nil) { add(.debug,   c, m, d) }
    func clear() { DispatchQueue.main.async { self.logs = [] } }

    // ─── Session ─────────────────────────────────────────────────
    func sessionStart() {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        formatter.locale = Locale(identifier: "fr_FR")
        info("SESSION", "━━━ Nouvelle session démarrée ━━━", formatter.string(from: Date()))
    }

    // ─── Réseau ──────────────────────────────────────────────────
    func network(_ method: String, _ url: String, status: Int? = nil, duration: Double? = nil) {
        let statusStr = status.map { " → HTTP \($0)" } ?? ""
        let durationStr = duration.map { String(format: " (%.0fms)", $0 * 1000) } ?? ""
        let level: LogLevel = status.map { $0 >= 400 ? .error : $0 >= 300 ? .warn : .success } ?? .debug
        add(level, "RÉSEAU", "\(method) \(url)\(statusStr)\(durationStr)")
    }

    // ─── Lecture ─────────────────────────────────────────────────
    func playStart(_ type: String, id: String, title: String? = nil) {
        info("LECTEUR", "▶️ Début \(type) : \(id)", title)
    }
    func playQuality(_ quality: String, url: String) {
        success("LECTEUR", "🎬 Qualité sélectionnée : \(quality)", url)
    }
    func playProgress(_ id: String, seconds: Double) {
        debug("LECTEUR", "⏱ Progression VOD \(id)", String(format: "%.0fs (%.1f min)", seconds, seconds / 60))
    }
    func playError(_ type: String, reason: String) {
        error("LECTEUR", "❌ Erreur lecture \(type)", reason)
    }

    // ─── Auth ────────────────────────────────────────────────────
    func authLogin(user: String) {
        success("AUTH", "🟣 Connexion Twitch réussie", "Utilisateur : \(user)")
    }
    func authLogout() {
        warn("AUTH", "🚪 Déconnexion Twitch")
    }
    func authTokenExpired() {
        error("AUTH", "⏰ Token Twitch expiré — reconnexion requise")
    }

    // ─── Recherche ───────────────────────────────────────────────
    func searchStreamer(_ name: String) {
        info("RECHERCHE", "🔍 Recherche streamer : \(name)")
    }
    func searchResult(_ name: String, vods: Int, isLive: Bool) {
        success("RECHERCHE", "📋 Résultats pour \(name)", "\(vods) VODs — Live: \(isLive ? "✅" : "❌")")
    }

    // ─── VOD ─────────────────────────────────────────────────────
    func vodUnlock(_ id: String, method: String, qualities: [String]) {
        success("VOD", "🔓 VOD \(id) déverrouillée via \(method)", "\(qualities.count) qualités : \(qualities.joined(separator: ", "))")
    }
    func vodFailed(_ id: String) {
        error("VOD", "❌ Impossible de débloquer VOD \(id)", "Toutes les méthodes ont échoué")
    }

    // ─── Navigation ──────────────────────────────────────────────
    func tabChange(_ tab: String) {
        debug("NAV", "📑 Onglet : \(tab)")
    }

    // ─── Settings ────────────────────────────────────────────────
    func settingChanged(_ key: String, value: String) {
        info("SETTINGS", "⚙️ \(key) → \(value)")
    }

    // ─── Historique ──────────────────────────────────────────────
    func historyAdded(_ type: String, term: String) {
        debug("HISTORIQUE", "📝 Ajouté (\(type)) : \(term)")
    }
    func historyCleared() {
        warn("HISTORIQUE", "🗑 Historique effacé")
    }

    // ─── Qualité exportée ────────────────────────────────────────
    func exportExternal(_ app: String, quality: String) {
        info("EXPORT", "📤 Ouverture dans \(app)", "Qualité : \(quality)")
    }

    // ─── Sync cloud ──────────────────────────────────────────────
    func syncPull(items: Int) {
        success("SYNC", "☁️ Sync cloud — \(items) éléments récupérés")
    }
    func syncPush(items: Int) {
        debug("SYNC", "☁️ Sync cloud — \(items) éléments envoyés")
    }
}

let logger = AppLogger.shared
