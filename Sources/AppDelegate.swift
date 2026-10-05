import SwiftUI
import AVFoundation
import UserNotifications

// MARK: – AppDelegate (configure audio session for background playback)
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        configureAudioSession()
        // Notifications de live : tâche d'arrière-plan et réception des touches.
        LiveNotifier.register()
        UNUserNotificationCenter.current().delegate = self
        // Live Activity restée d'une session précédente (app tuée en lecture).
        PlayerActivity.endOthers()
        return true
    }

    // Notification touchée → on ouvre le direct de la chaîne.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let login = response.notification.request.content.userInfo["login"] as? String {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .openLiveChannel, object: nil, userInfo: ["login": login])
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

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .moviePlayback,
                options: [.allowAirPlay, .allowBluetoothA2DP]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("⚠️ AVAudioSession error: \(error)")
        }
    }
}
