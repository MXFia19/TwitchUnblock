import SwiftUI

@main
struct TwitchUnblockApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
