import SwiftUI

@main
struct TwitchUnblockApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase
    /// ntfy retiré, et il était activé ici : dit une fois, avec le site en
    /// web app à la place (NtfyNotifier).
    @State private var ntfyRetired = false

    var body: some Scene {
        WindowGroup {
            MainTabView()
                // Avis internes (réponses aux signalements, drops,
                // téléchargements), par-dessus le lecteur compris.
                .inAppNoticeHost()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                // Taille du texte d'iOS suivie jusqu'à « Accessibilité 2 » :
                // au-delà, cartes et lignes ne tiennent plus (voir TType).
                .dynamicTypeSize(...TType.maxSize)
                .task { await UsageService.shared.ping(enabled: store.shareUsage) }
                // À chaque lancement : nouvelle version disponible ?
                .task { await UpdateChecker.shared.checkIfDue(atLaunch: true) }
                // Annonce du développeur en cours ?
                .task { await AnnouncementService.shared.refresh(force: true) }
                // Sondage en cours ?
                .task { await PollService.shared.refresh(force: true) }
                // Réponses aux retours envoyés depuis l'app (pastille, bandeau),
                // puis relues toutes les minutes tant que l'app est ouverte.
                .task {
                    FeedbackStore.shared.startForegroundChecks()
                    await FeedbackStore.shared.refresh(force: true)
                }
                // Notifications ntfy retirées : le Worker oublie le sujet, et
                // qui les avait activées l'apprend une fois.
                .task { if await NtfyNotifier.retire() { ntfyRetired = true } }
                .alert(store.t("ntfy_retired_title"), isPresented: $ntfyRetired) {
                    Button(store.t("notif_pwa_open")) { UIApplication.shared.open(kNotifInstallURL) }
                    Button(store.t("close"), role: .cancel) {}
                } message: {
                    Text(store.t("ntfy_retired_body"))
                }
                // Lien twitchunblock://live/<chaîne> (twitchunblock-test://
                // pour TU Test) : ouvre le direct.
                .onOpenURL { url in
                    guard url.scheme == kAppURLScheme || url.scheme == "twitchunblock", url.host == "live",
                          let login = url.pathComponents.dropFirst().first, !login.isEmpty else { return }
                    NotificationCenter.default.post(name: .openLiveChannel, object: nil,
                                                    userInfo: ["login": login.lowercased()])
                }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .background:
                        // Dernier moment sûr pour sauvegarder : iOS peut
                        // fermer l'app ensuite sans prévenir.
                        store.flushToCloud(force: true)
                        // Réglages changés à l'instant : partent aussi.
                        store.flushSettingsSync()
                        LiveNotifier.schedule()
                        FeedbackStore.shared.stopForegroundChecks()
                        VodDownloads.shared.sceneInactive()
                    case .inactive:
                        // Téléchargements : ce qui manque passe à iOS, avant
                        // que l'app soit en arrière-plan (sinon iOS attend
                        // le Wi-Fi ou la charge pour s'y mettre).
                        VodDownloads.shared.sceneInactive()
                    case .active:
                        // Avis arrivés en arrière-plan sans permission de
                        // notifier : affichés maintenant, dans l'app.
                        InAppNotices.shared.showPending()
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
                        Task { await PollService.shared.refresh() }
                        Task { await FeedbackStore.shared.refresh() }
                        FeedbackStore.shared.startForegroundChecks()
                        // ntfy retiré : désabonnement pas encore confirmé
                        // par le Worker (hors ligne…), renvoyé.
                        Task { await NtfyNotifier.retire() }
                        // Téléchargements : l'app reprend la main sur iOS,
                        // redemande ce qui manque (app fermée en la
                        // balayant…) et reprend les chats inachevés.
                        VodDownloads.shared.sceneActive()
                    default:
                        break
                    }
                }
        }
    }
}
