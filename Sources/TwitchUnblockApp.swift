import SwiftUI

@main
struct TwitchUnblockApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .task { await UsageService.shared.ping(enabled: store.shareUsage) }
                .onChange(of: scenePhase) { phase in
                    // Au retour en avant-plan : le service ne laisse passer
                    // qu'un ping par heure, on compte des journées actives.
                    guard phase == .active else { return }
                    Task { await UsageService.shared.ping(enabled: store.shareUsage) }
                }
        }
    }
}
