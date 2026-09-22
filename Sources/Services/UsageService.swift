import Foundation
import Combine
import UIKit

// ═══════════════════════════════════════════════════════════════════════════
//  Comptage d'utilisation.
//
//  L'app signale « je suis vivante » au Worker, qui compte les identifiants
//  distincts. Ce qui part du téléphone se limite à trois choses :
//
//    • un identifiant tiré au hasard à la première ouverture, propre à cette
//      installation — aucun lien avec le compte Twitch, ni avec l'appareil
//      (pas d'IDFV, pas de numéro de série) ;
//    • la version de l'app ;
//    • « ios ».
//
//  Pas de pseudo, pas de chaîne regardée, pas d'historique. Le Worker ne
//  conserve pas les adresses IP. Le comptage est débrayable dans les Réglages,
//  et le retrait efface l'identifiant côté serveur.
// ═══════════════════════════════════════════════════════════════════════════

/// Nombre d'installations actives sur une version donnée.
struct UsageVersion: Identifiable {
    var id: String { version }
    let version: String
    let count: Int
}

/// Fidélité : combien de JOURS DISTINCTS chaque installation a été utilisée.
struct UsageLoyalty {
    /// Ouverte un seul jour — quelqu'un qui a essayé puis n'est pas revenu.
    let once: Int
    /// 2 à 6 jours.
    let few: Int
    /// 7 à 29 jours.
    let regular: Int
    /// 30 jours et plus.
    let daily: Int

    var total: Int { once + few + regular + daily }
}

struct UsageStats {
    /// Identifiants distincts vus aujourd'hui / sur 7 jours / sur 30 jours.
    let today: Int
    let week:  Int
    let month: Int
    /// Installations connues sur la fenêtre de rétention (35 jours).
    let known: Int
    /// Installations revues au moins un deuxième jour.
    let returning: Int
    /// Répartition par nombre de jours d'utilisation.
    let loyalty: UsageLoyalty
    /// Moyenne de jours d'utilisation par installation.
    let avgDays: Double
    /// Date de la plus ancienne installation encore comptée (AAAA-MM-JJ).
    let oldestFirst: String?
    /// Répartition par version, la plus répandue en tête.
    let versions: [UsageVersion]

    /// Part des installations qui sont revenues au moins une fois, en %.
    var returnRate: Int {
        guard known > 0 else { return 0 }
        return Int((Double(returning) / Double(known) * 100).rounded())
    }
}

@MainActor
final class UsageService: ObservableObject {
    static let shared = UsageService()

    @Published private(set) var stats: UsageStats? = nil
    @Published private(set) var loading  = false
    /// Renseigné quand le Worker ne répond pas encore (routes non déployées).
    @Published private(set) var lastError: String? = nil

    /// Identifiant de cette installation. Tiré une fois, gardé localement.
    private(set) var installId: String

    private var lastPing: Date? = nil
    /// Un ping par heure au plus : le but est de compter des journées actives,
    /// pas de suivre les allers-retours dans l'app.
    private let pingInterval: TimeInterval = 3600

    private init() {
        let ud = UserDefaults.standard
        if let existing = ud.string(forKey: "usage_install_id") {
            installId = existing
        } else {
            installId = UUID().uuidString
            ud.set(installId, forKey: "usage_install_id")
        }
        if let t = ud.object(forKey: "usage_last_ping") as? Double {
            lastPing = Date(timeIntervalSince1970: t)
        }
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    // MARK: – Ping
    /// Signale l'installation au Worker. Sans effet si le comptage est coupé.
    func ping(enabled: Bool, force: Bool = false) async {
        guard enabled else { return }
        if !force, let last = lastPing, Date().timeIntervalSince(last) < pingInterval {
            return
        }
        guard let url = URL(string: "\(kAPIURL)/api/ping") else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "id": installId,
            "version": appVersion,
            "platform": "ios",
        ])

        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                logger.debug("USAGE", "Ping refusé par le serveur", "HTTP \(code)")
                return
            }
            lastPing = Date()
            UserDefaults.standard.set(lastPing!.timeIntervalSince1970, forKey: "usage_last_ping")
            logger.debug("USAGE", "Ping envoyé", "version \(appVersion)")
        } catch {
            logger.debug("USAGE", "Ping impossible", error.localizedDescription)
        }
    }

    // MARK: – Lecture des compteurs
    func loadStats() async {
        guard let url = URL(string: "\(kAPIURL)/api/stats") else { return }
        loading = true
        lastError = nil
        defer { loading = false }

        // Sans cette politique, « Actualiser » peut resservir la copie locale
        // d'URLSession et afficher deux fois les mêmes chiffres.
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                // 404 = le Worker n'a pas encore les routes de comptage.
                lastError = code == 404 ? "worker_missing" : "http_\(code)"
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                lastError = "bad_payload"; return
            }
            let versions = (json["versions"] as? [[String: Any]] ?? []).compactMap {
                v -> UsageVersion? in
                guard let name = v["version"] as? String,
                      let n = v["count"] as? Int else { return nil }
                return UsageVersion(version: name, count: n)
            }
            // Champs absents si le Worker n'a pas encore la mesure de fidélité :
            // tout retombe alors sur zéro plutôt que d'échouer.
            let l = json["loyalty"] as? [String: Any] ?? [:]
            stats = UsageStats(
                today: json["today"] as? Int ?? 0,
                week:  json["week"]  as? Int ?? 0,
                month: json["month"] as? Int ?? 0,
                known: json["known"] as? Int ?? 0,
                returning: json["returning"] as? Int ?? 0,
                loyalty: UsageLoyalty(
                    once:    l["once"]    as? Int ?? 0,
                    few:     l["few"]     as? Int ?? 0,
                    regular: l["regular"] as? Int ?? 0,
                    daily:   l["daily"]   as? Int ?? 0
                ),
                avgDays: json["avgDays"] as? Double ?? 0,
                oldestFirst: json["oldestFirst"] as? String,
                versions: versions
            )
            logger.success("USAGE", "Compteurs reçus",
                           "aujourd'hui \(stats?.today ?? 0) · 30 j \(stats?.month ?? 0)")
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: – Retrait
    /// Efface cette installation côté serveur (quand on coupe le comptage).
    func forget() async {
        guard let url = URL(string: "\(kAPIURL)/api/ping") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "id": installId,
            "forget": true,
        ])
        _ = try? await URLSession.shared.data(for: req)
        lastPing = nil
        UserDefaults.standard.removeObject(forKey: "usage_last_ping")
        logger.info("USAGE", "Retrait du comptage demandé", nil)
    }
}
