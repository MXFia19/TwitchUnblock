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
        /// Nouveautés de chaque build manquant, du plus récent au plus ancien :
        /// deux builds de retard → les notes des deux.
        let changes: [Changes]
    }
    struct Changes: Equatable, Identifiable {
        let version: String
        let build: Int
        let items: [String]
        /// Date du build telle qu'écrite par le CI (« 2026-10-06 »).
        var date = ""
        var id: Int { build }

        /// Une entrée `versions` de la source ; ses notes sont les lignes
        /// « - … » de `localizedDescription`. nil sans numéro ni notes.
        init?(entry v: [String: Any]) {
            guard let b = Int(v["buildVersion"] as? String ?? "") else { return nil }
            let items = (v["localizedDescription"] as? String ?? "")
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("- ") }
                .map { String($0.dropFirst(2)) }
            guard !items.isEmpty else { return nil }
            self.version = v["version"] as? String ?? "build \(b)"
            self.build = b
            self.items = items
            self.date = v["date"] as? String ?? ""
        }
    }

    /// Version plus récente que celle installée, sinon nil.
    @Published private(set) var available: Update? = nil
    /// Afficher l'alerte : une seule fois par version.
    @Published var showAlert = false

    /// Canal écrit par le CI : « test » pour les builds de la branche de test
    /// (app « TU Test »), qui ont leur propre source ; l'app normale ne lit
    /// que apps.json sur master et ne voit jamais les builds de test.
    static var isTestBuild: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "TUChannel") as? String) == "test"
    }
    static var sourceURL: String {
        isTestBuild
            ? "https://raw.githubusercontent.com/MXFia19/TwitchUnblock/test-17d298/apps-test.json"
            : "https://raw.githubusercontent.com/MXFia19/TwitchUnblock/master/apps.json"
    }
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

    /// `atLaunch` : au lancement, on vérifie toujours et on reprévient même si
    /// « Plus tard » a été choisi lors d'un lancement précédent.
    func checkIfDue(force: Bool = false, atLaunch: Bool = false) async {
        let force = force || atLaunch
        if atLaunch { UserDefaults.standard.removeObject(forKey: dismissedKey) }
        let ud = UserDefaults.standard
        let last = ud.double(forKey: lastCheckKey)
        guard force || Date().timeIntervalSince1970 - last > minInterval else { return }
        // Build local (Xcode) : pas de numéro fiable, rien à comparer.
        guard Self.installedBuild > 1 else { return }

        guard let versions = await Self.fetchVersions(),
              let latest = versions.first,
              let buildStr = latest["buildVersion"] as? String, let build = Int(buildStr) else { return }
        ud.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

        guard build > Self.installedBuild else { available = nil; return }
        // Notes de tous les builds plus récents que celui installé.
        let changes = versions.compactMap(Changes.init(entry:)).filter { $0.build > Self.installedBuild }
        let update = Update(version: latest["version"] as? String ?? "build \(build)",
                            build: build,
                            downloadURL: latest["downloadURL"] as? String,
                            changes: changes)
        available = update
        logger.info("UPDATE", "Mise à jour disponible", "\(Self.installedVersion) → \(update.version)")
        if ud.integer(forKey: dismissedKey) < build { showAlert = true }
    }

    /// Historique de la source (`versions`, du plus récent au plus ancien).
    /// nil si elle est injoignable.
    private static func fetchVersions() async -> [[String: Any]]? {
        // Contourne le cache du CDN de GitHub (quelques minutes).
        guard let url = URL(string: "\(sourceURL)?t=\(Int(Date().timeIntervalSince1970 / 600))") else { return nil }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let app = (json["apps"] as? [[String: Any]])?.first else { return nil }
        return app["versions"] as? [[String: Any]]
    }

    /// Journal des modifications des réglages : les notes de chaque build
    /// publié par la source (les 30 derniers, que garde le CI).
    static func history() async -> [Changes]? {
        await fetchVersions()?.compactMap(Changes.init(entry:))
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
