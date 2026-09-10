import Foundation
import Combine

/// Minuteur de veille : coupe la lecture au bout d'un délai choisi.
///
/// Le service ne connaît pas le lecteur : il incrémente `fireCount` à l'échéance,
/// et `MainTabView` observe ce compteur pour arrêter la lecture. Ça évite une
/// dépendance circulaire entre la vue et le service.
///
/// Tout se passe sur le thread principal : le minuteur est armé depuis l'interface
/// et son `Timer` tourne sur la run loop principale (comme les timers du lecteur).
final class SleepTimerService: ObservableObject {
    static let shared = SleepTimerService()

    /// Date d'échéance (nil = minuteur inactif).
    @Published private(set) var endDate: Date? = nil
    /// Secondes restantes, rafraîchies chaque seconde (0 si inactif).
    @Published private(set) var remaining: Int = 0
    /// Incrémenté à chaque déclenchement — sert de signal à la vue.
    @Published private(set) var fireCount: Int = 0

    /// Durées proposées dans les Réglages et le lecteur (minutes).
    static let presets = [15, 30, 45, 60, 90, 120]

    private var ticker: Timer?

    private init() {}

    var isActive: Bool { endDate != nil }

    /// Compte à rebours formaté « 1:23:45 » ou « 23:45 ».
    var label: String {
        let s = max(0, remaining)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }

    func start(minutes: Int) {
        guard minutes > 0 else { return }
        stopTicker()
        endDate   = Date().addingTimeInterval(TimeInterval(minutes * 60))
        remaining = minutes * 60
        logger.info("SLEEP", "Minuteur de veille armé", "\(minutes) min")
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// Rallonge (ou raccourcit) le minuteur en cours.
    func add(minutes: Int) {
        guard let end = endDate else { return start(minutes: max(0, minutes)) }
        let newEnd = end.addingTimeInterval(TimeInterval(minutes * 60))
        guard newEnd > Date() else { return cancel() }
        endDate   = newEnd
        remaining = Int(newEnd.timeIntervalSinceNow.rounded())
        logger.info("SLEEP", "Minuteur ajusté", "\(minutes > 0 ? "+" : "")\(minutes) min → \(label)")
    }

    func cancel() {
        guard endDate != nil else { return }
        stopTicker()
        endDate   = nil
        remaining = 0
        logger.info("SLEEP", "Minuteur de veille annulé", nil)
    }

    private func tick() {
        guard let end = endDate else { return stopTicker() }
        let left = Int(end.timeIntervalSinceNow.rounded())
        if left <= 0 {
            stopTicker()
            endDate   = nil
            remaining = 0
            fireCount += 1
            logger.success("SLEEP", "Minuteur écoulé → arrêt de la lecture", nil)
        } else {
            remaining = left
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}
