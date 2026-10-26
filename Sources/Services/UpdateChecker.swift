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
        /// Installation ratée : le numéro installé est celui de la dernière
        /// version, mais avec un build plus ancien, que la source ne connaît
        /// pas sous ce numéro. Cas réel : un outil d'installation (GBox) a
        /// posé un vieil IPA (build 254, une 1.2.x) sous le numéro « 1.6.0 »,
        /// et l'alerte annonçait une 1.6.0 qu'on croyait déjà avoir. Il faut
        /// supprimer l'app et réinstaller l'IPA (`downloadURL`).
        var mislabeled = false
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
        Int(installedBuildString) ?? 0
    }
    /// Numéro de build tel qu'écrit dans l'app (Réglages → À propos).
    static var installedBuildString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    /// Issue d'une vérification : « Rechercher une mise à jour » affichait
    /// « À jour » hors ligne (un échec ne se distinguait pas).
    enum Outcome { case upToDate, available, failed, skipped }

    /// `atLaunch` : au lancement, on vérifie toujours et on reprévient même si
    /// « Plus tard » a été choisi lors d'un lancement précédent.
    @discardableResult
    func checkIfDue(force: Bool = false, atLaunch: Bool = false) async -> Outcome {
        let force = force || atLaunch
        if atLaunch { UserDefaults.standard.removeObject(forKey: dismissedKey) }
        let ud = UserDefaults.standard
        let last = ud.double(forKey: lastCheckKey)
        guard force || Date().timeIntervalSince1970 - last > minInterval else { return .skipped }
        // Build local (Xcode) : pas de numéro fiable, rien à comparer.
        guard Self.installedBuild > 1 else { return .failed }

        guard let versions = await Self.fetchVersions(),
              let latest = versions.first,
              let buildStr = latest["buildVersion"] as? String, let build = Int(buildStr) else { return .failed }
        ud.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

        guard build > Self.installedBuild else { available = nil; return .upToDate }
        let version = latest["version"] as? String ?? "build \(build)"
        // Même numéro que la dernière version, build plus ancien : une vraie
        // installation de ce numéro a un build que la source liste sous lui
        // (chaque build a son propre numéro) ; sinon, c'est un vieil IPA
        // renuméroté par l'outil d'installation (voir Update.mislabeled).
        let mislabeled = version == Self.installedVersion && !versions.contains {
            $0["version"] as? String == Self.installedVersion
                && Int($0["buildVersion"] as? String ?? "") == Self.installedBuild
        }
        // Notes de tous les builds plus récents que celui installé ; aucune
        // pour une installation ratée : on croirait les avoir déjà.
        let changes: [Changes] = mislabeled ? []
            : versions.compactMap(Changes.init(entry:)).filter { $0.build > Self.installedBuild }
        let update = Update(version: version,
                            build: build,
                            downloadURL: latest["downloadURL"] as? String,
                            changes: changes,
                            mislabeled: mislabeled)
        available = update
        if mislabeled {
            logger.warn("UPDATE", "Ancien build installé sous le numéro de la dernière version",
                        "\(Self.installedVersion) (build \(Self.installedBuild)) au lieu du build \(build)")
        } else {
            logger.info("UPDATE", "Mise à jour disponible", "\(Self.installedVersion) → \(update.version)")
        }
        if ud.integer(forKey: dismissedKey) < build { showAlert = true }
        return .available
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
    /// faire la mise à jour ; à défaut, la page « Mettre à jour l'app » du
    /// site, qui dit quoi faire selon l'outil (ESign, GBox, Scarlet, KSign,
    /// TrollStore…). La page des versions sur GitHub ne l'expliquait pas.
    static func openSource() {
        let candidates = ["feather://", "sidestore://", "altstore://"]
            .compactMap(URL.init(string:))
            .filter { UIApplication.shared.canOpenURL($0) }
        let target = candidates.first
            ?? URL(string: "https://twitchunblock.vercel.app/?update=ios")!
        UIApplication.shared.open(target)
    }

    /// Ce qu'il faut faire d'une installation ratée (Update.mislabeled), dans
    /// la langue de l'app : alerte et Réglages → À propos.
    static func staleInstallMessage(_ store: AppStore) -> String {
        store.t("update_stale_msg")
            .replacingOccurrences(of: "{b}", with: installedBuildString)
            .replacingOccurrences(of: "{v}", with: installedVersion)
    }

    /// Installation ratée (Update.mislabeled) : l'IPA de la dernière version,
    /// à installer après avoir supprimé l'app ; à défaut, la page des
    /// versions sur GitHub.
    static func openDownload(_ link: String?) {
        let target = link.flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/MXFia19/TwitchUnblock/releases")!
        UIApplication.shared.open(target)
    }

    /// « Plus tard » : on ne reprévient pas pour cette version.
    func dismiss() {
        if let b = available?.build { UserDefaults.standard.set(b, forKey: dismissedKey) }
        showAlert = false
    }
}
