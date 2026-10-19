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
    /// Dernier réveil en arrière-plan (date, réussite) : affiché dans les
    /// réglages pour savoir si iOS réveille bien l'app.
    static let lastRunKey = "notif_last_bg_run"
    static let lastOkKey  = "notif_last_bg_ok"
    /// La dernière demande de réveil a été refusée par iOS (identifiant non
    /// autorisé, actualisation en arrière-plan coupée…).
    static let submitErrorKey = "notif_submit_error"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Catégorie des notifications de live et ses actions (AppDelegate).
    static let categoryId  = "LIVE_CHANNEL"
    static let watchAction = "LIVE_WATCH"
    static let muteAction  = "LIVE_MUTE"

    /// À appeler au lancement, avant la fin de didFinishLaunching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            handle(task)
        }
        registerCategory()
    }

    /// Actions « Regarder » et « Ne plus notifier cette chaîne », dans la
    /// langue de l'app : au lancement, puis avant chaque envoi (la langue a pu
    /// changer entre-temps).
    static func registerCategory(lang: Lang? = nil) {
        let lang = lang ?? Lang(rawValue: UserDefaults.standard.string(forKey: "lang") ?? "en") ?? .en
        let watch = UNNotificationAction(identifier: watchAction,
                                         title: translate("notif_action_watch", lang),
                                         options: [.foreground],
                                         icon: UNNotificationActionIcon(systemImageName: "play.fill"))
        let mute = UNNotificationAction(identifier: muteAction,
                                        title: translate("notif_action_mute", lang),
                                        options: [.destructive],
                                        icon: UNNotificationActionIcon(systemImageName: "bell.slash"))
        let category = UNNotificationCategory(identifier: categoryId, actions: [watch, mute],
                                              intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// « Ne plus notifier cette chaîne » (action d'une notification) : la
    /// chaîne passe dans les coupées de « Chaînes notifiées », et ntfy suit.
    static func mute(_ login: String) {
        let l = login.lowercased()
        guard !l.isEmpty else { return }
        NotifChannels.setNotify(l, false)
        logger.info("NOTIF", "Chaîne retirée des notifications", "@\(l)")
        let lang = Lang(rawValue: UserDefaults.standard.string(forKey: "lang") ?? "en") ?? .en
        Task { await NtfyNotifier.sync(lang: lang) }
    }

    /// Programme le prochain réveil : pour les lives suivis (option), ou pour
    /// les réponses aux retours envoyés (FeedbackStore).
    static func schedule() {
        // ntfy aussi : son sujet est renvoyé au Worker pendant ces réveils (il
        // l'oubliait après 60 jours sans retour dans l'app).
        guard isEnabled || NtfyNotifier.isEnabled
                || UserDefaults.standard.bool(forKey: FeedbackStore.hasReportsKey) else { return }
        let req = BGAppRefreshTaskRequest(identifier: taskId)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(req)
            UserDefaults.standard.removeObject(forKey: submitErrorKey)
        } catch {
            // Jusqu'ici avalé en silence : c'est ce qui cachait la panne.
            UserDefaults.standard.set(String(describing: error), forKey: submitErrorKey)
            logger.warn("NOTIF", "Réveil en arrière-plan refusé par iOS", String(describing: error))
        }
    }

    /// Notification immédiate, pour vérifier autorisations et affichage.
    static func sendTest(lang: Lang) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { return false }
        let content = UNMutableNotificationContent()
        content.title = translate("notif_test_title", lang)
        content.body = translate("notif_test_body", lang)
        content.sound = .default
        // 3 s : le temps de quitter l'app pour la voir arriver comme une vraie.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        do {
            try await center.add(UNNotificationRequest(identifier: "live-test", content: content, trigger: trigger))
            return true
        } catch { return false }
    }

    static var lastRun: Date? {
        let t = UserDefaults.standard.double(forKey: lastRunKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
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
            let ok = isEnabled ? await check(notify: true) : true
            // Réponses aux retours envoyés : notifiées par FeedbackStore.
            await FeedbackStore.shared.refresh(force: true)
            // ntfy : chaînes suivies renvoyées si elles ont changé (et au moins
            // une fois par jour), même sans ouvrir l'app.
            if NtfyNotifier.isEnabled {
                let lang = Lang(rawValue: UserDefaults.standard.string(forKey: "lang") ?? "en") ?? .en
                _ = await NtfyNotifier.sync(lang: lang)
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastRunKey)
            UserDefaults.standard.set(ok, forKey: lastOkKey)
            task.setTaskCompleted(success: ok)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// Relit les lives suivis ; notifie les nouveaux si `notify`.
    @discardableResult
    static func check(notify: Bool) async -> Bool {
        guard isEnabled else { return false }
        let ud = UserDefaults.standard
        // Suivis du compte Twitch (si connecté) + suivis sur cet appareil.
        var streams: [TwitchStream] = []
        var reached = false
        // Liste partielle (une page suivante n'a pas répondu) : un live qui
        // n'y est pas n'est pas fini pour autant. Le retirer des connus le
        // faisait notifier de nouveau au contrôle suivant, en rafale.
        var partial = false
        if let token = Keychain.loadToken("twitch_token"),
           let userId = ud.string(forKey: "twitch_user_id"), !userId.isEmpty {
            guard let followed = try? await getFollowedStreamsPaged(token: token, userId: userId) else { return false }
            streams = followed.streams
            partial = !followed.complete
            reached = true
        }
        let local = ud.stringArray(forKey: "local_follows") ?? []
        if !local.isEmpty {
            let known = Set(streams.map { $0.userLogin.lowercased() })
            guard let live = await getLiveStreamsGQL(logins: local) else { return false }
            streams += live.filter { !known.contains($0.userLogin.lowercased()) }
            reached = true
        }
        guard reached else { return false }
        let known = Set(ud.stringArray(forKey: knownKey) ?? [])
        let now = Set(streams.map { $0.userLogin.lowercased() })
        // ntfy actif : c'est lui qui prévient (sans doublon, et plus vite).
        let firstPass = ud.object(forKey: knownKey) == nil
        if notify && !firstPass && !(NtfyNotifier.isEnabled && !NtfyNotifier.isPending) {
            let lang = Lang(rawValue: ud.string(forKey: "lang") ?? "en") ?? .en
            // Chaînes coupées dans « Chaînes notifiées » : connues quand même,
            // pour ne pas notifier un live en cours le jour où on les rallume.
            let muted = NotifChannels.muted
            let fresh = streams.filter { !known.contains($0.userLogin.lowercased())
                                         && !muted.contains($0.userLogin.lowercased()) }
            if !fresh.isEmpty {
                registerCategory(lang: lang)
                // En parallèle : la vignette lente d'une chaîne ne retarde pas
                // les autres notifications.
                await withTaskGroup(of: Void.self) { group in
                    for s in fresh {
                        group.addTask { await LiveNotifier.post(s, lang: lang) }
                    }
                }
            }
        }
        ud.set(Array(partial ? known.union(now) : now), forKey: knownKey)
        return true
    }

    /// Une notification de live : vignette jointe si elle arrive à temps, un
    /// fil par chaîne, actions « Regarder » et « Ne plus notifier ».
    private static func post(_ s: TwitchStream, lang: Lang) async {
        let login = s.userLogin.lowercased()
        let content = UNMutableNotificationContent()
        content.title = translate("notif_live_title", lang).replacingOccurrences(of: "{u}", with: s.userName)
        content.body = s.title.isEmpty ? s.gameName : "\(s.title)\(s.gameName.isEmpty ? "" : " · \(s.gameName)")"
        content.sound = .default
        content.userInfo = ["login": login]
        content.threadIdentifier = "live-\(login)"
        content.categoryIdentifier = categoryId
        if let thumb = await thumbnail(of: s) { content.attachments = [thumb] }
        let req = UNNotificationRequest(identifier: "live-\(login)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }

    /// Vignette du live, téléchargée dans un fichier temporaire (iOS le range
    /// avec la notification). 6 s au plus : sans elle, la notification part
    /// quand même.
    private static func thumbnail(of s: TwitchStream) async -> UNNotificationAttachment? {
        let login = s.userLogin.lowercased()
        let template = s.thumbnailURL.isEmpty
            ? "https://static-cdn.jtvnw.net/previews-ttv/live_user_\(login)-{width}x{height}.jpg"
            : s.thumbnailURL
        let address = template.replacingOccurrences(of: "{width}", with: "640")
                              .replacingOccurrences(of: "{height}", with: "360")
        guard let url = URL(string: address) else { return nil }
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            logger.debug("NOTIF", "Vignette du live indisponible", "@\(login)")
            return nil
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-\(login)-\(UUID().uuidString).jpg")
        do {
            try data.write(to: file)
            return try UNNotificationAttachment(identifier: "thumbnail", url: file, options: nil)
        } catch {
            try? FileManager.default.removeItem(at: file)
            logger.debug("NOTIF", "Vignette non jointe", error.localizedDescription)
            return nil
        }
    }
}

extension Notification.Name {
    /// Ouvrir le direct d'une chaîne (touche d'une notification).
    static let openLiveChannel = Notification.Name("OpenLiveChannel")
    /// Ouvrir « Mes signalements » (notification d'une réponse).
    static let openMyFeedback = Notification.Name("OpenMyFeedback")
}
