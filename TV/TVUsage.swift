import Foundation

// ═══════════════════════════════════════════════════════════════════════════
//  Comptage d'utilisation de l'app Apple TV (page /stats), comme l'iPhone
//  (UsageService) : au plus un signal par heure au Worker — l'identifiant
//  tiré au hasard (ou le compte Twitch, connecté : compté une seule fois sur
//  l'iPhone, l'Apple TV et le site), la version, « tvos », la langue, et les
//  lectures depuis le précédent (source du direct, échecs). Jamais de chaîne
//  ni de titre. Coupé dans Compte : rien ne part, et le serveur efface tout.
// ═══════════════════════════════════════════════════════════════════════════
enum TVUsage {
    static let enabledKey = "tv_share_usage"
    private static let idKey = "usage_install_id"
    private static let lastKey = "usage_last_ping"
    private static let eventsKey = "usage_events"

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// Identifiant de cette installation : trousseau d'abord (il survit à une
    /// réinstallation), copié dans les réglages.
    private static var installId: String {
        let ud = UserDefaults.standard
        let id = Keychain.get(idKey) ?? ud.string(forKey: idKey) ?? UUID().uuidString
        ud.set(id, forKey: idKey)
        if Keychain.get(idKey) != id { Keychain.set(id, for: idKey) }
        return id
    }

    /// Jeton du build officiel (`TUPingKey` d'Info.plist, posé par la CI) : le
    /// Worker ne compte que les signaux qui le portent, pas ceux d'un fork.
    private static var buildPingKey: String? {
        let key = (Bundle.main.infoDictionary?["TUPingKey"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    private static var pendingEvents: [String: Int] {
        UserDefaults.standard.dictionary(forKey: eventsKey) as? [String: Int] ?? [:]
    }

    /// Une lecture de plus (« live_as », « vod_fail »…), envoyée au prochain signal.
    static func count(_ event: String) {
        guard enabled else { return }
        var all = pendingEvents
        all[event, default: 0] += 1
        UserDefaults.standard.set(all, forKey: eventsKey)
    }

    /// Source du direct en cours (TVPlayer) : jointe aux pauses pub vues.
    static var adSource: String? = nil

    /// Pause pub vue (une par pause) : comptée avec son heure UTC, la source
    /// du direct et son type (« pre », « mid » ou vide), pour /stats.
    static func countAdBreak(roll: String) {
        guard enabled else { return }
        count("live_ad_break")
        AdHours.add(source: adSource, roll: roll)
    }

    /// Au lancement et au retour dans l'app : un signal par heure au plus.
    static func ping(token: String?, lang: Lang) async {
        guard enabled else { return }
        let ud = UserDefaults.standard
        let last = ud.double(forKey: lastKey)
        if last > 0, Date().timeIntervalSince1970 - last < 3600 { return }
        guard await workerCountsTV(), var req = request() else { return }
        if let key = buildPingKey { req.setValue(key, forHTTPHeaderField: "X-TU-Key") }
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let events = pendingEvents
        var body: [String: Any] = [
            "id": installId,
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "platform": "tvos",
            "lang": lang.rawValue,
            "device": "tv",
        ]
        if !events.isEmpty { body["ev"] = events }
        let adHours = AdHours.pending
        if !adHours.isEmpty { body["adh"] = adHours }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
        ud.set(Date().timeIntervalSince1970, forKey: lastKey)
        // Partis : retirés (ceux arrivés pendant l'envoi restent).
        var left = pendingEvents
        for (key, n) in events {
            let rest = (left[key] ?? 0) - n
            left[key] = rest > 0 ? rest : nil
        }
        ud.set(left, forKey: eventsKey)
        if !adHours.isEmpty { AdHours.sent(adHours) }
    }

    /// Partage coupé : cette installation (et le compte connecté) effacés du serveur.
    static func forget(token: String?) async {
        let ud = UserDefaults.standard
        ud.removeObject(forKey: lastKey)
        ud.removeObject(forKey: eventsKey)
        AdHours.clear()
        guard var req = request() else { return }
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": installId, "forget": true])
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Un Worker d'avant l'Apple TV compterait ce signal comme l'iPhone (et
    /// pour toujours, pour un compte vu là) : rien ne part tant qu'il ne liste
    /// pas « tvos » (GET /api/ping). Vu une fois, retenu.
    private static let supportKey = "usage_tvos_ok"

    private static func workerCountsTV() async -> Bool {
        if UserDefaults.standard.bool(forKey: supportKey) { return true }
        guard let url = URL(string: "\(APIConfig.base)/api/ping"),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["platforms"] as? [String])?.contains("tvos") == true else { return false }
        UserDefaults.standard.set(true, forKey: supportKey)
        return true
    }

    private static func request() -> URLRequest? {
        guard let url = URL(string: "\(APIConfig.base)/api/ping") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }
}
