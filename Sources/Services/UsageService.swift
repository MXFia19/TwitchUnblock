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

struct UsageStats {
    /// Identifiants distincts vus aujourd'hui / sur 7 jours / sur 30 jours.
    let today: Int
    let week:  Int
    let month: Int
    /// Installations connues sur la fenêtre de rétention (35 jours).
    let known: Int
    /// Répartition par version, la plus répandue en tête.
    let versions: [UsageVersion]
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

        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
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
            stats = UsageStats(
                today: json["today"] as? Int ?? 0,
                week:  json["week"]  as? Int ?? 0,
                month: json["month"] as? Int ?? 0,
                known: json["known"] as? Int ?? 0,
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
