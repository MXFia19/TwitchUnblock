import Foundation

// ═══════════════════════════════════════════════════════════════════════════
//  Fin des notifications de live par ntfy.
//
//  L'app publiait les lives des chaînes suivies dans un sujet ntfy secret
//  (app gratuite de l'App Store) : le Worker les envoyait par le relais du
//  VPS à ntfy.sh. Retiré : ça dépendait d'une app tierce et d'un quota
//  d'envois partagé (250 messages par jour et par adresse). Les
//  notifications instantanées passent maintenant par le site installé en
//  web app (Réglages → Notifications, kNotifInstallURL).
//
//  Pour qui l'avait activé : le Worker est prié d'oublier le sujet (sinon il
//  y publiait encore jusqu'à 60 jours), renvoyé à chaque retour dans l'app
//  tant qu'il ne l'a pas confirmé, puis les réglages ntfy sont effacés. Un
//  avis le dit une fois (TwitchUnblockApp).
// ═══════════════════════════════════════════════════════════════════════════
enum NtfyNotifier {
    private static let enabledKey = "ntfy_enabled"
    private static let topicKey = "ntfy_topic"
    private static let unsubPendingKey = "ntfy_unsub_pending"
    /// Le reste de l'ancien ntfy, effacé une fois le Worker prévenu.
    private static let oldKeys = ["ntfy_hash", "ntfy_synced", "ntfy_channels", "ntfy_account_follows", "ntfy_error"]

    /// Au lancement et à chaque retour dans l'app. Fil principal : deux appels
    /// simultanés (lancement, retour au premier plan) ne voient pas tous deux
    /// ntfy encore activé. true la première fois pour qui l'avait activé :
    /// l'avis « installe le site » est à montrer.
    @MainActor @discardableResult
    static func retire() async -> Bool {
        let ud = UserDefaults.standard
        let wasOn = ud.bool(forKey: enabledKey)
        if wasOn {
            ud.removeObject(forKey: enabledKey)
            ud.set(true, forKey: unsubPendingKey)
            logger.info("NTFY", "Notifications ntfy retirées", "sujet à oublier par le Worker")
        }
        guard ud.bool(forKey: unsubPendingKey) else {
            for key in oldKeys + [topicKey] { ud.removeObject(forKey: key) }
            return wasOn
        }
        guard let topic = ud.string(forKey: topicKey), !topic.isEmpty else {
            ud.removeObject(forKey: unsubPendingKey)
            return wasOn
        }
        guard let code = await unsubscribe(topic) else { return wasOn }
        // 200, ou un refus qui ne changera pas (route absente, sujet inconnu).
        if code == 200 || ((400 ..< 500).contains(code) && code != 429) {
            ud.removeObject(forKey: unsubPendingKey)
            for key in oldKeys + [topicKey] { ud.removeObject(forKey: key) }
            logger.info("NTFY", "Sujet ntfy oublié par le Worker", "HTTP \(code)")
        }
        return wasOn
    }

    /// Route du Worker principal (base D1, pas de secours) ; code HTTP, nil
    /// si le Worker n'a pas pu être joint.
    private static func unsubscribe(_ topic: String) async -> Int? {
        guard let url = URL(string: APIConfig.base + "/api/push/unsubscribe"),
              let payload = try? JSONSerialization.data(withJSONObject: ["ntfy": topic]) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }
        return http.statusCode
    }
}
