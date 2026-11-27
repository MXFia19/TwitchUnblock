import Foundation
import Combine
import UIKit

// MARK: – Heure affichée (12 h / 24 h)
/// Format de l'heure du chat et du journal : réglage `cfg_time_format`
/// (« auto », « 12 », « 24 ») ; « auto » suit l'appareil (Réglages iOS →
/// Général → Date et heure, ou la région).
enum ClockFormat {
    static let key = "cfg_time_format"
    /// Format de l'appareil, lu une fois : 12 h si son modèle d'heure a AM/PM.
    static let device12h: Bool =
        (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")

    static func uses12h(_ pref: String? = UserDefaults.standard.string(forKey: ClockFormat.key)) -> Bool {
        switch pref ?? "auto" {
        case "12": return true
        case "24": return false
        default:   return device12h
        }
    }

    /// « 8:05 PM » ou « 20:05 » ; le journal ajoute secondes et millièmes.
    static func pattern(seconds: Bool = false, twelve: Bool = ClockFormat.uses12h()) -> String {
        let time = twelve ? "h:mm" : "HH:mm"
        let rest = seconds ? ":ss.SSS" : ""
        return twelve ? "\(time)\(rest) a" : "\(time)\(rest)"
    }
}

final class AppLogger: ObservableObject {
    static let shared = AppLogger()

    @Published private(set) var logs: [LogEntry] = []
    private var counter = 0
    /// Gardées d'un lancement à l'autre : de quoi couvrir plusieurs sessions.
    private let maxLogs = 1000
    /// Ajout de la dernière ligne (regroupement des répétitions).
    private var lastAddedAt = Date.distantPast

    /// Fichier du journal : les erreurs d'une session précédente, ou d'avant
    /// un plantage, restent lisibles (il ne vivait qu'en mémoire et
    /// disparaissait avec l'app). Caches : seul dossier inscriptible sur tvOS.
    private static let fileURL: URL? = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("twitchunblock-logs.json")
    private let saveQueue = DispatchQueue(label: "twitchunblock.logs.save", qos: .utility)
    private var saveScheduled = false
    /// Vrai tant que l'app est au premier plan. Encore vrai au lancement
    /// suivant : la session précédente s'est arrêtée d'un coup (plantage,
    /// mémoire épuisée…), et non par une sortie normale.
    private static let foregroundKey = "log_in_foreground"

    private init() {
        if let url = Self.fileURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([LogEntry].self, from: data) {
            logs = Array(saved.prefix(maxLogs))
            counter = (saved.map(\.id).max() ?? -1) + 1
        }
        let ud = UserDefaults.standard
        if ud.bool(forKey: Self.foregroundKey) {
            ud.set(false, forKey: Self.foregroundKey)
            // Figée avant l'arrêt (MainThreadWatch) : fermée de force, pas un
            // plantage — « App just freezes and have to hard close ».
            let start = ud.double(forKey: MainThreadWatch.startKey)
            let frozen = start > 0 ? Int(max(ud.double(forKey: MainThreadWatch.lastKey) - start, 3)) : nil
            if let frozen {
                logs.insert(LogEntry(id: counter, timestamp: Self.stamp(Date()), level: .error, category: "APP",
                                     message: "Arrêt de l'app figée pendant la session précédente",
                                     detail: "Fil principal bloqué depuis au moins \(frozen) s, puis app fermée : les lignes juste en dessous montrent ce qui se passait."),
                            at: 0)
            } else {
                logs.insert(LogEntry(id: counter, timestamp: Self.stamp(Date()), level: .error, category: "APP",
                                     message: "Arrêt brutal de l'app pendant la session précédente (plantage probable)",
                                     detail: "Elle était au premier plan : les lignes juste en dessous montrent ce qui se passait."),
                            at: 0)
            }
            counter += 1
        }
        ud.removeObject(forKey: MainThreadWatch.startKey)
        ud.removeObject(forKey: MainThreadWatch.lastKey)
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            UserDefaults.standard.set(true, forKey: Self.foregroundKey)
            self?.debug("APP", "Premier plan", nil)
        }
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            UserDefaults.standard.set(false, forKey: Self.foregroundKey)
            self?.debug("APP", "Arrière-plan", nil)
            self?.saveNow()
        }
        nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            UserDefaults.standard.set(false, forKey: Self.foregroundKey)
            self?.saveNow(sync: true)
        }
        // Exception non rattrapée : notée et écrite avant l'arrêt de l'app.
        NSSetUncaughtExceptionHandler { exception in
            AppLogger.shared.recordCrash(exception)
        }
        MainThreadWatch.shared.start()
    }

    private static func stamp(_ date: Date) -> String {
        stampFormatters[ClockFormat.uses12h()]?.string(from: date) ?? ""
    }

    /// Écrit le journal dans son fichier (en tâche de fond ; `sync` : tout de
    /// suite, l'app va s'arrêter). À appeler sur le fil principal.
    func saveNow(sync: Bool = false) {
        guard let url = Self.fileURL else { return }
        let snapshot = logs
        let write = {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
        if sync { write() } else { saveQueue.async(execute: write) }
    }

    /// Une écriture au plus toutes les 10 s pendant que le journal se remplit.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.saveScheduled = false
            self?.saveNow()
        }
    }

    fileprivate func recordCrash(_ e: NSException) {
        let detail = ([e.reason ?? ""] + e.callStackSymbols.prefix(12)).joined(separator: "\n")
        var snapshot = logs
        snapshot.insert(LogEntry(id: counter, timestamp: Self.stamp(Date()), level: .error, category: "CRASH",
                                 message: "Plantage : \(e.name.rawValue)", detail: detail), at: 0)
        if let url = Self.fileURL, let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Nombre de lignes d'un niveau (comptées avec leurs répétitions).
    func count(_ level: LogLevel) -> Int {
        logs.reduce(0) { $0 + ($1.level == level ? $1.repeats : 0) }
    }

    /// Un formateur par format (12 h, 24 h), gardé : en créer un à chaque ligne
    /// coûtait cher. Locale POSIX : iOS ne réécrit plus le format fixe selon
    /// la région (« 3:04:05 PM.123 »).
    private static let stampFormatters: [Bool: DateFormatter] = {
        var out: [Bool: DateFormatter] = [:]
        for twelve in [false, true] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = ClockFormat.pattern(seconds: true, twelve: twelve)
            out[twelve] = f
        }
        return out
    }()

    // ─── Core add ───────────────────────────────────────────────
    private func add(_ level: LogLevel, _ category: String, _ message: String, _ detail: String? = nil) {
        let now = Date()
        // 12 h ou 24 h selon le réglage (millièmes compris).
        let timestamp = Self.stampFormatters[ClockFormat.uses12h()]?.string(from: now) ?? ""
        // Identifiant attribué sur le fil principal : incrémenté depuis
        // plusieurs fils, le compteur pouvait donner deux fois le même id.
        DispatchQueue.main.async {
            // Même ligne que la précédente, moins de 30 s après : comptée
            // (« ×3 ») au lieu d'être répétée — une rafale d'erreurs ne
            // repousse plus tout le reste hors du journal.
            if var last = self.logs.first, last.level == level, last.category == category,
               last.message == message, last.detail == detail,
               now.timeIntervalSince(self.lastAddedAt) < 30 {
                last.repeats += 1
                last.timestamp = timestamp
                self.logs[0] = last
            } else {
                let entry = LogEntry(id: self.counter, timestamp: timestamp, level: level,
                                     category: category, message: message, detail: detail)
                self.counter += 1
                self.logs.insert(entry, at: 0)
                if self.logs.count > self.maxLogs {
                    self.logs.removeLast(self.logs.count - self.maxLogs)
                }
            }
            self.lastAddedAt = now
            self.scheduleSave()
        }
        #if DEBUG
        let icons = ["info": "ℹ️", "success": "✅", "warn": "⚠️", "error": "❌", "debug": "🔍"]
        let icon = icons[level.rawValue] ?? "•"
        print("\(icon) [\(category)] \(message)\(detail.map { " → \($0)" } ?? "")")
        #endif
    }

    func info   (_ c: String, _ m: String, _ d: String? = nil) { add(.info,    c, m, d) }
    func success(_ c: String, _ m: String, _ d: String? = nil) { add(.success, c, m, d) }
    func warn   (_ c: String, _ m: String, _ d: String? = nil) { add(.warn,    c, m, d) }
    func error  (_ c: String, _ m: String, _ d: String? = nil) { add(.error,   c, m, d) }
    func debug  (_ c: String, _ m: String, _ d: String? = nil) { add(.debug,   c, m, d) }
    func clear() { DispatchQueue.main.async { self.logs = []; self.saveNow() } }

    // ─── Session ─────────────────────────────────────────────────
    /// Début d'une session : date complète (le journal garde plusieurs
    /// sessions, ses lignes n'ont que l'heure), version et système.
    func sessionStart() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        self.info("SESSION", "━━━ Nouvelle session démarrée ━━━",
                  "\(formatter.string(from: Date())) · \(version) · \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
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

// MARK: – Fil principal bloqué
/// L'app gèle (le fil principal ne répond plus) et finit fermée de force, ce
/// que le journal prenait pour un plantage (fb_mwy5ueg4 : « App just freezes
/// and have to hard close »). Un fil à part demande un signe de vie au fil
/// principal toutes les demi-secondes, app au premier plan seulement.
/// Débloqué : une ligne avec la durée. Fermée pendant le blocage : le
/// lancement suivant le dit (début, et dernier instant vu bloqué, gardés dans
/// les réglages, lisibles d'un fil à l'autre).
private final class MainThreadWatch {
    static let shared = MainThreadWatch()
    static let startKey = "log_hang_start"
    static let lastKey = "log_hang_last"
    /// Blocage noté à partir de 3 s.
    private static let threshold: TimeInterval = 3

    private let lock = NSLock()
    // Sous `lock`.
    private var lastPong = Date()
    /// Premier plan depuis ; nil hors du premier plan (l'app suspendue en
    /// arrière-plan ne répond pas non plus, sans être bloquée).
    private var activeSince: Date?
    // Sur `queue`.
    private var hangStart: Date?
    private let queue = DispatchQueue(label: "twitchunblock.mainwatch", qos: .utility)
    private var timer: DispatchSourceTimer?

    func start() {
        guard timer == nil else { return }
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setActive(true)
        }
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setActive(false)
        }
        DispatchQueue.main.async { [weak self] in
            if UIApplication.shared.applicationState == .active { self?.setActive(true) }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 0.5, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func setActive(_ on: Bool) {
        lock.lock()
        activeSince = on ? Date() : nil
        lastPong = Date()
        lock.unlock()
    }

    /// Sur `queue` : signe de vie demandé ; sans réponse depuis le seuil, le
    /// blocage est retenu pour le lancement suivant.
    private func tick() {
        DispatchQueue.main.async { [weak self] in self?.pong() }
        lock.lock()
        let since = Date().timeIntervalSince(lastPong)
        let active = activeSince != nil
        lock.unlock()
        guard active, since >= Self.threshold else { return }
        let now = Date()
        let ud = UserDefaults.standard
        if hangStart == nil {
            let start = now.addingTimeInterval(-since)
            hangStart = start
            ud.set(start.timeIntervalSince1970, forKey: Self.startKey)
        }
        ud.set(now.timeIntervalSince1970, forKey: Self.lastKey)
    }

    /// Fil principal : signe de vie. Après un blocage, sa durée au journal.
    private func pong() {
        let now = Date()
        lock.lock()
        let gap = now.timeIntervalSince(lastPong)
        // Attente commencée au premier plan : pas une suspension de l'app.
        let counted = activeSince.map { lastPong >= $0 } ?? false
        lastPong = now
        lock.unlock()
        queue.async { [weak self] in
            guard let self, self.hangStart != nil else { return }
            self.hangStart = nil
            UserDefaults.standard.removeObject(forKey: Self.startKey)
            UserDefaults.standard.removeObject(forKey: Self.lastKey)
        }
        guard counted, gap >= Self.threshold else { return }
        logger.warn("APP", "Fil principal bloqué", String(format: "%.1f s", gap))
    }
}
