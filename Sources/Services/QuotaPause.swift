import Foundation

// ═══════════════════════════════════════════════════════════════════════════
// Réserve du quota du jour du Worker (worker.js, dépôt du site)
// ═══════════════════════════════════════════════════════════════════════════
// Le Worker gratuit a 100 000 requêtes par jour, et Cloudflare compte même
// celles qu'il refuse. Passé 80 %, il le dit sur le comptage, les annonces et
// les sondages (en-tête X-TU-Quota: reserve, Retry-After jusqu'à minuit UTC) :
// ces envois automatiques attendent alors, pour laisser le reste du quota à
// la lecture et aux sauvegardes. Le relais des minutes des points
// (/api/spade) répond 429 avec le code « quota_reserve » : ChannelPointsService
// laisse ce Worker jusqu'à l'heure dite. Passé 95 %, la lecture part au
// secours d'elle-même (le Worker répond « 1027 », comme au quota atteint).
enum QuotaPause {
    private static let key = "quota_pause_until"

    /// Envois automatiques en pause ?
    static var active: Bool {
        UserDefaults.standard.double(forKey: key) > Date().timeIntervalSince1970
    }

    /// Lit l'avis de la réserve sur une réponse du Worker.
    static func note(_ response: URLResponse?) {
        guard let http = response as? HTTPURLResponse,
              http.value(forHTTPHeaderField: "X-TU-Quota") == "reserve" else { return }
        let until = Date().timeIntervalSince1970 + wait(http.value(forHTTPHeaderField: "Retry-After"))
        if until > UserDefaults.standard.double(forKey: key) {
            UserDefaults.standard.set(until, forKey: key)
        }
    }

    /// Secondes à attendre d'après un Retry-After : une heure s'il manque, un
    /// jour au plus.
    static func wait(_ retryAfter: String?) -> TimeInterval {
        guard let s = retryAfter.flatMap(Double.init), s > 0 else { return 3600 }
        return min(s, 86400)
    }
}
