import SwiftUI
import AVFoundation
import UserNotifications

// MARK: – AppDelegate (configure audio session for background playback)
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Journal gardé d'un lancement à l'autre : chaque session y est
        // marquée (date, version), et les erreurs du lecteur y arrivent.
        logger.sessionStart()
        PlaybackDiagnostics.start()
        // Wi-Fi ou données mobiles : qualité de départ et avance du direct.
        NetworkStatus.start()
        // Catégorie seulement : la session n'est activée qu'à l'ouverture d'un
        // lecteur (PlaybackAudio). Activée ici, elle coupait la musique des
        // autres apps dès le lancement, même sans rien lire.
        PlaybackAudio.configure()
        // Notifications de live : tâche d'arrière-plan et réception des touches.
        LiveNotifier.register()
        UNUserNotificationCenter.current().delegate = self
        // Live Activity restée d'une session précédente (app tuée en lecture).
        PlayerActivity.endOthers()
        // VODs en téléchargement : iOS rend à la session les fichiers arrivés.
        VodDownloader.shared.activate()
        return true
    }

    /// Orientations permises : voir OrientationLock.
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }

    /// Fichiers d'une VOD arrivés pendant que l'app était fermée : iOS la
    /// relance en arrière-plan le temps de les ranger.
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == VodDownloader.identifier else { completionHandler(); return }
        VodDownloader.shared.backgroundCompletion = completionHandler
        VodDownloader.shared.activate()
        Task { @MainActor in _ = VodDownloads.shared }
    }

    // Notification touchée (ou « Regarder ») → on ouvre le direct de la chaîne.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let login = response.notification.request.content.userInfo["login"] as? String {
            if response.actionIdentifier == LiveNotifier.muteAction {
                // « Ne plus notifier cette chaîne » : sans ouvrir l'app. iOS
                // peut la suspendre dès completionHandler : appelé une fois la
                // chaîne coupée et ntfy prévenu.
                Task { @MainActor in
                    await LiveNotifier.mute(login)
                    completionHandler()
                }
                return
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .openLiveChannel, object: nil, userInfo: ["login": login])
            }
        } else if response.notification.request.content.userInfo["feedback"] != nil {
            // Réponse à un retour : « Mes signalements ».
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .openMyFeedback, object: nil)
            }
        }
        completionHandler()
    }

    // App ouverte : la notification s'affiche quand même en bannière.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Fermeture de l'app → purge du cache emotes/badges (si l'option est active).
    /// NB : on ne purge PAS en passant en arriere-plan, sinon revenir d'un
    /// changement d'app (ou du PiP) rechargerait tout pour rien.
    func applicationWillTerminate(_ application: UIApplication) {
        ImageCache.shared.purgeIfNeeded()
        // L'app fermée, la lecture s'arrête : sa Live Activity aussi, sinon
        // iOS la laisserait affichée des heures.
        PlayerActivity.end()
        PlayerActivity.endOthers(wait: true)
    }
}

// MARK: – Orientation
/// iPhone : l'app reste en portrait, sauf le lecteur (ouvert en grand) et le
/// multi-live, où le paysage reste pratique. L'iPad et le Mac gardent toutes
/// les orientations. Fil principal seulement.
enum OrientationLock {
    private static var landscapeAllowed = false

    static var mask: UIInterfaceOrientationMask {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return .all }
        return landscapeAllowed ? .allButUpsideDown : .portrait
    }

    static func allowLandscape(_ on: Bool) {
        guard on != landscapeAllowed else { return }
        landscapeAllowed = on
        guard UIDevice.current.userInterfaceIdiom == .phone,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        // Lecteur fermé ou réduit en paysage : retour au portrait.
        if !on, scene.effectiveGeometry.interfaceOrientation.isLandscape {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { error in
                logger.warn("APP", "Retour au portrait refusé", error.localizedDescription)
            }
        }
    }
}
