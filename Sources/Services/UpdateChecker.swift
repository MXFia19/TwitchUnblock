import Foundation
import UIKit

// MARK: – Détection de mise à jour
//
// L'app se met à jour par sa source (AltStore, SideStore, Feather), qui ne
// prévient pas toujours. Au retour au premier plan, au plus toutes les 6 h,
// on relit `apps.json` (la source elle-même) et on compare son numéro de
// build à celui de l'app installée.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Update: Equatable {
        let version: String      // « 1.0.199 »
        let build: Int
        let downloadURL: String?
    }

    /// Version plus récente que celle installée, sinon nil.
    @Published private(set) var available: Update? = nil
    /// Afficher l'alerte : une seule fois par version.
    @Published var showAlert = false

    static let sourceURL = "https://raw.githubusercontent.com/MXFia19/TwitchUnblock/master/apps.json"
    private let lastCheckKey = "update_last_check"
    private let dismissedKey = "update_dismissed_build"
    private let minInterval: TimeInterval = 6 * 3600

    /// Version installée (« 1.0.198 ») et son numéro de build.
    static var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    static var installedBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    func checkIfDue(force: Bool = false) async {
        let ud = UserDefaults.standard
        let last = ud.double(forKey: lastCheckKey)
        guard force || Date().timeIntervalSince1970 - last > minInterval else { return }
        // Build local (Xcode) : pas de numéro fiable, rien à comparer.
        guard Self.installedBuild > 1 else { return }

        // Contourne le cache du CDN de GitHub (quelques minutes).
        guard let url = URL(string: "\(Self.sourceURL)?t=\(Int(Date().timeIntervalSince1970 / 600))") else { return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let app = (json["apps"] as? [[String: Any]])?.first,
              let latest = (app["versions"] as? [[String: Any]])?.first,
              let buildStr = latest["buildVersion"] as? String, let build = Int(buildStr) else { return }
        ud.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

        guard build > Self.installedBuild else { available = nil; return }
        let update = Update(version: latest["version"] as? String ?? "build \(build)",
                            build: build,
                            downloadURL: latest["downloadURL"] as? String)
        available = update
        logger.info("UPDATE", "Mise à jour disponible", "\(Self.installedVersion) → \(update.version)")
        if ud.integer(forKey: dismissedKey) < build { showAlert = true }
    }

    /// Ouvre l'app de sideload installée (Feather, SideStore, AltStore) pour
    /// faire la mise à jour ; à défaut, la page des versions sur GitHub.
    static func openSource() {
        let candidates = ["feather://", "sidestore://", "altstore://"]
            .compactMap(URL.init(string:))
            .filter { UIApplication.shared.canOpenURL($0) }
        let target = candidates.first
            ?? URL(string: "https://github.com/MXFia19/TwitchUnblock/releases")!
        UIApplication.shared.open(target)
    }

    /// « Plus tard » : on ne reprévient pas pour cette version.
    func dismiss() {
        if let b = available?.build { UserDefaults.standard.set(b, forKey: dismissedKey) }
        showAlert = false
    }
}
