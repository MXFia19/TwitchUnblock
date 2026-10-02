import Foundation
import BackgroundTasks
import UserNotifications

// MARK: – Notifications « chaîne suivie en live »
//
// iOS réveille l'app de temps en temps en arrière-plan (BGAppRefreshTask, au
// mieux toutes les 15 min, souvent moins : c'est iOS qui décide). À chaque
// réveil, on relit les chaînes suivies en live et on notifie celles qui ne
// l'étaient pas au réveil précédent. Rien ne passe par un serveur.
enum LiveNotifier {
    static let taskId = "com.mxfia19.TwitchUnblock.liveRefresh"
    private static let knownKey = "notif_known_live"
    static let enabledKey = "notif_live_enabled"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// À appeler au lancement, avant la fin de didFinishLaunching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            handle(task)
        }
    }

    /// Programme le prochain réveil (sans effet si l'option est coupée).
    static func schedule() {
        guard isEnabled else { return }
        let req = BGAppRefreshTaskRequest(identifier: taskId)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    /// Active l'option : demande l'autorisation, mémorise l'état actuel (pour
    /// ne pas notifier tout ce qui est déjà en live), programme le réveil.
    static func enable() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        UserDefaults.standard.set(granted, forKey: enabledKey)
        guard granted else { return false }
        _ = await check(notify: false)
        schedule()
        return true
    }

    static func disable() {
        UserDefaults.standard.set(false, forKey: enabledKey)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskId)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()   // le suivant d'abord : un échec ne doit pas tout arrêter
        let work = Task {
            let ok = await check(notify: true)
            task.setTaskCompleted(success: ok)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// Relit les lives suivis ; notifie les nouveaux si `notify`.
    @discardableResult
    static func check(notify: Bool) async -> Bool {
        guard isEnabled,
              let token = Keychain.loadToken("twitch_token"),
              let userId = UserDefaults.standard.string(forKey: "twitch_user_id"), !userId.isEmpty,
              let streams = try? await getFollowedStreams(token: token, userId: userId) else { return false }
        let ud = UserDefaults.standard
        let known = Set(ud.stringArray(forKey: knownKey) ?? [])
        let now = Set(streams.map { $0.userLogin.lowercased() })
        if notify {
            let lang = Lang(rawValue: ud.string(forKey: "lang") ?? "en") ?? .en
            for s in streams where !known.contains(s.userLogin.lowercased()) {
                let content = UNMutableNotificationContent()
                content.title = translate("notif_live_title", lang).replacingOccurrences(of: "{u}", with: s.userName)
                content.body = s.title.isEmpty ? s.gameName : "\(s.title)\(s.gameName.isEmpty ? "" : " · \(s.gameName)")"
                content.sound = .default
                content.userInfo = ["login": s.userLogin.lowercased()]
                let req = UNNotificationRequest(identifier: "live-\(s.userLogin.lowercased())",
                                                content: content, trigger: nil)
                try? await UNUserNotificationCenter.current().add(req)
            }
        }
        ud.set(Array(now), forKey: knownKey)
        return true
    }
}

extension Notification.Name {
    /// Ouvrir le direct d'une chaîne (touche d'une notification).
    static let openLiveChannel = Notification.Name("OpenLiveChannel")
}
