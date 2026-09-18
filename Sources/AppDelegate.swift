import SwiftUI
import AVFoundation

// MARK: – AppDelegate (configure audio session for background playback)
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        configureAudioSession()
        return true
    }

    /// Fermeture de l'app → purge du cache emotes/badges (si l'option est active).
    /// NB : on ne purge PAS en passant en arriere-plan, sinon revenir d'un
    /// changement d'app (ou du PiP) rechargerait tout pour rien.
    func applicationWillTerminate(_ application: UIApplication) {
        ImageCache.shared.purgeIfNeeded()
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
