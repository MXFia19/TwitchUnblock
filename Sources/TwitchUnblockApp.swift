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
                // À chaque lancement : nouvelle version disponible ?
                .task { await UpdateChecker.shared.checkIfDue(atLaunch: true) }
                // Annonce du développeur en cours ?
                .task { await AnnouncementService.shared.refresh(force: true) }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .background:
                        // Dernier moment sûr pour sauvegarder : iOS peut
                        // fermer l'app ensuite sans prévenir.
                        store.flushToCloud(force: true)
                        LiveNotifier.schedule()
                    case .active:
                        // Le service ne laisse passer qu'un ping par heure :
                        // on compte des journées actives.
                        Task { await UsageService.shared.ping(enabled: store.shareUsage) }
                        // Ce qui a été regardé ailleurs entre-temps (site,
                        // autre appareil) — au plus une lecture par 10 min.
                        Task { await store.refreshFromCloudIfStale() }
                        // Nouvelle version sur la source ? (au plus toutes les 6 h)
                        Task { await UpdateChecker.shared.checkIfDue() }
                        // Lives vus dans l'app : pas de notification en retard
                        // au prochain réveil pour un live déjà découvert ici.
                        Task { await LiveNotifier.check(notify: false) }
                        Task { await AnnouncementService.shared.refresh() }
                    default:
                        break
                    }
                }
        }
    }
}
