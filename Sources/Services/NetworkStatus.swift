import Foundation
import Network

// ═══════════════════════════════════════════════════════════════════════════
//  Type de connexion, suivi en continu (NWPathMonitor).
//
//  En données mobiles, le débit varie et peut tomber sous celui de la qualité
//  « Source » d'un direct : l'image gelait (calages en boucle) pendant que le
//  chat, lui, continuait. Le lecteur démarre alors dans la qualité choisie
//  pour les données mobiles (« Auto » par défaut : elle suit le débit) et
//  garde plus d'avance sur le bord du direct.
//
//  Chaque changement est annoncé (.tuNetworkChanged : téléchargements en
//  « Wi-Fi seulement »), et le retour après une coupure aussi
//  (.tuNetworkRestored : les lectures en échec se relancent).
// ═══════════════════════════════════════════════════════════════════════════
final class NetworkStatus {
    static let shared = NetworkStatus()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var cellular = false
    private var constrained = false
    private var online = false
    private var described = ""

    /// Données mobiles (ou connexion que le système dit coûteuse : partage de
    /// connexion d'un iPhone).
    var isCellular: Bool { lock.lock(); defer { lock.unlock() }; return cellular }
    /// Connecté, quel que soit le réseau (faux avant le premier état).
    var isOnline: Bool { lock.lock(); defer { lock.unlock() }; return online }
    /// Mode « données réduites » d'iOS activé pour cette connexion.
    var isConstrained: Bool { lock.lock(); defer { lock.unlock() }; return constrained }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let isCell = path.usesInterfaceType(.cellular) || path.isExpensive
            let state = path.status != .satisfied ? "off" : isCell ? "cell" : "wifi"
            let key = state + (path.isConstrained ? "-low" : "")
            self.lock.lock()
            self.cellular = isCell
            self.constrained = path.isConstrained
            self.online = path.status == .satisfied
            let changed = key != self.described
            // Hors ligne avant, connecté maintenant (pas au premier état).
            let restored = self.described.hasPrefix("off") && state != "off"
            self.described = key
            self.lock.unlock()
            // Dans le journal : un gel de l'image se lit avec la connexion du moment.
            guard changed else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .tuNetworkChanged, object: nil)
                if restored { NotificationCenter.default.post(name: .tuNetworkRestored, object: nil) }
            }
            switch state {
            case "off":  logger.warn("RÉSEAU", "Connexion : hors ligne", nil)
            case "cell": logger.info("RÉSEAU", "Connexion : données mobiles", path.isConstrained ? "mode données réduites" : nil)
            default:     logger.info("RÉSEAU", "Connexion : Wi-Fi ou filaire", path.isConstrained ? "mode données réduites" : nil)
            }
        }
        monitor.start(queue: DispatchQueue(label: "twitchunblock.network", qos: .utility))
    }

    /// À appeler au lancement : le premier état arrive tout de suite après.
    static func start() { _ = shared }
}

extension Notification.Name {
    /// Connexion changée (Wi-Fi, données mobiles, hors ligne), sur la file
    /// principale : `NetworkStatus.shared` dit la nouvelle.
    static let tuNetworkChanged = Notification.Name("TUNetworkChanged")
    /// Connexion revenue après une coupure, sur la file principale.
    static let tuNetworkRestored = Notification.Name("TUNetworkRestored")
}
