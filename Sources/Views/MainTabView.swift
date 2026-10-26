import SwiftUI
import AVFoundation

struct MainTabView: View {
    @EnvironmentObject private var store: AppStore
    /// Onglet choisi pour le lancement (Réglages → Personnaliser), lu une fois.
    private static let launchTab = TabName(rawValue: UICustomization.saved()?.startTab ?? "home") ?? .home
    @State private var activeTab: TabName = MainTabView.launchTab
    @State private var headerSafeTop = HeaderView.windowSafeTop
    /// Onglets en colonne à gauche (fenêtre large, voir TabScaffold) : la
    /// mini-barre et la barre du multi-live se posent alors à sa droite, au
    /// bas de l'écran.
    @State private var sideTabs = SideTabRail.windowFits

    // ── Player state ─────────────────────────────────────────────────────
    @State private var playerMode: PlayerMode? = nil
    /// Playlist lancée avec « Tout lire » : la VOD suivante démarre à la fin.
    @State private var vodQueue: [VodData] = []
    @State private var vodQueueStreamer: String? = nil
    @State private var qualityLinks: QualityLinks? = nil
    /// Hauteur et cadence de chaque qualité (mêmes clés que `qualityLinks`),
    /// pour la qualité préférée ; vide quand la source ne les donne pas.
    @State private var qualityVariants: [String: VariantInfo] = [:]
    @State private var playerVisible = false
    @State private var loading = false
    @State private var errorMsg: String? = nil
    /// Relance prévue au retour du réseau, lecteur resté sur son erreur.
    @State private var networkRetry: Task<Void, Never>? = nil
    @State private var statusTitle = ""
    /// Source du direct en cours d'essai (écran de chargement) : elles sont
    /// essayées l'une après l'autre, l'attente peut durer.
    @State private var loadingSource: String? = nil
    /// Une image joue, d'après le lecteur (ni en pause, ni arrêtée ; le
    /// lecteur natif exclut aussi l'audio seul) : voir `keepScreenOn`.
    @State private var playerPlaying = false

    // ── Chat state ───────────────────────────────────────────────────────
    /// Le chat est affiché en permanence sous le lecteur (comme sur Twitch) ;
    /// « chat seul » masque la vidéo et lui laisse tout l'écran.
    @State private var chatOnly = false
    @State private var vodPlaybackTime: Double = 0   // pilote le chat des VODs
    // ── DVR (rembobiner un live) ─────────────────────────────────────────
    @State private var liveDvrVideoId: String? = nil    // VOD en cours du live regardé
    @State private var pendingDvrChannel: String? = nil // passe le relais à startPlayback
    @State private var dvrSourceChannel: String? = nil  // on regarde le DVR de cette chaîne
    @State private var currentChannelName: String? = nil
    @State private var currentChannelId: String? = nil   // ← branché sur data.userId

    // ── Live stats ────────────────────────────────────────────────────────
    @State private var liveViewerCount: Int = 0
    @State private var liveAvatar: String? = nil
    @State private var liveGame: String = ""
    /// Source qui sert le direct en cours (menu du lecteur).
    @State private var liveSourceUsed: String? = nil
    /// Qualités supérieures par le compte d'un non-abonné (voir HQLive) ;
    /// nil hors de ce cas, et dès qu'on reste sur la source sans pub.
    @State private var hqLive: HQLive? = nil
    /// Retour prévu au flux du compte après une pause pub.
    @State private var hqReturnTask: Task<Void, Never>? = nil
    /// Bascule annoncée dans le lecteur (4 s), et son effacement.
    @State private var hqNotice: String? = nil
    @State private var hqNoticeTask: Task<Void, Never>? = nil
    /// Image verticale du direct en cours (Dual Format, voir portraitLive),
    /// quand Twitch en a une ; jouée à la place de l'habituelle quand
    /// `verticalOn`, l'habituelle gardée pour le retour (`verticalBackup`).
    @State private var portraitMaster: MasterPlaylist? = nil
    @State private var verticalOn = false
    @State private var verticalBackup: (links: QualityLinks, variants: [String: VariantInfo], source: String?)? = nil
    /// Feuille « Télécharger » (VOD en cours).
    @State private var showDownloadSheet = false
    /// Multi-live : la sélection, et la mosaïque ouverte.
    @ObservedObject private var multi = MultiLive.shared
    /// Image dans l'image du lecteur : la mini-barre le dit (voir PlayerPiP).
    @ObservedObject private var pipState = PlayerPiP.shared
    @State private var showMultiLive = false
    @State private var liveStartedAt: Date? = nil
    @State private var liveUptimeText: String = ""
    @State private var refreshTimer: Timer? = nil
    @State private var uptimeTimer: Timer? = nil

    // ── Débogage / synchro ────────────────────────────────────────────────
    /// Latence mesurée du direct, arrondie à la seconde (affichée).
    @State private var liveLatency: Double = 0
    /// Glissé vers le bas du lecteur en cours : décalage suivi au doigt.
    /// Objet gardé en @State sans être observé ici : seul PlayerPullEffect
    /// se redessine pendant le geste (voir PlayerPull.swift).
    @State private var pull = PlayerPull()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Taille du texte d'iOS (plafonnée par TwitchUnblockApp) : relevée
    /// avant tout rendu (TType), les onglets sont refaits quand elle change.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // ── Minuteur de veille ────────────────────────────────────────────────
    @ObservedObject private var sleepTimer = SleepTimerService.shared
    @State private var showSleepSheet  = false
    @State private var showSettings    = false
    @State private var showPlayerMenu  = false
    /// « Créer un clip » (menu du lecteur) : création, puis lien du clip.
    @State private var showClipSheet   = false
    /// Formulaire de retour, et ce qui se lisait quand on l'a ouvert depuis
    /// le lecteur (joint au message).
    @State private var showFeedback    = false
    /// « Mes signalements », ouvert par la notification d'une réponse.
    @State private var showMyFeedback  = false
    @State private var feedbackContext: String? = nil
    /// Qualité retenue par le lecteur immersif (vide = meilleure disponible).
    @State private var immersiveQuality = ""
    /// « Connexion lente » annoncé dans le lecteur après une baisse de qualité.
    @State private var slowNetworkNotice: String? = nil
    /// Effacement de cet avis, 4 s après le dernier.
    @State private var slowNoticeTask: Task<Void, Never>? = nil
    /// « Connexion lente » déjà annoncé pendant cette lecture : l'avis du
    /// compte ne revient plus après lui (voir `accountNotice`).
    @State private var slowNoticeShown = false
    /// Largeur du chat au début d'un glissement : la translation du geste est
    /// relative à son point de départ, que la vue ne connaît plus une fois
    /// qu'elle a commencé à rétrécir.
    @State private var chatDragStart: Double? = nil
    /// Largeur en cours de glissement. Tant qu'elle vaut nil, c'est le réglage
    /// mémorisé qui s'applique ; pendant le geste, cet état local évite de
    /// toucher à l'AppStore à chaque image (voir `playerBody`).
    @State private var chatDragRatio: Double? = nil
    /// Fermeture du lecteur en cours : le contenu survit le temps du fondu.
    @State private var closingPlayer = false
    /// Bascule entre le direct et son enregistrement, sur la même chaîne.
    /// On garde l'image à l'écran et on n'échange les liens qu'une fois les
    /// nouveaux prêts : vider `qualityLinks` faisait repasser par l'écran noir
    /// « Chargement de la VOD », alors qu'on ne change ni de chaîne ni de
    /// contexte — juste de source.
    @State private var switchingSource = false
    /// Contenu des liens donnés au lecteur (« live:… », « vod:… »), et s'ils
    /// sont ceux d'un direct. Pendant une bascule, `playerMode` désigne déjà
    /// la nouvelle source alors que le lecteur lit encore l'ancienne : une
    /// qualité choisie à ce moment passait pour un changement de source, et
    /// l'arrivée des nouveaux liens pour un simple changement de qualité
    /// (l'enregistrement s'ouvrait à la position du direct, pas à l'instant
    /// visé). Posés en même temps que `qualityLinks`.
    @State private var linksContentID = ""
    @State private var linksAreLive = false
    /// Incrémenté à chaque ouverture et fermeture du lecteur : la réponse
    /// d'un chargement dépassé (chaîne A arrivée après la chaîne B, lecteur
    /// déjà fermé) est ignorée au lieu d'écraser l'état ou de relancer les
    /// minuteries du direct sans lecteur.
    @State private var loadGeneration = 0
    @ObservedObject private var updater = UpdateChecker.shared
    @State private var showDiscordPrompt = false
    /// Page d'une chaîne ouverte en feuille (sans passer par l'onglet Recherche).
    @State private var channelSheet: ChannelSheetItem? = nil
    /// Cette page a été ouverte depuis le lecteur affiché en grand (pseudo,
    /// titre, chat) : fermée sans rien lancer, elle rend le lecteur en grand.
    /// Il restait réduit en mini-lecteur.
    @State private var channelReturnsToPlayer = false
    /// Visite guidée du tout premier lancement (revue depuis les réglages).
    @AppStorage("onboarding_done") private var onboardingDone = false
    /// Clip en cours : VOD d'origine et position, pour en rejouer le chat.
    @State private var clipVodId: String? = nil
    @State private var clipOffset: Double = 0
    /// Vitesse du clip en cours : un clip part toujours à 1×, et celle qu'on
    /// y choisit n'est pas retenue pour les VODs.
    @State private var clipSpeed: Double = 1
    /// Vitesse imposée par le lecteur immersif (bord d'un enregistrement en
    /// cours rattrapé, récepteur AirPlay qui refuse) : pour cette lecture
    /// seulement. Écrite dans la préférence, elle remettait toutes les VODs
    /// suivantes à 1×. Un choix dans le menu l'efface.
    @State private var forcedVodSpeed: Double? = nil
    /// Chapitres de la VOD en cours (changements de jeu).
    @State private var vodChapters: [VodChapter] = []
    /// Passages de la VOD dont Twitch a coupé le son (et que l'app n'a pas pu
    /// rétablir), et nombre de segments rétablis (VodUnmuteLoader).
    @State private var vodMuted: [MutedRange] = []
    @State private var vodUnmuted = 0

    /// Infos affichées par-dessus l'image en mode immersif.
    private var overlayInfo: PlayerOverlayInfo {
        PlayerOverlayInfo(
            channel: currentChannelName ?? statusTitle,
            avatar:  liveAvatar,
            title:   isLivePlaying ? statusTitle : "",
            game:    liveGame,
            viewers: liveViewerCount,
            uptime:  liveUptimeText,
            latency: liveLatency > 0 ? liveLatency : nil
        )
    }

    /// Écran verrouillé, centre de contrôle et Live Activity : quoi, de qui, et
    /// une image — l'aperçu du direct, la miniature de la VOD, sinon l'avatar.
    /// Un direct y ajoute sa catégorie, ses spectateurs et son heure de début.
    private var nowPlayingMeta: NowPlayingMeta {
        switch playerMode {
        case .live(let channel)?:
            return NowPlayingMeta(
                title: statusTitle.isEmpty ? channel : statusTitle,
                artist: channel,
                artworkURL: "https://static-cdn.jtvnw.net/previews-ttv/live_user_\(channel.lowercased())-640x360.jpg",
                game: liveGame,
                viewers: liveViewerCount,
                startedAt: liveStartedAt,
                liveLabel: store.t("live_on"))
        case .vod(_, let title, let thumb, let streamer)?:
            return NowPlayingMeta(title: title ?? statusTitle,
                                  artist: streamer ?? currentChannelName ?? "",
                                  artworkURL: thumb ?? liveAvatar,
                                  liveLabel: store.t("live_on"))
        case .clip(_, let title)?:
            return NowPlayingMeta(title: title ?? statusTitle,
                                  artist: currentChannelName ?? "",
                                  artworkURL: liveAvatar,
                                  liveLabel: store.t("live_on"))
        case .recovered(let rec)?:
            return NowPlayingMeta(title: rec.title.isEmpty ? statusTitle : rec.title,
                                  artist: rec.streamer,
                                  artworkURL: liveAvatar,
                                  liveLabel: store.t("live_on"))
        case nil:
            return NowPlayingMeta()
        }
    }

    /// Chaîne de ce qu'on regarde (direct, ou streamer de la VOD) : pour ouvrir
    /// sa page en touchant le pseudo.
    private var playerChannelLogin: String? {
        if let ch = currentChannelName { return ch }
        if case .vod(_, _, _, let streamer)? = playerMode, let s = streamer, !s.isEmpty { return s.lowercased() }
        if case .recovered(let rec)? = playerMode, !rec.streamer.isEmpty { return rec.streamer.lowercased() }
        return nil
    }

    /// Ce qui se lit, joint à un signalement fait depuis le lecteur, avec ce
    /// qui suffit à classer un retour de lecture : qualité, source du direct,
    /// mode faible latence, lecteur immersif ou natif.
    /// Exemple : « live caedrel · chunked · as · ll=1 · imm=1 ».
    private var playerFeedbackContext: String? {
        guard playerMode != nil else { return nil }
        let parts: [String?] = [isLivePlaying ? "live" : "vod", playerChannelLogin,
                                isLivePlaying ? nil : currentVodId]
        var details: [String] = []
        // Le lecteur natif choisit sa qualité lui-même : on ne la connaît pas ici.
        if store.immersivePlayer, let links = qualityLinks {
            let q = currentQuality(links)
            if !q.isEmpty { details.append(q) }
        }
        if let source = menuLiveSource { details.append(source) }
        if isLivePlaying { details.append("ll=\(store.lowLatency ? 1 : 0)") }
        else if playbackSpeed != 1 { details.append(String(format: "×%g", playbackSpeed)) }
        details.append("imm=\(store.immersivePlayer ? 1 : 0)")
        return ([parts.compactMap { $0 }.joined(separator: " ")] + details).joined(separator: " · ")
    }

    /// Écran gardé allumé : seulement quand une vidéo joue (ou va jouer),
    /// lecteur affiché. Il l'était tant qu'un lecteur existait — en pause,
    /// réduit, en erreur, en audio seul : téléphone posé, jusqu'à vider la
    /// batterie. L'audio seul n'a rien à montrer : l'écran s'éteint comme
    /// d'habitude, le son continue écran verrouillé.
    private var keepScreenOn: Bool {
        guard playerMode != nil, playerVisible, !closingPlayer, !chatOnly,
              errorMsg == nil else { return false }
        if loading { return true }
        guard playerPlaying, let links = qualityLinks else { return false }
        // Le lecteur natif écarte déjà l'audio seul (VideoPlayerView).
        return !(store.immersivePlayer && isAudioQuality(currentQuality(links)))
    }

    /// Y a-t-il un chat à afficher sous le lecteur ?
    /// Paysage permis (iPhone) : lecteur ouvert en grand, ou multi-live.
    private var landscapeAllowed: Bool {
        (playerMode != nil && playerVisible && !closingPlayer) || showMultiLive
    }

    /// L'onglet affiché doit être dans la barre ; sinon, le premier qui y est.
    /// Pas pendant la visite guidée, qui passe par tous les onglets.
    private func keepVisibleTab() {
        guard onboardingDone else { return }
        let visible = TabName.visible(store)
        if !visible.contains(activeTab), let first = visible.first { activeTab = first }
    }

    private var chatTarget: String? {
        if let ch = currentChannelName { return ch }
        return currentVodId
    }

    /// « Streamer » et « Lien / ID » ont fusionné dans Recherche, et les
    /// Réglages sont passés derrière l'avatar de l'en-tête. Chaque onglet se
    /// masque ou se déplace dans Réglages → Personnaliser.
    enum TabName: String, CaseIterable {
        case home, discover, search, library

        var icon: String {
            switch self {
            case .home:     return "play.tv"
            case .discover: return "play.rectangle.on.rectangle"
            case .search:   return "magnifyingglass"
            case .library:  return "clock.arrow.circlepath"
            }
        }
        var iconFilled: String {
            switch self {
            case .home:     return "play.tv.fill"
            case .discover: return "play.rectangle.on.rectangle.fill"
            case .search:   return "magnifyingglass"
            case .library:  return "clock.arrow.circlepath"
            }
        }
        func label(_ store: AppStore) -> String {
            switch self {
            case .home:     return store.t("tab_home")
            case .discover: return store.t("tab_discover")
            case .search:   return store.t("tab_search")
            case .library:  return store.t("tab_library")
            }
        }
        /// Onglets que la visite guidée fait toucher.
        var tourTarget: TourTarget? {
            switch self {
            case .home, .discover: return nil
            case .search:  return .tabSearch
            case .library: return .tabLibrary
            }
        }

        /// Onglets de la barre, dans l'ordre choisi (Réglages → Personnaliser).
        /// `all` : les masqués aussi — la visite guidée fait toucher Recherche
        /// et Bibliothèque.
        static func visible(_ store: AppStore, all: Bool = false) -> [TabName] {
            let c = store.customization
            return (all ? c.tabs : c.visibleTabs).compactMap(TabName.init(rawValue:))
        }
    }

    var body: some View {
        // En premier : les polices de l'app (TType) en dépendent, celles de
        // ce rendu comprises (mini-barre, chat du lecteur).
        let typeSize = TType.adopt(dynamicTypeSize)
        ZStack(alignment: .bottom) {
            Color.tDark.ignoresSafeArea()

            // En-tête, écran de l'onglet, et barre d'onglets en bas ou en
            // colonne à gauche (fenêtre large) : voir TabScaffold.
            TabScaffold(activeTab: $activeTab,
                        sideTabs: $sideTabs,
                        safeTop: headerSafeTop,
                        header: AnyView(HeaderView(title: activeTab.label(store),
                                                   onOpenSettings: { showSettings = true },
                                                   onFeedback: { feedbackContext = nil; showFeedback = true },
                                                   safeTop: headerSafeTop)),
                        content: AnyView(tabContent))
            // Thème changé dans les réglages : les onglets sont reconstruits,
            // pour qu'aucune vue ne garde les anciennes couleurs. Le lecteur et
            // la feuille des réglages, hors de ce bloc, restent en place. De
            // même pour la taille du texte d'iOS, que les polices de l'app ne
            // suivent pas d'elles-mêmes (TType).
            .id("\(store.themeID)|\(typeSize)")
            // Onglet masqué pendant qu'il est affiché (Réglages →
            // Personnaliser), ou fin de la visite guidée qui les montrait
            // tous : le premier de la barre.
            .onChange(of: store.customization.visibleTabs) { _ in keepVisibleTab() }
            .onChange(of: onboardingDone) { _ in keepVisibleTab() }
            // Multi-live ouvert ou fermé : aperçus de Découvrir bloqués ou permis.
            .onChange(of: showMultiLive) { on in DiscoverGate.shared.blocked = on || playerMode != nil }
            // iPhone : portrait, sauf lecteur ouvert en grand ou multi-live.
            .onChange(of: landscapeAllowed) { OrientationLock.allowLandscape($0) }
            .onAppear { OrientationLock.allowLandscape(landscapeAllowed) }

            // ── Mini bar ──────────────────────────────────────────────
            // `!closingPlayer` : sans lui, la mini-barre apparaîtrait le temps du
            // fondu de fermeture, le lecteur étant encore en place mais masqué.
            // Aussi pendant un chargement réduit (ou son erreur) : de quoi y
            // revenir.
            if playerMode != nil && !playerVisible && !closingPlayer {
                miniBar.zIndex(99)
            }

            // ── Multi-live : directs choisis, prêts à être lancés ─────
            if !multi.entries.isEmpty && !playerVisible && !closingPlayer {
                multiBar.zIndex(98)
            }

            // ── Player overlay ────────────────────────────────────────
            if playerMode != nil {
                playerOverlay
                    // Glissé vers le bas : le lecteur suit le doigt.
                    .modifier(PlayerPullEffect(pull: pull))
                    .opacity(playerVisible ? 1 : 0)
                    .allowsHitTesting(playerVisible)
                    .zIndex(100)
                    .transition(.opacity)
            }
        }
        // Menu « ⋯ » du lecteur immersif.
        .sheet(isPresented: $showPlayerMenu) {
            PlayerMenuSheet(
                qualities: sortQualities(Array((qualityLinks ?? [:]).keys), variants: qualityVariants),
                selected: currentQuality(qualityLinks ?? [:]),
                canRewind: liveDvrVideoId != nil,
                isDvr: dvrSourceChannel != nil,
                variants: qualityVariants,
                onSelectQuality: { q in
                    // Toucher la qualité déjà cochée ne change pas la préférence.
                    if q != currentQuality(qualityLinks ?? [:]) {
                        store.rememberQualityChoice(q, among: Array((qualityLinks ?? [:]).keys), variants: qualityVariants)
                    }
                    immersiveQuality = q
                    showPlayerMenu = false
                },
                // Pas sur le direct lui-même ; son rembobinage (enregistrement)
                // l'a, de quoi rattraper le bord.
                speed: isLivePlaying ? nil : playbackSpeed,
                onSelectSpeed: { setPlaybackSpeed($0); showPlayerMenu = false },
                onRewind: { showPlayerMenu = false; rewindAction?() },
                onBackToLive: { showPlayerMenu = false; backToLiveAction?() },
                onSleepTimer: { showPlayerMenu = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                    showSleepSheet = true } },
                onSettings: { showPlayerMenu = false
                              DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                  showSettings = true } },
                onFeedback: { showPlayerMenu = false
                              feedbackContext = playerFeedbackContext
                              DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                  showFeedback = true } },
                liveSource: menuLiveSource,
                onSelectSource: { id in
                    showPlayerMenu = false
                    // La source qui sert déjà le direct : rien à relancer. Une
                    // autre le relance par elle, même celle en tête de l'ordre
                    // quand c'est une suivante qui a répondu (la réessayer ne
                    // faisait rien). Lecture par le compte : un choix de source
                    // est respecté — le compte est mis de côté pour cette
                    // chaîne jusqu'au prochain lancement.
                    // Qualités supérieures (compte, ou source sans pub le
                    // temps d'une pause) : toute source choisie, même celle en
                    // cours, quitte le compte et ses retours.
                    let fromAccount = liveSourceUsed == "account" || hqLive != nil
                    guard id != liveSourceUsed || hqLive != nil else { return }
                    if fromAccount, case .live(let ch)? = playerMode {
                        store.accountPlaybackSkipped.insert(ch.lowercased())
                        logger.info("LECTEUR", "Compte mis de côté pour \(ch)", "source choisie : \(id)")
                    }
                    if id != store.liveSourceOrder.first {
                        logger.settingChanged("Source du direct en tête", value: id)
                        store.preferLiveSource(id)
                    }
                    reloadCurrent()
                },
                onDownload: downloadAction,
                onMultiLive: multiLiveAction,
                multiLiveOn: menuMultiLiveOn,
                multiLiveFull: multi.isFull,
                shareURL: shareURL,
                shareDetail: shareDetail,
                onCreateClip: createClipAction
            )
            .presentationDetents([.medium])
            .inAppNoticeHost()
            .tTypeRoot()
        }
        // Clip du direct en cours (menu ⋯ du lecteur).
        .sheet(isPresented: $showClipSheet) {
            ClipSheet()
                .environmentObject(store)
                .presentationDetents([.medium, .large])
                .inAppNoticeHost()
                .tTypeRoot()
        }
        // Multi-live : jusqu'à quatre vidéos côte à côte, directs et VODs.
        .fullScreenCover(isPresented: $showMultiLive) {
            MultiLiveView(onWatch: { entry, at in
                showMultiLive = false
                if let id = entry.vodId {
                    // La VOD reprend où en était sa tuile (sinon à la progression
                    // enregistrée) ; playVod tient l'historique.
                    if let at { store.setVodProgress(id, time: at) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        playVod(id, entry.title, entry.thumb,
                                entry.login.isEmpty ? (entry.name.isEmpty ? nil : entry.name) : entry.login)
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { playLive(entry.login) }
                }
            })
            // Avis internes : une feuille cache le bandeau de la racine.
            .inAppNoticeHost()
            .environmentObject(store)
        }
        // Télécharger un passage de la VOD en cours (menu ⋯ du lecteur).
        .sheet(isPresented: $showDownloadSheet) {
            if let ctx = downloadContext {
                VodDownloadSheet(context: ctx)
                    .inAppNoticeHost()
                    .environmentObject(store)
                    .presentationDetents([.large])
                    .tTypeRoot()
            }
        }
        // Réglages : ouverts depuis l'avatar de l'en-tête. `.equatable()` :
        // cette vue se redessine chaque seconde pendant une lecture, les
        // Réglages n'ont pas à suivre (voir SettingsView: Equatable).
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .equatable()
                .inAppNoticeHost()
                .tTypeRoot()
        }
        // Signaler un bug ou proposer une idée (en-tête, menu du lecteur).
        .sheet(isPresented: $showFeedback) {
            FeedbackSheet(context: feedbackContext)
                .inAppNoticeHost()
                .environmentObject(store)
                .presentationDetents([.large])
                .tTypeRoot()
        }
        // Invitation au Discord : à chaque lancement à partir du 2ᵉ, tant
        // qu'on n'a pas choisi « Ne plus afficher » (ou rejoint), et jamais en
        // même temps que la fenêtre de mise à jour.
        .task {
            let ud = UserDefaults.standard
            let launches = ud.integer(forKey: "launch_count") + 1
            ud.set(launches, forKey: "launch_count")
            guard launches >= 2, onboardingDone, !ud.bool(forKey: "discord_never") else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !updater.showAlert else { return }
            showDiscordPrompt = true
        }
        // Fenêtres « mise à jour » et « Discord » dans le style de l'app.
        // Jamais pendant la visite guidée, qui passe avant tout le reste.
        .overlay {
            if onboardingDone, updater.showAlert, let up = updater.available {
                // Installation ratée (vieil IPA sous le numéro de la dernière
                // version) : ce qu'il faut faire, et l'IPA à réinstaller,
                // plutôt qu'une mise à jour qu'on croit déjà avoir.
                TPromptCard(
                    icon: up.mislabeled ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill",
                    title: store.t(up.mislabeled ? "update_stale_title" : "update_title"),
                    message: up.mislabeled ? UpdateChecker.staleInstallMessage(store)
                        : store.t(up.changes.isEmpty ? "update_msg_short" : "update_whats_new"),
                    // Même version (builds de test) : le numéro de build les distingue.
                    detail: UpdateChecker.installedVersion == up.version
                        ? "\(up.version) (\(UpdateChecker.installedBuild))  →  \(up.version) (\(up.build))"
                        : "\(UpdateChecker.installedVersion)  →  \(up.version)",
                    primary: store.t(up.mislabeled ? "update_stale_download" : "update_open"),
                    secondary: store.t("later"),
                    onPrimary: {
                        withAnimation(.spring(response: 0.3)) { updater.dismiss() }
                        if up.mislabeled { UpdateChecker.openDownload(up.downloadURL) }
                        else { UpdateChecker.openSource() }
                    },
                    onSecondary: { withAnimation(.spring(response: 0.3)) { updater.dismiss() } },
                    // Nouveautés de chaque build manquant, du plus récent au plus ancien.
                    sections: up.changes.map { c -> TPromptCard.PromptSection in
                        let twin = up.changes.contains { $0.version == c.version && $0.build != c.build }
                        return TPromptCard.PromptSection(title: twin ? "\(c.version) (build \(c.build))" : c.version,
                                                         items: c.items, key: "\(c.build)")
                    })
                .zIndex(10)
            } else if onboardingDone, showDiscordPrompt {
                TPromptCard(
                    icon: "bubble.left.and.bubble.right.fill",
                    title: store.t("discord_title"),
                    message: store.t("discord_msg"),
                    primary: store.t("discord_join"),
                    secondary: store.t("later"),
                    onPrimary: {
                        // Rejoint : inutile de le reproposer.
                        UserDefaults.standard.set(true, forKey: "discord_never")
                        withAnimation(.spring(response: 0.3)) { showDiscordPrompt = false }
                        if let url = URL(string: kDiscordURL) { UIApplication.shared.open(url) }
                    },
                    onSecondary: { withAnimation(.spring(response: 0.3)) { showDiscordPrompt = false } },
                    tertiary: store.t("dont_show_again"),
                    onTertiary: {
                        UserDefaults.standard.set(true, forKey: "discord_never")
                        withAnimation(.spring(response: 0.3)) { showDiscordPrompt = false }
                    })
                .zIndex(10)
            }
        }
        // Marge haute de l'en-tête suivie par la mise en page : elle change
        // avec la rotation (0 en paysage sur iPhone, l'encoche passe sur le
        // côté). Un 0 en portrait (lecture ratée) reprend la valeur d'UIKit.
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { updateHeaderSafeTop(geo.safeAreaInsets.top) }
                .onChange(of: geo.safeAreaInsets.top) { updateHeaderSafeTop($0) }
        })
        // Visite guidée (premier lancement, ou revue depuis les réglages) :
        // par-dessus tout, elle éclaire les vrais boutons de l'app, dont les
        // positions remontent par `TourAnchorKey`.
        .overlayPreferenceValue(TourAnchorKey.self) { anchors in
            Group {
                if !onboardingDone {
                    GeometryReader { proxy in
                        OnboardingTour(rects: anchors.mapValues { proxy[$0] },
                                       size: proxy.size,
                                       insets: proxy.safeAreaInsets,
                                       activeTab: $activeTab) {
                            withAnimation(.easeInOut(duration: 0.3)) { onboardingDone = true }
                        }
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
                }
            }
        }
        // Visite relancée pendant une lecture : le lecteur se réduit, sinon
        // il cacherait les boutons montrés.
        .onChange(of: onboardingDone) { done in
            if !done { withAnimation(.easeInOut(duration: 0.2)) { playerVisible = false } }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: updater.showAlert)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showDiscordPrompt)
        // Notification « en live » touchée : on ouvre le direct.
        // Page d'une chaîne demandée (pseudo dans le lecteur, accueil…) :
        // ouverte dans une feuille par-dessus l'onglet en cours, sans passer
        // par Recherche ; le lecteur se réduit en mini-barre le temps de la
        // page (portrait, clavier du chat fermé). Ouverte depuis le lecteur
        // en grand, sa fermeture le rend en grand (channelSheetDismissed).
        .onChange(of: store.pendingChannel) { login in
            guard let login else { return }
            store.pendingChannel = nil
            // Une page en remplace une autre : le retour prévu à l'ouverture
            // de la première tient.
            if channelSheet == nil {
                channelReturnsToPlayer = playerMode != nil && playerVisible && !closingPlayer
            }
            withAnimation(.easeInOut(duration: 0.2)) { playerVisible = false }
            channelSheet = ChannelSheetItem(login: login)
        }
        // Une vidéo lancée depuis la page s'ouvre elle-même en grand : pas
        // de retour au lecteur d'avant (closeChannelSheet).
        .sheet(item: $channelSheet, onDismiss: channelSheetDismissed) { item in
            SearchView(onPlayVod: { id, t, th, s in closeChannelSheet(); playVod(id, t, th, s) },
                       onPlayLive: { l in closeChannelSheet(); playLive(l) },
                       onPlayClip: { slug, t in closeChannelSheet(); playClip(slug, t) },
                       onPlayQueue: { list, s in closeChannelSheet(); playQueue(list, s) },
                       onRecovered: { rec in closeChannelSheet(); playRecovered(rec) },
                       initialChannel: item.login,
                       onClose: { channelSheet = nil })
                // Grilles de la page (VODs, clips) : colonnes d'après la
                // largeur de la feuille.
                .tMeasuresContentWidth()
                .inAppNoticeHost()
                .environmentObject(store)
                .presentationDragIndicator(.visible)
                .tTypeRoot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
            playNextInQueue()
        }
        // Playlist réécrite par VodUnmuteLoader : passages encore muets (pour
        // la barre de lecture) et nombre de segments rétablis.
        .onReceive(NotificationCenter.default.publisher(for: VodUnmuteLoader.resultNotification)) { note in
            guard let url = note.userInfo?["url"] as? String,
                  let links = qualityLinks,
                  links.values.contains(where: { VodUnmuteLoader.unwrap($0) == url }) else { return }
            if let remaining = note.userInfo?["remaining"] as? [MutedRange] { vodMuted = remaining }
            vodUnmuted = note.userInfo?["restored"] as? Int ?? 0
        }
        // Notification touchée (direct, réponse à un retour) : ce qui est
        // ouvert ici se ferme d'abord (voir afterClosingPresentations).
        .onReceive(NotificationCenter.default.publisher(for: .openLiveChannel)) { note in
            guard let login = note.userInfo?["login"] as? String, !login.isEmpty else { return }
            afterClosingPresentations { playLive(login) }
        }
        // Téléchargement supprimé pendant qu'on le regarde (mini-lecteur) :
        // le lecteur se ferme au lieu de rester figé sur des fichiers effacés.
        .onReceive(NotificationCenter.default.publisher(for: .vodDownloadDeleted)) { note in
            guard let id = note.object as? String,
                  case .recovered(let rec)? = playerMode, rec.streamID == "offline-\(id)" else { return }
            stopPlayer()
        }
        // Calages répétés dans le lecteur immersif : qualité trop haute pour le
        // débit (données mobiles, Wi-Fi faible) → Auto, ou un cran en dessous.
        .onReceive(NotificationCenter.default.publisher(for: .tuPlaybackStalling)) { note in
            guard note.object as? String == "immersive" else { return }
            lowerQualityAfterStalls()
        }
        // Réseau revenu après une coupure : un lecteur resté sur son erreur
        // (« Réessayer ») relit le flux seul, une fois, 2 s plus tard. Celui
        // dont la lecture s'est arrêtée en route se relance de lui-même
        // (ImmersivePlayer).
        .onReceive(NotificationCenter.default.publisher(for: .tuNetworkRestored)) { _ in
            guard playerMode != nil, errorMsg != nil, !loading, networkRetry == nil else { return }
            networkRetry = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                networkRetry = nil
                guard !Task.isCancelled, playerMode != nil, errorMsg != nil, !loading else { return }
                logger.info("LECTEUR", "Réseau revenu : relance de la lecture", nil)
                reloadCurrent()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openMyFeedback)) { _ in
            guard !showMyFeedback else { return }
            afterClosingPresentations { showMyFeedback = true }
        }
        .sheet(isPresented: $showMyFeedback) {
            NavigationStack { MyFeedbackList() }
                .inAppNoticeHost()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tTypeRoot()
        }
        // Réglage rapide du minuteur depuis le lecteur.
        .sheet(isPresented: $showSleepSheet) {
            SleepTimerSheet()
                .presentationDetents([.medium, .large])
                .inAppNoticeHost()
        }
        // Session web : vérifiée une fois au lancement. Sans ça on ne s'aperçoit
        // de son expiration que quand les points cessent de répondre.
        .task { await store.validateWebSession() }
        // Suivis du compte (chaînes, catégories) lus au lancement, quel que
        // soit l'onglet de départ : seul l'accueil les lisait, et Découvrir
        // proposait de masquer une chaîne suivie.
        .task { await store.loadAccountFollows() }
        // Session web changée (déconnexion, expiration, autre compte) pendant
        // un direct lu par le compte (abonné sans pub) : sa liste de lecture
        // est signée pour l'ancienne session, que Twitch continuerait de
        // compter (spectateur, drops) jusqu'à la fermeture. Le direct est
        // relu tout de suite, avec la nouvelle session ou le jeton anonyme,
        // sans bouger le lecteur (réduit, chat seul).
        .onChange(of: store.twitchWebToken) { _ in
            // Drops : la pulsation repart avec la nouvelle session.
            if case .live(let channel)? = playerMode, dvrSourceChannel == nil, !closingPlayer {
                startDropsHeartbeat(channel: channel)
            }
            // Qualités supérieures : les liens du compte, gardés pour le retour
            // pendant une pause pub, sont signés pour l'ancienne session.
            guard case .live(let channel)? = playerMode, dvrSourceChannel == nil,
                  liveSourceUsed == "account" || hqLive != nil, !closingPlayer else { return }
            logger.info("LECTEUR", "Session web changée : direct relu", channel)
            let visible = playerVisible, onlyChat = chatOnly
            playLive(channel, soft: true)
            playerVisible = visible
            chatOnly = onlyChat
        }
        // Progression des drops activée pendant un direct : elle démarre.
        .onChange(of: store.dropsProgress) { on in
            guard on, case .live(let channel)? = playerMode, dvrSourceChannel == nil,
                  !closingPlayer else { return }
            startDropsHeartbeat(channel: channel)
        }
        // Qualités supérieures : lecture reprise sur la source sans pub, dont
        // le retour au compte s'était arrêté avec la pause (scheduleHQReturn).
        .onChange(of: playerPlaying) { playing in
            guard playing, hqLive?.onAdFree == true, hqReturnTask == nil else { return }
            scheduleHQReturn(after: 2)
        }
        // Minuteur de veille écoulé → on coupe la lecture.
        .onChange(of: sleepTimer.fireCount) { _ in
            guard playerMode != nil else { return }
            logger.info("SLEEP", "Arrêt du lecteur par le minuteur de veille", nil)
            // On s'endort : la musique d'une autre app ne doit pas repartir.
            stopPlayer(wakeOthers: false)
        }
        .onChange(of: keepScreenOn) { ScreenAwake.set("player", $0) }
        // Lecteur réduit (ou fermé) après le bouton de rotation : sur iPhone,
        // le reste de l'app revient au portrait au lieu de rester couché. Le
        // clavier du chat se ferme aussi : il restait par-dessus l'app.
        // Rouvert en grand (mini-barre, notification…) pendant un PiP :
        // l'image revient dans le lecteur, qui restait noir sinon.
        .onChange(of: playerVisible) { visible in
            guard !visible else { PlayerPiP.shared.playerShown(); return }
            PlayerOrientation.restorePortraitIfForced()
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                            to: nil, from: nil, for: nil)
        }
        // Chat seul (empilé, sans image) après le bouton de rotation : retour
        // au portrait aussi. Le lecteur ne le fait plus en disparaissant (il
        // disparaît aussi à chaque relance).
        .onChange(of: chatOnly) { only in
            if only { PlayerOrientation.restorePortraitIfForced() }
            // Plus d'image (le lecteur part) : le chat n'a plus rien à suivre.
            if only { ChatSync.shared.reset() }
        }
        // Liens arrivés sans qualité choisie : celle de départ du lecteur
        // immersif est figée, comme le fait le lecteur natif. Recalculée à
        // chaque rendu, elle suivait la connexion (Wi-Fi ↔ données mobiles)
        // et rechargeait le flux à un moment quelconque, parfois plusieurs fois.
        .onChange(of: qualityLinks) { links in
            guard immersiveQuality.isEmpty, let links, !links.isEmpty else { return }
            immersiveQuality = currentQuality(links)
        }
    }

    /// Écran de l'onglet affiché (sous l'en-tête, voir TabScaffold).
    @ViewBuilder private var tabContent: some View {
        switch activeTab {
        // Les fermetures sont explicites : Swift n'applique pas les
        // valeurs par défaut (`soft:`) quand une méthode est passée
        // comme valeur, donc `playLive` vaudrait ici
        // `(String, Bool) -> Void` et ne collerait pas au callback.
        case .home:    HomeView(onPlayStream: { playLive($0) },
                                onPlayVod: { playVod($0, $1, $2, $3) })
        // Aperçus seulement sans lecteur ouvert (ni réduit, ni
        // multi-live) et sans feuille par-dessus.
        case .discover: DiscoverView(active: playerMode == nil && !presentationOpen,
                                     bottomInset: floatingBarsInset,
                                     onPlayLive: { playLive($0) },
                                     onPlayClip: { playClip($0, $1) })
        case .search:  SearchView(onPlayVod: { playVod($0, $1, $2, $3) },
                                  onPlayLive: { playLive($0) },
                                  onPlayClip: { playClip($0, $1) },
                                  onPlayQueue: { playQueue($0, $1) },
                                  onRecovered: { playRecovered($0) })
        case .library: LibraryView(onPlayVod: { playVod($0, $1, $2, $3) },
                                   onPlayOffline: { playRecovered($0) })
        }
    }

    private func updateHeaderSafeTop(_ top: CGFloat) {
        let value = top > 0 ? top : HeaderView.windowSafeTop
        if abs(value - headerSafeTop) > 0.5 { headerSafeTop = value }
    }

    /// Une des feuilles (ou la mosaïque) attachées à cet écran est ouverte.
    /// Découvrir n'y joue pas d'aperçu : il continuait sous « Signaler un
    /// problème » ou le minuteur, avec le son s'il avait été rallumé.
    private var presentationOpen: Bool {
        showSettings || showFeedback || showMyFeedback || showPlayerMenu || showClipSheet
            || showDownloadSheet || showSleepSheet || channelSheet != nil || showMultiLive
    }

    /// Hauteur que la mini-barre et la barre du multi-live, posées par-dessus
    /// le bas des onglets, cachent à Découvrir (voir DiscoverView.bottomInset).
    /// Onglets en colonne : les barres descendent au bas de l'écran, sans
    /// barre d'onglets dessous (voir miniBar).
    private var floatingBarsInset: CGFloat {
        guard !playerVisible, !closingPlayer else { return 0 }
        let bars = (playerMode != nil ? 1 : 0) + (multi.entries.isEmpty ? 0 : 1)
        guard bars > 0 else { return 0 }
        return CGFloat((sideTabs ? 0 : 20) + 65 * bars)
    }

    /// Feuilles et mosaïque attachées à cet écran : une notification touchée
    /// pendant que l'une d'elles est ouverte lançait le direct dessous (sous
    /// la mosaïque, caché, avec son son en plus des siens) ou rien du tout
    /// (SwiftUI refuse une seconde feuille, « Mes signalements » ne s'ouvrait
    /// pas). Tout se ferme, puis l'action part une fois la fermeture finie.
    private func afterClosingPresentations(_ action: @escaping () -> Void) {
        guard presentationOpen else { action(); return }
        showSettings = false
        showFeedback = false
        showMyFeedback = false
        showPlayerMenu = false
        showClipSheet = false
        showDownloadSheet = false
        showSleepSheet = false
        closeChannelSheet()
        showMultiLive = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { action() }
    }

    /// Page d'une chaîne fermée pour autre chose (vidéo lancée depuis elle,
    /// notification touchée) : le lecteur d'avant ne revient pas en grand.
    private func closeChannelSheet() {
        channelReturnsToPlayer = false
        channelSheet = nil
    }

    /// Page d'une chaîne fermée (balayée, « Fermer ») : ouverte depuis le
    /// lecteur en grand, celui-ci revient tel qu'il était, au lieu de rester
    /// en mini-lecteur. Rien si le lecteur a été fermé entre-temps.
    private func channelSheetDismissed() {
        // Remplacée par la page d'une autre chaîne : on attend la dernière.
        guard channelReturnsToPlayer, channelSheet == nil else { return }
        channelReturnsToPlayer = false
        guard playerMode != nil, !playerVisible, !closingPlayer else { return }
        pull.y = 0
        withAnimation(.easeInOut(duration: 0.2)) { playerVisible = true }
    }

    // MARK: – Lecteur
    @ViewBuilder
    private var playerOverlay: some View {
        // En paysage, la vidéo et le chat se partagent la largeur : empiler
        // verticalement ne laisserait qu'un timbre-poste à l'image.
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height

            ZStack(alignment: .top) {
                Color.tDark.ignoresSafeArea()
                    // Hauteur du lecteur : seuil du glissé et glissade finale.
                    .onAppear { pull.height = geo.size.height }
                    .onChange(of: geo.size.height) { pull.height = $0 }

                if loading {
                    // Les sources d'un direct sont essayées l'une après
                    // l'autre : on dit laquelle, et on peut réduire le lecteur
                    // ou le fermer sans attendre (un simple rond tournait,
                    // par-dessus tout, sans issue).
                    VStack(spacing: TSpace.md) {
                        ProgressView().tint(.tPrimary).scaleEffect(1.3)
                        Text(store.t(isLivePlaying ? "loading" : "loading_vod"))
                            .font(.tCardTitle).foregroundColor(.tMuted)
                        if let source = loadingSource {
                            Text(store.t("loading_source")
                                    .replacingOccurrences(of: "{s}", with: store.t("src_\(source)")))
                                .font(.tMeta).foregroundColor(.tMuted)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, TSpace.lg)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) { loadingBar }

                } else if let err = errorMsg {
                    // Réessayer : une source a pu revenir, le direct a pu
                    // commencer. « Retour » ferme le lecteur, comme avant.
                    VStack(spacing: TSpace.sm) {
                        TEmptyState(icon: "exclamationmark.triangle", title: err,
                                    actionTitle: store.t("retry"), action: { reloadCurrent() })
                        Button(store.t("back")) { stopPlayer() }
                            .font(.tLabel)
                            .foregroundColor(.tMuted)
                            .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                } else if let links = qualityLinks {
                    playerBody(links: links, size: geo.size, landscape: landscape)
                }
            }
            // Bascule direct ↔ enregistrement : une pastille discrète en haut,
            // pas un écran d'attente. L'image précédente continue de jouer
            // dessous jusqu'à ce que la nouvelle source soit prête.
            .overlay(alignment: .top) {
                if switchingSource {
                    HStack(spacing: TSpace.sm) {
                        ProgressView().tint(.white).scaleEffect(0.7)
                        Text(store.t("switching_source"))
                            .font(.tLabel).foregroundColor(.white)
                    }
                    .padding(.horizontal, TSpace.md)
                    .frame(minHeight: 34)
                    .background(Color.black.opacity(0.65))
                    .clipShape(Capsule())
                    .padding(.top, TSpace.lg)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: switchingSource)
            // Lecteur en grand en paysage (immersif ou natif, chat seul à
            // part) : l'indicateur d'accueil s'efface au bout de quelques
            // secondes et revient au moindre toucher, comme dans les apps
            // vidéo. Il restait affiché en permanence sur l'image (retour d'un
            // iPhone XR, iOS 18.7). Préférence lue par le contrôleur de la
            // fenêtre : posée ici, elle vaut pour toute l'app tant que le
            // lecteur est affiché ainsi.
            .persistentSystemOverlays(landscape && playerVisible && !chatOnly && !closingPlayer
                                      ? .hidden : .automatic)
        }
    }

    /// Une seule disposition pour les deux orientations.
    ///
    /// `AnyLayout` échange HStack et VStack **sans changer l'identité des vues** :
    /// avec deux branches `if`, tourner le téléphone détruisait le lecteur, donc
    /// son AVPlayer, et le direct se rechargeait à chaque rotation.
    ///
    /// Les tailles passent toutes par `frame(width:height:)` avec des optionnels
    /// (`nil` = libre) plutôt que par des modificateurs conditionnels, pour la
    /// même raison. En particulier on n'utilise plus `aspectRatio(nil)` en
    /// paysage : le ratio « idéal » y était calculé à partir des contrôles, d'où
    /// l'image réduite en vignette dès qu'on les affichait.
    @ViewBuilder
    private func playerBody(links: QualityLinks, size: CGSize, landscape: Bool) -> some View {
        // Le mode « chat seul » n'a pas de colonne vidéo : il reste empilé.
        let split  = landscape && !chatOnly
        let mode   = store.landscapeChat
        let layout = split ? AnyLayout(HStackLayout(spacing: 0))
                           : AnyLayout(VStackLayout(spacing: 0))
        // Portrait : hauteur 16:9 imposée, le chat prend le reste ; image
        // verticale d'un direct en « Dual Format » : 9:16, sans dépasser 62 %
        // de l'écran (le chat garde de la place).
        // Paysage : libre, la colonne donne toute sa hauteur à l'image.
        let videoHeight: CGFloat? = split ? nil
            : verticalOn ? min(size.width * 16 / 9, size.height * 0.62) : size.width * 9 / 16
        let videoMaxHeight: CGFloat? = split ? CGFloat.infinity : nil
        // Largeur réglable, mais jamais sous 220 pt : en deçà les messages se
        // hachent en mots isolés, quel que soit le réglage.
        //
        // Pendant un glissement la valeur vient de `chatDragRatio`, un simple
        // @State. Écrire dans le store à chaque image passait par un `didSet`
        // qui enregistre dans UserDefaults — une écriture disque synchrone
        // soixante fois par seconde — et invalidait tout ce qui observe
        // l'AppStore, dont chaque ligne de message du chat. D'où les à-coups.
        let ratio = chatDragRatio ?? store.chatWidthRatio
        let chatWidth: CGFloat? = split ? max(size.width * CGFloat(ratio), 220) : nil
        // Place prise dans la rangée : seule la disposition « colonne » en
        // réclame. Superposé et replié laissent toute la largeur à l'image.
        let chatColumn: CGFloat? = {
            guard split, mode != .column else { return chatWidth }
            return CGFloat(0)
        }()
        let chatVisible = !split || mode != .hidden
        let overlaying  = split && mode == .overlay
        // Le décor ne tient que dans le chat plein cadre ; la transparence ne
        // sert qu'au calque. Le reste (tailles) vient des réglages.
        let chatStyle = store.chatStyle(chrome: !split, translucent: overlaying)
        // Posé sur l'image, le chat couvre la droite de l'écran. Plutôt que de
        // se disputer les touchers avec les boutons du lecteur, on les écarte :
        // les barres du lecteur se replient de la largeur du chat et restent
        // donc entièrement visibles et cliquables, quelle que soit sa taille.
        let controlsInset: CGFloat = overlaying ? (chatWidth ?? 0) : 0

        layout {
            VStack(spacing: 0) {
                // En immersif, la barre est dessinée par-dessus l'image par le
                // lecteur lui-même : pas de bandeau séparé ici.
                if !store.immersivePlayer || chatOnly {
                    playerTopBar
                }
                if !chatOnly {
                    videoSurface(links: links, landscape: split,
                                 controlsInset: controlsInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(height: videoHeight)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: videoMaxHeight)

            // Le chat n'est jamais retiré de la hiérarchie : le sortir ferait
            // mourir ChatView, donc couperait la connexion IRC à chaque bascule.
            // Les trois `frame` ne font pas doublon. Le premier fixe la largeur
            // de mise en page des messages (à zéro, chacun se replierait sur une
            // colonne d'un caractère). Le second donne la hauteur. Le troisième
            // fixe la place prise dans la rangée : à zéro et aligné à droite, le
            // contenu déborde vers la gauche — c'est ce qui le pose sur l'image
            // en mode superposé, sans que la vidéo ne rétrécisse.
            //
            // Replié, `opacity` le masque et `allowsHitTesting` coupe les
            // touchers : sans ça on appuyait encore sur un chat invisible, un
            // cadrage nul ne bornant pas les zones tactiles.
            chatPane(style: chatStyle)
                .frame(width: chatWidth)
                .frame(maxHeight: .infinity)
                // Bord du chat : une petite poignée pour régler sa largeur,
                // sans trait au repos (le chat se fond dans l'image).
                .overlay(alignment: .leading) {
                    if split { chatResizeHandle(totalWidth: size.width) }
                }
                .frame(width: chatColumn, alignment: .trailing)
                .opacity(chatVisible ? 1 : 0)
                .allowsHitTesting(chatVisible)
        }
    }

    /// Poignée du bord vidéo / chat, qui se saisit pour régler la largeur.
    ///
    /// Au repos, pas de trait (violet sur l'image, il coupait le chat de la
    /// vidéo) : seule une petite poignée discrète. Le trait n'apparaît que
    /// pendant qu'on tire. Une bande transparente de 28 pt reçoit le geste,
    /// sous peine de viser un fil avec un pouce.
    @ViewBuilder
    private func chatResizeHandle(totalWidth: CGFloat) -> some View {
        let dragging = chatDragRatio != nil
        Rectangle()
            .fill(dragging ? Color.tPrimary : Color.clear)
            .frame(width: dragging ? 2 : 1)
            .overlay {
                // Sans repère, personne ne devine qu'on peut tirer.
                Capsule()
                    .fill(Color.white.opacity(dragging ? 0.95 : 0.22))
                    .frame(width: dragging ? 5 : 3, height: dragging ? 48 : 28)
            }
            .overlay {
                Color.clear
                    .frame(width: 28)
                    .contentShape(Rectangle())
                    .gesture(
                        // Repère global : la poignée suit le bord du chat ;
                        // mesuré dans son propre repère, le déplacement
                        // retombait vers 0 à chaque image (largeur qui oscille,
                        // ou poignée qui reste en place).
                        DragGesture(minimumDistance: 2, coordinateSpace: .global)
                            .onChanged { value in
                                let start = chatDragStart ?? store.chatWidthRatio
                                if chatDragStart == nil { chatDragStart = start }
                                // Tirer vers la gauche élargit le chat.
                                let delta = -value.translation.width / totalWidth
                                chatDragRatio = min(max(start + Double(delta), 0.20), 0.60)
                            }
                            .onEnded { _ in
                                // Une seule écriture dans le store, donc un seul
                                // enregistrement disque, à la fin du geste.
                                if let final = chatDragRatio { store.chatWidthRatio = final }
                                chatDragStart = nil
                                chatDragRatio = nil
                            }
                    )
            }
            .animation(.easeOut(duration: 0.15), value: dragging)
    }

    /// Le chat, quelle que soit la disposition.
    @ViewBuilder
    private func chatPane(style: ChatStyle) -> some View {
        // Bascule douce vers un direct (« Retour au direct » depuis le DVR) :
        // le lecteur reste affiché, le chat attend l'id de la chaîne, qui
        // arrive avec les liens. Créé sans lui, il ne le prenait jamais (il se
        // configure une fois) : ni emotes de la chaîne, ni badges, ni points,
        // ni épinglé, ni raid jusqu'à la réouverture.
        if let channel = currentChannelName, currentChannelId != nil || !switchingSource {
            ChatView(
                channelName: channel,
                channelId: currentChannelId,
                token: store.twitchToken,
                login: store.twitchLogin,
                syncsWithPlayer: true,
                chatOnly: $chatOnly,
                style: style,
                onJoinChannel: { target in   // raid → suit la chaîne raidée
                    // Lecteur réduit : il le reste (on naviguait ailleurs).
                    playLive(target, keepVisibility: true)
                }
            )
            .id(channel)   // changement de chaîne → chat reconstruit à neuf
            .frame(maxHeight: .infinity)

        } else if let vid = currentVodId {
            VodChatView(videoId: vid, playbackTime: vodPlaybackTime, style: style)
                .id(vid)
                .frame(maxHeight: .infinity)

        } else if let cv = clipVodId {
            // Clip : le chat de la VOD d'origine, à l'instant du clip.
            VodChatView(videoId: cv, playbackTime: clipOffset + vodPlaybackTime, style: style)
                .id("clip-\(cv)-\(Int(clipOffset))")
                .frame(maxHeight: .infinity)

        } else if let file = offlineChatFile {
            // VOD téléchargée : le chat gardé avec elle, rejoué sans connexion.
            VodChatView(videoId: file.path, playbackTime: vodPlaybackTime, style: style, offlineFile: file)
                .id(file.path)
                .frame(maxHeight: .infinity)

        } else {
            Spacer()
        }
    }

    /// Surface vidéo : lecteur natif (contrôles Apple) ou immersif (contrôles maison).
    @ViewBuilder
    private func videoSurface(links: QualityLinks, landscape: Bool,
                              controlsInset: CGFloat = 0) -> some View {
        if store.immersivePlayer {
            ImmersivePlayer(
                url: URL(string: links[currentQuality(links)] ?? "") ?? URL(string: "about:blank")!,
                isLive: linksAreLive,
                dvrEnabled: linksAreLive,
                savedTime: currentVodId.map { store.getVodProgress($0) } ?? 0,
                contentID: linksContentID,
                info: overlayInfo,
                onChannel: playerChannelLogin.map { l in { store.openChannelPage(l) } },
                sleepLabel: sleepTimer.isActive ? sleepTimer.label : nil,
                chatMode: store.landscapeChat,
                isLandscape: landscape,
                controlsInset: controlsInset,
                // Image verticale en paysage : jamais recadrée (il n'en
                // resterait qu'une bande).
                fillScreen: store.fillScreen && !verticalOn,
                canReturnToLive: dvrSourceChannel != nil,
                streamStartedAt: liveStartedAt,
                archiveAvailable: liveDvrVideoId != nil,
                chapters: vodChapters,
                mutedRanges: vodMuted,
                unmutedCount: vodUnmuted,
                nowPlaying: nowPlayingMeta,
                speed: playbackSpeed,
                // Toujours une vitesse imposée par le lecteur (voir forcedVodSpeed).
                onSpeedChange: { setForcedSpeed($0) },
                onSpeedRestore: { restoreChosenSpeed($0) },
                notice: slowNetworkNotice ?? hqNotice ?? accountNotice,
                onProgress: { time in
                    // Pendant une bascule, `playerMode` désigne déjà la
                    // nouvelle source alors que le lecteur en place joue encore
                    // l'ancienne. Sa position n'a aucun sens dans la nouvelle
                    // base de temps, et l'enregistrer écrasait précisément
                    // l'instant qu'on venait d'y viser — d'où un retour au
                    // début de l'enregistrement.
                    guard !switchingSource else { return }
                    vodPlaybackTime = time
                    if let id = currentVodId { store.setVodProgress(id, time: time) }
                },
                onLatency: { updateLatency($0) },
                onBehind: { updateBehind($0) },
                onPlaying: { playerPlaying = $0 },
                onPull: { pullPlayer($0) },
                onPullEnd: { endPull($0, predicted: $1) },
                onReduce: { leavePlayer() },
                onClose:  { stopPlayer() },
                onMenu:   { showPlayerMenu = true },
                onRefresh: { reloadCurrent() },
                onToggleChat: { withAnimation { store.landscapeChat = store.landscapeChat.next } },
                onToggleChatVisibility: { withAnimation { store.toggleLandscapeChatVisibility() } },
                onSleep: { showSleepSheet = true },
                onBackToLive: { backToLiveAction?() },
                onSeekToArchive: { offset in
                    // Le flux du direct ne sait pas remonter si loin : on ouvre
                    // l'enregistrement à cet instant. Passer par la progression
                    // enregistrée réutilise le chemin de reprise des VODs.
                    guard let ch = currentChannelName, let dvr = liveDvrVideoId else { return }
                    store.setVodProgress(dvr, time: offset)
                    pendingDvrChannel = ch
                    playVod(dvr, statusTitle, nil, ch, soft: true)
                },
                // Boutons de la barre, s'ils y sont mis (Réglages → Personnaliser).
                onMultiLive: multiLiveAction,
                multiLiveOn: menuMultiLiveOn,
                multiLiveFull: multi.isFull,
                onRewind: dvrSourceChannel == nil ? rewindAction : nil,
                onVertical: verticalAvailable ? { toggleVertical() } : nil,
                verticalOn: verticalOn,
                // Qualités supérieures sans abonnement : pauses pub et échec
                // du flux du compte (voir adBreakChanged).
                onAdBreak: { adBreakChanged($0) },
                onFailed: { hqStreamFailed() },
                onPiPStart: { pipStarted() },
                onPiPRestore: { pipRestore() }
            )
        } else {
            VideoPlayerView(
                qualityLinks: links,
                // Pas de VOD tant que le lecteur lit encore le direct (bascule) :
                // sa position partait comme reprise de l'enregistrement.
                vodId: linksAreLive ? nil : currentVodId,
                isLive: linksAreLive,
                contentID: linksContentID,
                variants: qualityVariants,
                compact: false,  // garde qualité / rembobiner ; le bouton Chat, lui,
                                 // n'a plus lieu d'être (le chat est toujours affiché)
                nowPlaying: nowPlayingMeta,
                speed: playbackSpeed,
                onSpeedChange: { setPlaybackSpeed($0) },
                // Imposée (bord d'un enregistrement, AirPlay) : pour cette
                // lecture seulement, comme dans le lecteur immersif.
                onSpeedForced: { setForcedSpeed($0) },
                onTime: { vodPlaybackTime = $0 },
                onLatency: { updateLatency($0) },
                onBehind: { updateBehind($0) },
                onPlaying: { playerPlaying = $0 },
                notice: slowNetworkNotice ?? hqNotice ?? accountNotice,
                onPull: { pullPlayer($0) },
                onPullEnd: { endPull($0, predicted: $1) },
                onChat: nil,
                onRewind: rewindAction,
                onBackToLive: backToLiveAction,
                // Qualités supérieures sans abonnement : la qualité du compte au
                // retour d'une pause pub, et les pauses elles-mêmes.
                wantedQuality: hqLive?.accountQuality,
                onAdBreak: { adBreakChanged($0) },
                onPiPStart: { pipStarted() },
                onPiPRestore: { pipRestore() },
                videoAspect: verticalOn ? 9 / 16 : 16 / 9
            )
        }
    }

    /// Le direct en cours a une image verticale (Dual Format) qu'on peut
    /// choisir : pas pendant son rembobinage.
    private var verticalAvailable: Bool {
        portraitMaster != nil && linksAreLive && dvrSourceChannel == nil
    }

    /// Bandeau au-dessus de la vidéo (mode natif) : qui regarde-t-on, et quoi.
    /// Ses boutons ne font rien pendant un glissé du lecteur et juste après
    /// (PlayerPull.guarded) : parti sur un bouton, le glissé l'emporte avec
    /// le doigt, encore dessus au doigt levé — la croix fermait le lecteur.
    @ViewBuilder
    private var playerTopBar: some View {
        HStack(spacing: TSpace.sm) {
            Button { PlayerPull.guarded { leavePlayer() } } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.tPrimary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            if isLivePlaying, let avatar = liveAvatar {
                AsyncImage(url: URL(string: avatar)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(Color.tSurface)
                }
                .frame(width: 28, height: 28)
                .clipShape(Circle())
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(currentChannelName ?? statusTitle)
                    .font(.tCardTitle).foregroundColor(.tText).lineLimit(1)
                    // Toucher le pseudo : page de la chaîne.
                    .onTapGesture {
                        PlayerPull.guarded { if let l = playerChannelLogin { store.openChannelPage(l) } }
                    }

                HStack(spacing: TSpace.sm) {
                    if isLivePlaying {
                        if !liveUptimeText.isEmpty {
                            TMeta(icon: "dot.radiowaves.left.and.right",
                                  text: liveUptimeText, tint: .tLive)
                        }
                        if liveViewerCount > 0 {
                            TMeta(icon: "eye.fill", text: formatViewers(liveViewerCount))
                        }
                        // Un appui ramène au bord du direct, sans recharger.
                        if store.showLatency, liveLatency > 0 {
                            Button {
                                PlayerPull.guarded {
                                    NotificationCenter.default.post(name: .tuGoLive, object: nil)
                                }
                            } label: {
                                TMeta(icon: "waveform.path.ecg",
                                      text: String(format: "%.0f s", liveLatency))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(store.t("back_to_live"))
                        }
                    } else {
                        Text(statusTitle).font(.tMeta).foregroundColor(.tMuted).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Direct en « Dual Format » : son image verticale, ou retour.
            if verticalAvailable {
                Button { PlayerPull.guarded { toggleVertical() } } label: {
                    Image(systemName: verticalOn ? "rectangle" : "rectangle.portrait")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(verticalOn ? .tPurple : .tMuted)
                        .frame(width: 32, height: 32)
                        .background(verticalOn ? Color.tPurple.opacity(0.18) : Color.tSurface)
                        .cornerRadius(TRadius.chip)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.t("vertical_format"))
            }

            // Minuteur de veille
            Button { PlayerPull.guarded { showSleepSheet = true } } label: {
                HStack(spacing: 3) {
                    Image(systemName: "moon.zzz.fill").font(.system(size: 11))
                    if sleepTimer.isActive {
                        Text(sleepTimer.label)
                            .font(.system(size: 11, weight: .bold).monospacedDigit())
                    }
                }
                .foregroundColor(sleepTimer.isActive ? .tPurple : .tMuted)
                .fixedSize()
                .padding(.horizontal, TSpace.sm)
                .frame(height: 32)
                .background(sleepTimer.isActive ? Color.tPurple.opacity(0.18) : Color.tSurface)
                .cornerRadius(TRadius.chip)
            }
            .buttonStyle(.plain)

            TIconButton(icon: "xmark", size: 32) { PlayerPull.guarded { stopPlayer() } }
        }
        .padding(.horizontal, TSpace.md)
        .padding(.top, TSpace.sm)
        .padding(.bottom, TSpace.sm)
        .background(Color.tCard)
        .overlay(Divider().background(Color.tBorder), alignment: .bottom)
        .contentShape(Rectangle())
        // Le tirer vers le bas réduit le lecteur (l'image du lecteur natif
        // aussi, voir VideoPlayerView). Geste interrompu : il reprend sa place.
        .modifier(PlayerPullGesture(
            onPull: { pullPlayer($0) },
            onPullEnd: { endPull($0, predicted: $1) }
        ))
    }

    /// Barre de l'écran de chargement : réduire (le chargement continue, la
    /// mini-barre y ramène) ou fermer.
    private var loadingBar: some View {
        HStack {
            Button { reducePlayer() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.tPrimary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.t("reduce"))
            Spacer()
            TIconButton(icon: "xmark", size: 32) { stopPlayer() }
                .accessibilityLabel(store.t("close"))
        }
        .padding(.horizontal, TSpace.md)
        .padding(.top, TSpace.sm)
    }

    /// Qualité baissée après des calages répétés : « Auto » (la qualité suit
    /// le débit) si le flux l'a, sinon le cran du dessous. La préférence
    /// enregistrée ne change pas : seul ce lecteur passe plus bas.
    private func lowerQualityAfterStalls() {
        guard let links = qualityLinks, !links.isEmpty else { return }
        let current = currentQuality(links)
        guard !isAutoQuality(current), !isAudioQuality(current) else { return }
        var next = links.keys.first(where: isAutoQuality)
        if next == nil {
            let keys = Array(links.keys)
            let height = { (k: String) in qualityHeight(k, among: keys, variants: qualityVariants) }
            let video = keys.filter { !isAudioQuality($0) && !isAutoQuality($0) }.sorted { height($0) > height($1) }
            if let i = video.firstIndex(of: current), i + 1 < video.count { next = video[i + 1] }
        }
        guard let next, next != current else { return }
        logger.warn("LECTEUR", "Calages répétés : qualité baissée", "\(current) → \(next)")
        immersiveQuality = next
        slowNetworkNotice = store.t("slow_network_quality")
        slowNoticeShown = true
        // Annulable : un second avis reste ses 4 s (l'effacement du premier,
        // par asyncAfter, l'emportait au bout d'une seconde).
        slowNoticeTask?.cancel()
        slowNoticeTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            slowNetworkNotice = nil
        }
    }

    /// Qualité en cours pour le lecteur immersif : celle choisie, sinon la
    /// qualité préférée (ou la plus proche en dessous). `variants` : celles de
    /// `links` quand ce ne sont pas les liens en cours (qualités supérieures).
    private func currentQuality(_ links: QualityLinks, variants: [String: VariantInfo]? = nil) -> String {
        if !immersiveQuality.isEmpty, links[immersiveQuality] != nil { return immersiveQuality }
        // En données mobiles : la qualité choisie pour elles (Auto par défaut).
        return launchQualityKey(Array(links.keys), pref: store.preferredQuality, cellularPref: store.cellularQuality,
                                cellular: NetworkStatus.shared.isCellular, variants: variants ?? qualityVariants)
    }

    /// Arrondi à la seconde : sinon la vue se recalculerait à chaque tick.
    private func updateLatency(_ value: Double?) {
        let rounded = (value ?? 0).rounded()
        if abs(rounded - liveLatency) >= 1 { liveLatency = rounded }
    }

    /// Retard de l'image, pour la synchro du chat (ChatSync) : le direct du
    /// lecteur principal seulement. Une VOD, l'enregistrement (DVR, même
    /// pendant la bascule) ou le chat seul n'ont pas d'image à suivre.
    private func updateBehind(_ value: Double?) {
        if isLivePlaying, !chatOnly { ChatSync.shared.update(value) } else { ChatSync.shared.reset() }
    }

    /// Réduit le lecteur en mini-barre (flèche, ou glissé vers le bas) : il
    /// file jusqu'en bas en s'effaçant, comme dans l'app Twitch. Avec
    /// « Réduire les animations », un simple fondu.
    private func reducePlayer() {
        guard playerVisible, !closingPlayer else { return }
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.15)) { playerVisible = false }
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 1)) {
                pull.y = pull.height
                playerVisible = false
            }
        }
        // Le décalage retombe une fois le lecteur masqué, pour qu'il revienne
        // à sa place à la prochaine ouverture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !playerVisible { pull.y = 0 }
        }
    }

    /// Doigt levé : assez loin (seuil selon la hauteur), ou lancé
    /// franchement, on quitte le lecteur ; sinon il revient à sa place.
    private func endPull(_ distance: CGFloat, predicted: CGFloat) {
        guard playerVisible, !closingPlayer else { return }
        let threshold = PlayerPull.threshold(for: pull.height)
        if distance >= threshold || (distance > 20 && predicted >= threshold * 1.8) {
            leavePlayer()
        } else {
            pullPlayer(0)
        }
    }

    // MARK: – Image dans l'image (PiP)
    /// Lecteur quitté (flèche, glissé vers le bas) : avec « PiP en quittant le
    /// lecteur », la vidéo passe en PiP et le lecteur se réduit à son départ
    /// (pipStarted) ; sinon, ou si le PiP ne démarre pas, mini-lecteur.
    private func leavePlayer() {
        guard playerVisible, !closingPlayer else { return }
        if pipOnLeaveAllowed, PlayerPiP.shared.startOnLeave(fallback: { reducePlayer() }) { return }
        reducePlayer()
    }

    /// « PiP en quittant le lecteur » : lecteur immersif (le natif n'a rien
    /// de public pour démarrer son PiP), une image à montrer — ni chargement,
    /// ni erreur, ni chat seul, ni audio seul. Le lecteur dit ensuite s'il
    /// joue et si AVKit le permet (PlayerPiP.startOnLeave).
    private var pipOnLeaveAllowed: Bool {
        guard store.pipOnLeave, store.immersivePlayer, !chatOnly, !loading,
              errorMsg == nil, let links = qualityLinks else { return false }
        return !isAudioQuality(currentQuality(links))
    }

    /// PiP démarré (bouton, app en arrière-plan, lecteur quitté) : le lecteur
    /// se réduit pour laisser naviguer dans l'app, comme dans les apps vidéo.
    /// Il restait en grand, noir (l'image partie dans la fenêtre), et il
    /// fallait le fermer à la main.
    private func pipStarted() {
        // Paysage du bouton de rotation : la réduction le perd (retour au
        // portrait), pipRestore le remet. Rien à remettre pour un lecteur
        // déjà réduit.
        PlayerOrientation.landscapeBeforePiP = playerVisible && !closingPlayer
            && PlayerOrientation.forcedLandscape
        guard playerVisible, !closingPlayer else { return }
        reducePlayer()
    }

    /// Bouton « agrandir » de la fenêtre PiP, ou PiP arrêté pour rouvrir le
    /// lecteur : il revient en grand sur la même lecture, où AVKit ramène
    /// l'image. Une feuille ouverte par-dessus (réglages, page d'une chaîne…)
    /// se ferme : le lecteur serait revenu dessous.
    private func pipRestore() {
        guard playerMode != nil, !closingPlayer else { return }
        if presentationOpen { afterClosingPresentations {} }
        let landscape = PlayerOrientation.landscapeBeforePiP
        PlayerOrientation.landscapeBeforePiP = false
        guard !playerVisible else { return }
        pull.y = 0
        withAnimation(.easeInOut(duration: 0.2)) { playerVisible = true }
        // Regardé en paysage forcé (rotation verrouillée) avant le PiP : il
        // revient en paysage, une fois l'image rentrée dans le lecteur (la
        // fenêtre s'y pose en ~0,3 s), et non en portrait.
        guard landscape else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard playerVisible, playerMode != nil, !closingPlayer else { return }
            OrientationLock.allowLandscape(true)
            PlayerOrientation.forceLandscape()
        }
    }

    /// Le lecteur suit le doigt ; 0 = relâché trop tôt, il revient en place.
    private func pullPlayer(_ y: CGFloat) {
        guard playerVisible, !closingPlayer else { return }
        if y <= 0 {
            guard pull.y != 0 else { return }
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.8)) { pull.y = 0 }
        } else {
            // Au doigt, sans animation : même si le lecteur revenait encore
            // en place, il suit aussitôt (borné à sa hauteur).
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { pull.y = min(y, pull.height) }
        }
    }

    /// VOD en cours : de quoi proposer d'en télécharger un passage (liens
    /// directs, sans l'adresse maison des passages coupés).
    private var downloadContext: VodDownloadContext? {
        guard let links = qualityLinks?.mapValues({ VodUnmuteLoader.unwrap($0) }), !links.isEmpty else { return nil }
        switch playerMode {
        case .vod(let id, let title, let thumb, let streamer)?:
            return VodDownloadContext(vodId: id, title: title ?? statusTitle, streamer: streamer ?? "",
                                      thumbnail: thumb ?? "", links: links, position: vodPlaybackTime,
                                      variants: qualityVariants)
        case .recovered(let rec)? where !rec.streamID.hasPrefix("offline-"):
            // VOD supprimée retrouvée : la garder avant qu'elle ne quitte le CDN.
            return VodDownloadContext(vodId: "r\(rec.streamID)", title: rec.title.isEmpty ? statusTitle : rec.title,
                                      streamer: rec.streamer, thumbnail: "", links: links, position: vodPlaybackTime)
        default:
            return nil
        }
    }

    /// Direct ou VOD en cours : l'ajouter au multi-live, ou l'en retirer.
    /// Pas le rembobinage d'un direct (DVR).
    private var multiLiveAction: (() -> Void)? {
        guard dvrSourceChannel == nil else { return nil }
        switch playerMode {
        case .live(let ch)?:
            return {
                showPlayerMenu = false
                if multi.toggle(ch, name: ch) {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }
        case .vod(let id, let title, let thumb, let streamer)?:
            return {
                showPlayerMenu = false
                // La tuile reprendra ici. `streamer` peut être un nom affiché :
                // la chaîne est complétée au démarrage de la tuile.
                store.setVodProgress(id, time: vodPlaybackTime)
                if multi.toggleVod(id: id, name: streamer ?? "", title: title, thumb: thumb) {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }
        default:
            return nil
        }
    }

    private var menuMultiLiveOn: Bool {
        switch playerMode {
        case .live(let ch)?:              return multi.contains(ch)
        case .vod(let id, _, _, _)?:      return multi.containsVod(id)
        default:                          return false
        }
    }

    private var downloadAction: (() -> Void)? {
        guard downloadContext != nil else { return nil }
        return {
            showPlayerMenu = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showDownloadSheet = true }
        }
    }

    /// Position de la VOD en cours, en secondes entières (0 si illisible).
    private var vodShareSeconds: Int {
        vodPlaybackTime.isFinite ? max(0, Int(vodPlaybackTime)) : 0
    }

    /// Lien partagé depuis le menu du lecteur : la VOD (ou le rembobinage
    /// d'un direct) à la position en cours, la chaîne d'un direct, le clip.
    /// Rien pour une VOD retrouvée ou téléchargée : pas de page Twitch.
    private var shareURL: URL? {
        switch playerMode {
        case .live(let channel)?:
            return URL(string: "https://www.twitch.tv/\(channel.lowercased())")
        case .vod(let id, _, _, _)?:
            let t = vodShareSeconds
            return URL(string: "https://www.twitch.tv/videos/\(id)?t=\(t / 3600)h\((t % 3600) / 60)m\(t % 60)s")
        case .clip(let slug, _)?:
            return URL(string: "https://clips.twitch.tv/\(slug)")
        default:
            return nil
        }
    }

    /// Position partagée d'une VOD, affichée à côté de « Partager ».
    private var shareDetail: String? {
        guard case .vod? = playerMode else { return nil }
        let t = vodShareSeconds
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// Direct en cours (pas son rembobinage) : en créer un clip, à l'image
    /// affichée — maintenant moins la latence mesurée du direct (inconnue :
    /// 5 s, celle d'un direct ordinaire).
    private var createClipAction: (() -> Void)? {
        guard case .live(let channel)? = playerMode, qualityLinks != nil, !loading,
              errorMsg == nil else { return nil }
        return {
            showPlayerMenu = false
            let moment = Date().addingTimeInterval(-(liveLatency > 0 ? liveLatency : 5))
            ClipCreator.shared.start(login: channel, moment: moment, store: store)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                showClipSheet = true
            }
        }
    }

    /// Direct servi par le compte (abonné sans pub) : annoncé au lancement,
    /// une fois. Revenu après « Connexion lente » (4 s plus tard), il était
    /// réannoncé à chaque baisse de qualité. Qualités supérieures sans
    /// abonnement : pas « sans pub », et plus après une première bascule
    /// (chacune a son avis, hqNotice).
    private var accountNotice: String? {
        guard !slowNoticeShown else { return nil }
        switch menuLiveSource {
        case "account"?: return store.t("src_account_toast")
        case "account_hq"? where (hqLive?.switches ?? 0) == 0: return store.t("src_account_hq_toast")
        default: return nil
        }
    }

    /// Source du direct pour le menu du lecteur : seulement pendant un direct
    /// (pas pendant son rembobinage, qui lit la VOD en cours). Le compte d'un
    /// non-abonné en qualité supérieure : « account_hq » (pas sans pub).
    private var menuLiveSource: String? {
        guard case .live? = playerMode, dvrSourceChannel == nil else { return nil }
        if liveSourceUsed == "account", hqLive != nil { return "account_hq" }
        return liveSourceUsed
    }

    /// Recharge le flux courant (bouton ⟳ du lecteur, « Réessayer »).
    private func reloadCurrent() {
        guard let mode = playerMode else { return }
        logger.info("LECTEUR", "Rechargement du flux demandé", nil)
        // Rembobinage d'un direct : il garde son « Retour au direct ».
        pendingDvrChannel = dvrSourceChannel
        startPlayback(mode)
    }

    // MARK: – Actions du lecteur (nil ⇒ bouton masqué)
    /// Rembobiner un live : lit le VOD en cours d'enregistrement.
    /// Bascule douce : même chaîne, seule la source change.
    private var rewindAction: (() -> Void)? {
        guard let ch = currentChannelName, let dvr = liveDvrVideoId else { return nil }
        return {
            pendingDvrChannel = ch
            playVod(dvr, statusTitle, nil, ch, soft: true)
        }
    }

    private var backToLiveAction: (() -> Void)? {
        guard let ch = dvrSourceChannel else { return nil }
        return { playLive(ch, soft: true) }
    }

    /// VOD téléchargée en lecture : le chat gardé avec elle, s'il y en a un.
    private var offlineChatFile: URL? {
        guard case .recovered(let rec)? = playerMode, rec.streamID.hasPrefix("offline-") else { return nil }
        let file = VodDownloads.folder(String(rec.streamID.dropFirst("offline-".count)))
            .appendingPathComponent(VodChatArchive.fileName)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Ce qui se lit, quelle que soit la qualité : le lecteur immersif y
    /// distingue un changement de qualité (la lecture reste où elle en est)
    /// d'un changement de source (direct ↔ enregistrement).
    private var playerContentID: String {
        switch playerMode {
        case .live(let channel)?:     return "live:" + channel.lowercased()
        case .vod(let id, _, _, _)?:  return "vod:" + id
        case .clip(let slug, _)?:     return "clip:" + slug
        case .recovered(let rec)?:    return "rec:" + rec.streamID
        case nil:                     return ""
        }
    }

    /// Identifiant de la VOD en cours de lecture (nil en live).
    private var currentVodId: String? {
        if case .vod(let id, _, _, _) = playerMode { return id }
        return nil
    }

    // MARK: – Nature de la lecture en cours
    private var isLivePlaying: Bool {
        guard let mode = playerMode else { return false }
        if case .live = mode { return true }
        return false
    }

    private var isClipPlaying: Bool {
        if case .clip? = playerMode { return true }
        return false
    }

    /// Vitesse de ce qui se lit hors direct : celle des VODs (retenue d'une
    /// VOD à l'autre, sauf vitesse imposée pour la lecture en cours), ou
    /// celle du clip en cours.
    private var playbackSpeed: Double { isClipPlaying ? clipSpeed : (forcedVodSpeed ?? store.vodSpeed) }

    private func setPlaybackSpeed(_ v: Double) {
        let speed = VodSpeed.nearest(v)
        if isClipPlaying {
            clipSpeed = speed
        } else if VodSpeed.isExperimental(speed) {
            // Au-delà de 2× (expérimental) : pour cette lecture seulement. La
            // préférence, partagée avec le site, reste dans ses crans.
            forcedVodSpeed = speed
        } else {
            forcedVodSpeed = nil
            if speed != store.vodSpeed {
                store.vodSpeed = speed
                logger.settingChanged("Vitesse des VODs", value: String(format: "×%g", speed))
            }
        }
    }

    /// Vitesse imposée par le lecteur : retenue pour cette lecture seulement
    /// (voir `forcedVodSpeed`) ; celle d'un clip, comme un choix. Gardée même
    /// égale à la préférence : restoreChosenSpeed y lit qu'elle est imposée.
    private func setForcedSpeed(_ v: Double) {
        let speed = VodSpeed.nearest(v)
        if isClipPlaying {
            clipSpeed = speed
        } else {
            forcedVodSpeed = speed
        }
    }

    /// Lecteur immersif revenu loin du bord d'un enregistrement en cours
    /// (retour en arrière) : la vitesse d'avant le retour à 1× revient — la
    /// préférence, ou une vitesse expérimentale choisie pour cette lecture.
    /// Seulement si celle de la lecture est encore imposée : un choix fait
    /// entre-temps dans le menu ⋯ l'emporte.
    private func restoreChosenSpeed(_ held: Double) {
        guard !isClipPlaying, forcedVodSpeed != nil else { return }
        forcedVodSpeed = VodSpeed.isExperimental(held) ? VodSpeed.nearest(held) : nil
    }

    // MARK: – Mini-barre (lecteur réduit)
    @ViewBuilder
    private var miniBar: some View {
        HStack(spacing: TSpace.md) {
            // Chargement réduit : il tourne encore ; en échec, on le dit.
            if loading {
                ProgressView().tint(.tPrimary).scaleEffect(0.7)
                    .frame(width: 16, height: 16)
            } else if errorMsg != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.tWarning)
            } else {
                // En PiP, l'image est dans la fenêtre : toucher la barre l'y reprend.
                Image(systemName: pipState.active ? "pip"
                      : isLivePlaying ? "dot.radiowaves.left.and.right" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(isLivePlaying ? .tLive : .tPrimary)
            }

            Text(statusTitle)
                .font(.tCardTitle)
                .foregroundColor(.tText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            TIconButton(icon: "xmark", size: 30) { stopPlayer() }
        }
        .padding(.horizontal, TSpace.md)
        .padding(.vertical, TSpace.sm)
        .tGlass(in: RoundedRectangle(cornerRadius: TRadius.card, style: .continuous),
                fallback: .tCard)
        .overlay(RoundedRectangle(cornerRadius: TRadius.card, style: .continuous)
            .stroke(Color.tPrimary.opacity(store.liquidGlass ? 0.25 : 0.4), lineWidth: 1))
        // La zone tactile est fixée AVANT les marges : sinon le rectangle
        // tactile englobait les 92 pt de marge basse, qui recouvrent la barre
        // d'onglets — appuyer sur « Recherche » ou « VODs » rouvrait le lecteur
        // en plein écran au lieu de changer d'onglet.
        .contentShape(Rectangle())
        .onTapGesture {
            pull.y = 0
            withAnimation { playerVisible = true }
        }
        // Onglets en colonne à gauche : la barre se pose à sa droite, au bas
        // de l'écran (plus de barre d'onglets dessous).
        .padding(.leading, sideTabs ? SideTabRail.width : 0)
        .padding(.horizontal, TSpace.md)
        .padding(.bottom, sideTabs ? Self.sideBarsBottom : 92)
    }

    /// Bas de la mini-barre quand les onglets sont en colonne : juste
    /// au-dessus de l'indicateur d'accueil.
    private static let sideBarsBottom: CGFloat = TSpace.md

    /// Multi-live en préparation : les vidéos choisies, et « Regarder ».
    /// Au-dessus du mini-lecteur quand il est là.
    private var multiBar: some View {
        let miniShown = playerMode != nil
        return HStack(spacing: TSpace.sm) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.tPurple)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(store.t("multi_title")) · \(multi.entries.count)/\(MultiLive.max)")
                    .font(.tCardTitle).foregroundColor(.tText)
                Text(multi.entries.map(\.label).joined(separator: ", "))
                    .font(.tMeta).foregroundColor(.tMuted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: openMultiLive) {
                Label(store.t("multi_watch"), systemImage: "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(Capsule().fill(Color.tPrimary))
            }
            .buttonStyle(.plain)
            TIconButton(icon: "xmark", size: 30) { multi.clear() }
        }
        .padding(.horizontal, TSpace.md)
        .padding(.vertical, TSpace.sm)
        .tGlass(in: RoundedRectangle(cornerRadius: TRadius.card, style: .continuous),
                fallback: .tCard)
        .overlay(RoundedRectangle(cornerRadius: TRadius.card, style: .continuous)
            .stroke(Color.tPurple.opacity(0.35), lineWidth: 1))
        .contentShape(Rectangle())
        .padding(.leading, sideTabs ? SideTabRail.width : 0)
        .padding(.horizontal, TSpace.md)
        .padding(.bottom, (sideTabs ? Self.sideBarsBottom : 92) + (miniShown ? 60 : 0))
    }

    /// Un seul son à la fois : le lecteur se ferme.
    private func openMultiLive() {
        if playerMode != nil { stopPlayer() }
        DiscoverGate.shared.blocked = true
        showMultiLive = true
    }

    // MARK: – Playback
    /// `keepVisibility` : enchaînement automatique (VOD suivante de « Tout
    /// lire », raid suivi) — un lecteur réduit le reste, au lieu de surgir en
    /// plein écran pendant qu'on navigue.
    private func playVod(_ id: String, _ title: String? = nil,
                         _ thumb: String? = nil, _ streamer: String? = nil,
                         soft: Bool = false, keepVisibility: Bool = false) {
        // Une VOD hors de la playlist en cours met fin à l'enchaînement.
        if !vodQueue.contains(where: { $0.id == id }) { vodQueue = [] }
        // Historique des VODs vues : centralisé ici pour couvrir TOUS les points
        // d'entrée (Découverte, Streamer, Lien/ID, rembobinage…). Avant, seul
        // l'onglet Lien/ID enregistrait, donc l'onglet VODs restait vide.
        store.saveToHistory(HistoryItem(
            term: id, type: .vod,
            display: title ?? "VOD \(id)",
            thumb: thumb, streamer: streamer,
            addedAt: Date().timeIntervalSince1970 * 1000
        ))
        startPlayback(.vod(id: id, title: title, thumb: thumb, streamer: streamer),
                      soft: soft, keepVisibility: keepVisibility)
    }
    private func playQueue(_ list: [VodData], _ streamer: String?) {
        guard let first = list.first else { return }
        vodQueue = list
        vodQueueStreamer = streamer
        playVod(first.id, first.title, first.previewThumbnailURL, streamer)
    }
    /// Fin d'une vidéo : la suivante de la playlist, s'il y en a une. Pas
    /// pendant la fermeture du lecteur (fin arrivée pendant le fondu).
    private func playNextInQueue() {
        guard !closingPlayer, case .vod(let id, _, _, _) = playerMode,
              let i = vodQueue.firstIndex(where: { $0.id == id }) else { return }
        guard i + 1 < vodQueue.count else { vodQueue = []; return }
        let next = vodQueue[i + 1]
        playVod(next.id, next.title, next.previewThumbnailURL, vodQueueStreamer, keepVisibility: true)
    }
    private func playClip(_ slug: String, _ title: String?) {
        vodQueue = []
        startPlayback(.clip(slug: slug, title: title))
    }
    /// VOD supprimée déjà reconstruite (liens prêts) : on lit directement.
    private func playRecovered(_ rec: RecoveredVod) {
        vodQueue = []
        startPlayback(.recovered(rec))
    }
    private func playLive(_ channel: String, soft: Bool = false, keepVisibility: Bool = false) {
        // Ce direct est déjà ouvert (mini-barre, puis sa notification ou sa
        // carte) : on le remontre. Tout recharger donnait un écran noir, et
        // flux et chat relus.
        if !soft, case .live(let current)? = playerMode,
           current.lowercased() == channel.lowercased(), errorMsg == nil, !closingPlayer {
            if !keepVisibility {
                pull.y = 0
                withAnimation { playerVisible = true }
            }
            return
        }
        vodQueue = []
        startPlayback(.live(channelName: channel), soft: soft, keepVisibility: keepVisibility)
    }

    /// `soft` : on reste sur la même chaîne (direct ↔ enregistrement). Le
    /// lecteur en place continue de jouer pendant que la nouvelle source se
    /// résout, au lieu d'être démonté et remplacé par un écran d'attente.
    /// `keepVisibility` : voir playVod.
    private func startPlayback(_ mode: PlayerMode, soft: Bool = false, keepVisibility: Bool = false) {
        // Plus d'aperçu de Découvrir sous le lecteur (son en double).
        DiscoverGate.shared.blocked = true
        // Referme le clavier s'il était ouvert (recherche en cours) : sinon il
        // restait affiché par-dessus le lecteur.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        // Le son passe à l'app ; il est rendu aux autres apps à la fermeture
        // du lecteur (PlaybackAudio). Rien n'est relâché en changeant de
        // chaîne : le lecteur reste ouvert.
        PlaybackAudio.shared.claim("player")
        // Même direct relu en douce (session web changée) : ses minuteries
        // continuent, elles repartent avec lui. Sinon, celles de la lecture
        // précédente (spectateurs relus toutes les 30 s, durée chaque seconde)
        // et la pulsation des drops s'arrêtent ici : passer d'un direct à une
        // VOD, ou à un direct hors ligne, les laissait tourner pour l'ancienne
        // chaîne. Calculé avant que la chaîne en cours ne change.
        var sameLive = false
        if soft, case .live(let channel) = mode, channel.lowercased() == currentChannelName { sameLive = true }
        if !sameLive {
            stopLiveTimers()
            liveViewerCount = 0
            liveStartedAt   = nil
            liveUptimeText  = ""
        }
        playerMode    = mode
        if !keepVisibility { playerVisible = true }
        // Une fermeture en plein fondu est remplacée par cette lecture (voir
        // stopPlayer).
        closingPlayer = false
        errorMsg      = nil
        chatOnly      = false
        vodPlaybackTime = 0
        liveDvrVideoId  = nil
        liveLatency     = 0
        ChatSync.shared.reset()
        pull.y          = 0
        loadingSource   = nil
        slowNoticeShown = false
        // Qualités supérieures : décidées de nouveau par cette lecture.
        resetHQLive()

        if soft {
            switchingSource = true
        } else {
            loading          = true
            playerPlaying    = false
            qualityLinks     = nil
            linksContentID   = ""
            linksAreLive     = false
            qualityVariants  = [:]
            // Avatar, jeu et qualité retenue ne sont vidés qu'à l'ouverture
            // d'une autre chaîne : en bascule, ils sont toujours les bons, et
            // les effacer ne ferait que les faire clignoter.
            liveAvatar       = nil
            liveGame         = ""
            immersiveQuality = ""
            // Vitesse imposée à la lecture précédente : la préférence revient.
            // Gardée en bascule (direct ↔ enregistrement, même chaîne).
            forcedVodSpeed   = nil
            // Titre provisoire (mini-barre d'un chargement réduit) : le vrai
            // arrive avec les liens.
            switch mode {
            case .live(let channel):             statusTitle = channel
            case .vod(let id, let title, _, _):  statusTitle = title ?? "VOD \(id)"
            case .clip(_, let title):            statusTitle = title ?? "Clip"
            case .recovered(let rec):            statusTitle = rec.title.isEmpty ? store.t("recover_title") : rec.title
            }
        }
        // Un VOD lancé depuis le bouton Rembobiner garde le lien vers sa chaîne,
        // pour pouvoir revenir au direct. Un VOD normal, non.
        if case .live = mode { dvrSourceChannel = nil }
        else { dvrSourceChannel = pendingDvrChannel }
        pendingDvrChannel = nil

        if case .live(let channel) = mode {
            let login = channel.lowercased()
            // Autre chaîne : son id est vidé, rempli après getLive (le chat
            // l'attend en bascule douce, voir chatPane). Même chaîne (session
            // web changée) : il reste, le chat aussi.
            if currentChannelName != login { currentChannelId = nil }
            currentChannelName = login
        } else {
            currentChannelName = nil
            currentChannelId   = nil
        }

        loadGeneration += 1
        let gen = loadGeneration
        clipVodId = nil; clipOffset = 0; clipSpeed = 1
        vodChapters = []
        vodMuted = []
        vodUnmuted = 0
        Task {
            switch mode {
            case .clip(let slug, let title):
                let clip = await getClip(slug: slug)
                await MainActor.run {
                    guard gen == loadGeneration else { return }
                    guard let clip else {
                        errorMsg = store.t("err_clip"); loading = false; switchingSource = false
                        return
                    }
                    qualityLinks    = clip.links
                    linksContentID  = playerContentID
                    linksAreLive    = false
                    qualityVariants = [:]   // noms avec la hauteur (« 720p60 »)
                    statusTitle     = clip.title.isEmpty ? (title ?? "Clip") : clip.title
                    clipVodId       = clip.vodId
                    clipOffset      = clip.vodOffset ?? 0
                    loading         = false
                    switchingSource = false
                }
                if let who = clip?.broadcasterLogin {
                    let avatar = await channelAvatar(login: who, token: store.twitchToken)
                    await MainActor.run { if gen == loadGeneration { liveAvatar = avatar } }
                }

            case .vod(let id, let title, _, let streamer):
                // Le bandeau du lecteur montrait un rond gris sur les VODs :
                // `getM3U8` ne ramène aucune photo de profil. On la demande à
                // part, depuis le nom de chaîne que tous les points d'entrée
                // transmettent déjà.
                if let who = streamer, !who.isEmpty {
                    Task { @MainActor in
                        let avatar = await channelAvatar(login: who.lowercased(),
                                                         token: store.twitchToken)
                        if gen == loadGeneration { liveAvatar = avatar }
                    }
                }
                // Repères (chapitres, passages coupés) en même temps que les
                // liens : ils décident de la playlist à donner au lecteur.
                async let markersTask = getVodMarkers(vodId: id)
                let data = await getM3U8(vodId: id)
                let markers = await markersTask
                // Santé des lectures (/stats) : compteur seulement, sans la VOD.
                await MainActor.run { UsageService.shared.count(data.links.isEmpty ? "vod_fail" : "vod") }
                if let err = data.error, data.links.isEmpty {
                    await MainActor.run {
                        guard gen == loadGeneration else { return }
                        errorMsg = store.t(apiErrorKey(err)); loading = false; switchingSource = false
                    }
                } else {
                    // VOD récente avec des passages coupés : le son d'origine
                    // est peut-être encore sur le CDN (VodUnmuteLoader).
                    let unmute = store.restoreMutedAudio && VodUnmuteLoader.worthTrying(markers)
                    let links = unmute ? VodUnmuteLoader.wrap(data.links) : data.links
                    await MainActor.run {
                        guard gen == loadGeneration else { return }
                        vodChapters     = markers.chapters
                        vodMuted        = markers.muted
                        qualityLinks    = links
                        linksContentID  = playerContentID
                        linksAreLive    = false
                        qualityVariants = data.variants
                        statusTitle     = title ?? "VOD \(id)"
                        loading         = false
                        switchingSource = false
                    }
                }

            case .recovered(let rec):
                // Liens déjà reconstruits et validés : aucune requête de lecture.
                if !rec.streamer.isEmpty {
                    Task { @MainActor in
                        let avatar = await channelAvatar(login: rec.streamer.lowercased(),
                                                         token: store.twitchToken)
                        if gen == loadGeneration { liveAvatar = avatar }
                    }
                }
                await MainActor.run {
                    guard gen == loadGeneration else { return }
                    qualityLinks    = rec.links
                    linksContentID  = playerContentID
                    linksAreLive    = false
                    qualityVariants = [:]
                    statusTitle     = rec.title.isEmpty ? store.t("recover_title") : rec.title
                    loading         = false
                    switchingSource = false
                }

            case .live(let channel):
                // Abonné sans pub sur cette chaîne : le direct passe par son
                // compte (session web), sinon jeton anonyme comme avant.
                let web = store.accountPlaybackWebToken(for: channel)
                // Source essayée : dite par l'écran de chargement. Qualités
                // supérieures sans abonnement : ce lecteur seulement (HQLive).
                let data = await getLive(channelName: channel, webToken: web,
                                         integrity: web.map { dropsIntegrity(for: $0) },
                                         hqAccount: true,
                                         onSource: { source in
                                             DispatchQueue.main.async {
                                                 if gen == loadGeneration { loadingSource = source }
                                             }
                                         })
                // Session refusée par Twitch : le circuit habituel l'efface et
                // affiche « session expirée ».
                if data.webSessionExpired {
                    Task { @MainActor in await store.validateWebSession() }
                }
                // Santé du direct (/stats) : la source qui a servi, ou un échec
                // — jamais la chaîne. Hors ligne n'est pas un échec.
                if let links = data.links, !links.isEmpty {
                    await MainActor.run { UsageService.shared.count("live_\(data.source ?? "unknown")") }
                } else if data.error != "offline" {
                    await MainActor.run { UsageService.shared.count("live_fail") }
                }
                // Chaîne introuvable, réseau, ou aucune source n'a répondu
                // (Twitch la dit en direct) : dit tel quel, plus « hors ligne ».
                if let err = data.error, err != "offline" {
                    await MainActor.run {
                        guard gen == loadGeneration else { return }
                        errorMsg = store.t(apiErrorKey(err)); loading = false; switchingSource = false
                    }
                } else if let links = data.links, !links.isEmpty {
                    // Mode faible latence : playlist réécrite avec la vraie
                    // durée des segments (LivePlaylistLoader), relue toutes les
                    // 2 s au lieu de 6 — le lecteur peut tenir près du bord.
                    let playable = store.lowLatency ? LivePlaylistLoader.wrap(links) : links
                    // Qualités supérieures par le compte d'un non-abonné.
                    let hq = await hqLaunch(data)
                    await MainActor.run {
                        guard gen == loadGeneration else { return }
                        if let live = hq?.live {
                            hqLive            = live
                            // Qualité du compte, retrouvée après chaque pause pub.
                            immersiveQuality  = live.accountQuality
                            qualityLinks      = live.onAdFree ? live.adFree : live.account
                            qualityVariants   = live.onAdFree ? live.adFreeVariants : live.accountVariants
                            liveSourceUsed    = live.onAdFree ? live.adFreeSource : "account"
                        } else {
                            qualityLinks      = playable
                            qualityVariants   = data.variants
                            liveSourceUsed    = data.source
                        }
                        linksContentID    = playerContentID
                        linksAreLive      = true
                        statusTitle       = data.title.isEmpty ? channel : data.title
                        liveViewerCount   = data.viewerCount
                        liveStartedAt     = data.startedAt
                        // userId Twitch → emotes de la chaîne. Même chaîne relue
                        // sans réponse de GQL : l'id déjà connu reste.
                        if let uid = data.userId { currentChannelId = uid }
                        liveAvatar        = data.avatar
                        liveGame          = data.game
                        liveDvrVideoId    = data.dvrVideoId
                        loading           = false
                        switchingSource   = false
                        startLiveTimers(channel: channel)
                        // Pub au début du flux du compte : annoncée, et retour
                        // prévu à sa fin.
                        if let hq, hq.live.onAdFree {
                            let q = hqQualityLabel(hq.live.adFree, hq.live.adFreeVariants)
                            showHQNotice(store.t("hq_ad_fallback").replacingOccurrences(of: "{q}", with: q))
                            scheduleHQReturn(after: hq.wait + 1)
                        }
                    }
                    // GQL ne rend pas toujours `profileImageURL` : repli Helix,
                    // plutôt qu'un rond gris pour le reste de la session.
                    if data.avatar == nil {
                        let fallback = await channelAvatar(login: channel.lowercased(),
                                                           token: store.twitchToken)
                        await MainActor.run { if gen == loadGeneration { liveAvatar = fallback } }
                    }
                    // Image verticale (Dual Format) : cherchée une fois le direct
                    // parti, jamais sur le chemin du lancement.
                    let portrait = await portraitLive(login: channel.lowercased(), lowLatency: store.lowLatency)
                    await MainActor.run { if gen == loadGeneration { portraitFound(portrait) } }
                } else {
                    await MainActor.run {
                        guard gen == loadGeneration else { return }
                        errorMsg = store.t("offline_msg")
                        loading = false; switchingSource = false
                    }
                }
            }
        }
    }

    /// `wakeOthers` faux (minuteur de veille) : la musique qu'une autre app
    /// jouait avant la vidéo ne reprend pas toute seule.
    private func stopPlayer(wakeOthers: Bool = true) {
        // Session audio relâchée : une musique coupée par la vidéo peut reprendre.
        // (L'écran, lui, peut de nouveau s'éteindre : voir keepScreenOn.)
        PlaybackAudio.shared.release("player", notifyOthers: wakeOthers)
        loadGeneration += 1   // un chargement encore en cours sera ignoré
        let gen = loadGeneration
        stopLiveTimers()
        resetHQLive()
        // Fin de visionnage : la progression part maintenant, plutôt que
        // toutes les quelques secondes pendant la lecture.
        store.flushToCloud(force: true)

        // Le fondu d'abord, le ménage ensuite. Vider `qualityLinks` et
        // `playerMode` dans la même transaction escamotait l'animation : le
        // contenu disparaissait aussitôt et il ne restait qu'un cadre noir à
        // estomper, d'où la fermeture « instantanée » alors que l'ouverture
        // s'animait.
        closingPlayer = true
        withAnimation(.easeInOut(duration: 0.28)) { playerVisible = false }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // Autre lecture lancée pendant le fondu (les onglets sont
            // touchables dès son début) : c'est elle qui compte. Le ménage
            // effaçait son état, alors que son chargement se poursuivait.
            guard gen == loadGeneration else { return }
            // Vraie fermeture : la Live Activity part. Le démontage du lecteur
            // ne la termine qu'au premier plan (PlayerActivity.playerRemoved) :
            // arrêté écran verrouillé (minuteur de veille), il la laissait.
            PlayerActivity.end()
            chatOnly           = false
            currentChannelName = nil
            currentChannelId   = nil
            liveDvrVideoId     = nil
            dvrSourceChannel   = nil
            pendingDvrChannel  = nil
            liveViewerCount    = 0
            liveStartedAt      = nil
            liveUptimeText     = ""
            liveLatency        = 0
            ChatSync.shared.reset()
            pull.y             = 0
            liveAvatar         = nil
            clipVodId          = nil
            clipOffset         = 0
            clipSpeed          = 1
            liveGame           = ""
            liveSourceUsed     = nil
            playerMode         = nil
            // Lecteur fermé : les aperçus de Découvrir peuvent reprendre.
            DiscoverGate.shared.blocked = showMultiLive
            qualityLinks       = nil
            linksContentID     = ""
            linksAreLive       = false
            qualityVariants    = [:]
            statusTitle        = ""
            loading            = false
            loadingSource      = nil
            errorMsg           = nil
            playerPlaying      = false
            // Rien ne doit survivre à la fermeture : une VOD de la playlist
            // rouverte plus tard depuis l'historique enchaînait sur la suivante.
            vodQueue           = []
            vodQueueStreamer   = nil
            switchingSource    = false
            vodChapters        = []
            vodMuted           = []
            vodUnmuted         = 0
            closingPlayer      = false
        }
    }

    // MARK: – Qualités supérieures sans abonnement
    /// Dernières secondes de la playlist du compte qui doivent être sans pub
    /// pour y revenir : le lecteur repart à quelques secondes du bord (6 s en
    /// faible latence, trois segments sinon).
    private var hqEdgeWindow: TimeInterval { store.lowLatency ? 10 : 20 }

    /// Qualités supérieures par le compte d'un non-abonné (getLive :
    /// hqAccountLinks) : seulement si la qualité de départ y dépasse 1080p
    /// (sinon aucune pub risquée pour rien), et d'abord par la source sans pub
    /// quand une pub ouvre la playlist du compte (`wait` : ses secondes
    /// restantes) ; sans bascule si la source habituelle a elle aussi des
    /// pubs (Twitch officiel). nil : la source habituelle, comme avant.
    private func hqLaunch(_ data: LiveData) async -> (live: HQLive, wait: TimeInterval)? {
        let wrap = { (links: QualityLinks) -> QualityLinks in
            store.lowLatency ? LivePlaylistLoader.wrap(links) : links
        }
        // Aucune source habituelle n'a répondu : le compte, sans bascule possible.
        if data.accountAds, let links = data.links {
            let live = HQLive(account: wrap(links), accountVariants: data.variants,
                              accountQuality: currentQuality(links, variants: data.variants),
                              adFree: [:], adFreeVariants: [:], adFreeSource: nil)
            return (live, 0)
        }
        guard let account = data.hqAccountLinks, !account.isEmpty,
              let adFree = data.links, !adFree.isEmpty else { return nil }
        let start = currentQuality(account, variants: data.hqAccountVariants)
        guard qualityHeight(start, among: Array(account.keys), variants: data.hqAccountVariants) > 1080 else {
            logger.info("LECTEUR", "Qualité de départ en 1080p ou moins", "source habituelle, sans pub")
            return nil
        }
        // 2 s au plus : avec la liste du compte (getLive, 2 s aussi), le
        // lancement attend 4 s de plus au pire.
        guard let url = account[start].flatMap({ URL(string: $0) }),
              let wait = await AdBreakMonitor.adWait(at: url, window: hqEdgeWindow, timeout: 2) else {
            logger.warn("LECTEUR", "Flux du compte injoignable", "source habituelle, sans pub")
            return nil
        }
        // Source habituelle = Twitch officiel sans compte : des pubs elle
        // aussi, aucune bascule n'y gagnerait. Le compte seul, comme sans
        // source habituelle : ses pubs coupées et annoncées, pré-roll compris.
        guard data.source != "twitch" else {
            logger.info("LECTEUR", "Source habituelle avec pubs (Twitch officiel) : direct par le compte",
                        "pubs de Twitch comprises")
            let live = HQLive(account: wrap(account), accountVariants: data.hqAccountVariants,
                              accountQuality: start, adFree: [:], adFreeVariants: [:], adFreeSource: nil)
            return (live, 0)
        }
        var live = HQLive(account: wrap(account), accountVariants: data.hqAccountVariants,
                          accountQuality: start, adFree: wrap(adFree), adFreeVariants: data.variants,
                          adFreeSource: data.source)
        if wait > 0 {
            // Twitch coud souvent une pub au début de la séance : la source
            // sans pub d'abord, le compte à sa fin.
            live.onAdFree = true
            live.switches = 1
            logger.info("PUB", "Pub au début du flux du compte", "source sans pub d'abord")
        }
        return (live, wait)
    }

    /// Pause pub à l'écran d'après le lecteur (secondes restantes, nil hors
    /// pause). Sur le flux du compte : la source sans pub — pas en pause (la
    /// bascule relancerait la lecture ; le compte à rebours, qui reprend avec
    /// elle, la refait). Sur la source sans pub : une pause de la chaîne
    /// (écran violet), que le retour attend.
    private func adBreakChanged(_ left: Int?) {
        guard var live = hqLive, linksAreLive, dvrSourceChannel == nil,
              !switchingSource, !closingPlayer else { return }
        if live.onAdFree {
            guard live.adFreeBreak != left else { return }
            live.adFreeBreak = left
            hqLive = live
        } else if let left, playerPlaying {
            switchToAdFree(remaining: left)
        }
    }

    /// Pause pub de Twitch sur le flux du compte : la source sans pub (1080p
    /// au plus ; la qualité choisie si elle y est), comme un changement de
    /// qualité — lecteur, chat et Live Activity restent. Retour prévu à la fin
    /// de la pause : `left` s et une marge (scheduleHQReturn).
    private func switchToAdFree(remaining left: Int) {
        guard var live = hqLive, !live.onAdFree, !live.adFree.isEmpty, !live.refreshing else { return }
        // Liens lus il y a plus de 10 min : leurs adresses de séance ont pu
        // expirer, et le lecteur resterait figé dessus. Relus d'abord ; la
        // bascule attend des liens frais (seconde suivante de la pause). Ratée,
        // la pub reste sur le compte, coupée et annoncée comme ailleurs, et
        // pas de nouvel essai avant une minute.
        if live.adFreeStale {
            if let failed = live.refreshFailed, Date().timeIntervalSince(failed) < 60 { return }
            logger.info("PUB", "Source sans pub lue il y a plus de 10 min", "relue avant la bascule")
            refreshAdFree()
            return
        }
        // Pub revenue moins de 30 s après un retour : la pause n'était pas
        // finie, ou Twitch en remet. Deux fois de suite : plus de retour.
        if let back = live.lastReturn, Date().timeIntervalSince(back) < 30 {
            live.quickAds += 1
        } else {
            live.quickAds = 0
        }
        live.onAdFree = true
        live.adFreeBreak = nil
        live.switches += 1
        hqLive = live
        qualityLinks = live.adFree
        qualityVariants = live.adFreeVariants
        liveSourceUsed = live.adFreeSource
        let q = hqQualityLabel(live.adFree, live.adFreeVariants)
        showHQNotice(store.t("hq_ad_fallback").replacingOccurrences(of: "{q}", with: q))
        logger.info("PUB", "Pause pub Twitch : source sans pub", "\(q) · \(left) s")
        if live.quickAds >= 2 {
            logger.warn("PUB", "Pubs répétées sur le flux du compte", "reste sur la source sans pub")
            settleOnAdFree()
        } else {
            scheduleHQReturn(after: TimeInterval(left) + 2)
        }
    }

    /// Retour au flux du compte, `delay` s plus tard. Pas tant que la source
    /// sans pub montre elle-même une pause (celle de la chaîne), ni que le bord
    /// de la playlist du compte est en pub (pub suivante, annoncée après
    /// coup) : on attend encore, vingt vérifications au plus, puis on reste
    /// sur la source sans pub, qui a l'image. Playlist du compte injoignable :
    /// on y reste aussi. Lecture en pause : plus de vérification (le retour la
    /// relancerait) ; elles reprennent avec la lecture (onChange playerPlaying).
    private func scheduleHQReturn(after delay: TimeInterval) {
        hqReturnTask?.cancel()
        let gen = loadGeneration
        hqReturnTask = Task { @MainActor in
            var wait = delay
            var checks = 0
            while true {
                try? await Task.sleep(nanoseconds: UInt64(max(1, wait) * 1_000_000_000))
                guard !Task.isCancelled, gen == loadGeneration, let live = hqLive, live.onAdFree else { return }
                // En pause : la tâche s'arrête, la reprise la relance. Pas
                // annulée, c'est bien elle que tient hqReturnTask.
                guard playerPlaying else {
                    hqReturnTask = nil
                    return
                }
                checks += 1
                guard checks <= 20 else {
                    logger.warn("PUB", "Retour au flux du compte impossible", "reste sur la source sans pub")
                    settleOnAdFree()
                    return
                }
                // Pause de la chaîne sur la source sans pub : le compte a la sienne.
                if let left = live.adFreeBreak {
                    wait = TimeInterval(left) + 2
                    continue
                }
                // Bascule ou erreur en cours : un peu plus tard.
                guard linksAreLive, !switchingSource, errorMsg == nil,
                      let link = live.account[currentQuality(live.account, variants: live.accountVariants)],
                      let url = URL(string: link).flatMap({ LivePlaylistLoader.unwrap($0) }) else {
                    wait = 5
                    continue
                }
                let pending = await AdBreakMonitor.adWait(at: url, window: hqEdgeWindow)
                guard !Task.isCancelled, gen == loadGeneration, let after = hqLive, after.onAdFree else { return }
                // Mise en pause pendant la vérification : comme plus haut.
                guard playerPlaying else {
                    hqReturnTask = nil
                    return
                }
                // Pause de la chaîne commencée pendant la vérification.
                if let left = after.adFreeBreak {
                    wait = TimeInterval(left) + 2
                    continue
                }
                guard let pending else {
                    logger.warn("PUB", "Flux du compte injoignable", "reste sur la source sans pub")
                    settleOnAdFree()
                    return
                }
                if pending > 0 {
                    wait = min(pending + 1, 30)
                    logger.debug("PUB", "Pub encore au bord du flux du compte", "nouvel essai dans \(Int(wait)) s")
                    continue
                }
                returnToAccount()
                return
            }
        }
    }

    /// Fin de la pause pub : retour au flux du compte, dans la qualité qu'il
    /// avait (ou celle choisie entre-temps, si elle y est).
    private func returnToAccount() {
        guard var live = hqLive, live.onAdFree else { return }
        live.onAdFree = false
        live.adFreeBreak = nil
        live.lastReturn = Date()
        hqLive = live
        qualityLinks = live.account
        qualityVariants = live.accountVariants
        liveSourceUsed = "account"
        let q = hqQualityLabel(live.account, live.accountVariants)
        showHQNotice(store.t("hq_ad_back").replacingOccurrences(of: "{q}", with: q))
        logger.info("PUB", "Fin de la pause pub : retour au flux du compte", q)
    }

    /// Lecture arrêtée sur une erreur (après les relances du lecteur). Flux du
    /// compte : la source sans pub, pour de bon (relue d'abord si ses liens
    /// sont trop anciens). Source sans pub, pendant une pause : retour au
    /// compte tout de suite — sa pub y est coupée et annoncée, comme sur les
    /// autres sources — et la source habituelle est relue pour les pauses
    /// suivantes ; rien où basculer d'ici là.
    private func hqStreamFailed() {
        guard var live = hqLive, !live.adFree.isEmpty, linksAreLive,
              dvrSourceChannel == nil, !switchingSource else { return }
        guard live.onAdFree else {
            logger.warn("LECTEUR", "Flux du compte en échec", "reste sur la source sans pub")
            if live.adFreeStale { refreshAdFree { settleOnAdFree() } } else { settleOnAdFree() }
            return
        }
        logger.warn("LECTEUR", "Source sans pub en échec", "retour au flux du compte, source relue")
        hqReturnTask?.cancel()
        hqReturnTask = nil
        live.onAdFree = false
        live.adFreeBreak = nil
        // Liens morts : plus de bascule dessus tant qu'ils ne sont pas relus.
        live.adFreeAt = .distantPast
        hqLive = live
        qualityLinks = live.account
        qualityVariants = live.accountVariants
        liveSourceUsed = "account"
        refreshAdFree()
    }

    /// Source habituelle relue sans le compte, comme au lancement (getLive sans
    /// hqAccount) : des liens frais pour les pauses pub. Twitch officiel sans
    /// compte n'en est pas une (des pubs aussi). Ratée : les anciens liens ne
    /// servent plus, nouvel essai une minute plus tard au plus tôt
    /// (switchToAdFree). `done` : après une relecture réussie, même lecture.
    private func refreshAdFree(then done: (() -> Void)? = nil) {
        guard var live = hqLive, !live.refreshing, case .live(let channel)? = playerMode else { return }
        live.refreshing = true
        hqLive = live
        let gen = loadGeneration
        Task { @MainActor in
            let data = await getLive(channelName: channel)
            guard gen == loadGeneration, var now = hqLive else { return }
            now.refreshing = false
            guard let links = data.links, !links.isEmpty, data.source != "twitch" else {
                now.refreshFailed = Date()
                hqLive = now
                logger.warn("PUB", "Source sans pub injoignable", "reste sur le flux du compte")
                return
            }
            now.adFree = store.lowLatency ? LivePlaylistLoader.wrap(links) : links
            now.adFreeVariants = data.variants
            now.adFreeSource = data.source
            now.adFreeAt = Date()
            now.refreshFailed = nil
            hqLive = now
            done?()
        }
    }

    /// Plus de retour au compte pour cette lecture (pubs répétées, flux du
    /// compte injoignable ou en échec) : la source sans pub reste, comme un
    /// direct ordinaire, et le compte n'est plus essayé sur cette chaîne
    /// jusqu'au prochain lancement de l'app (relecture, « Réessayer »).
    private func settleOnAdFree() {
        hqReturnTask?.cancel()
        hqReturnTask = nil
        guard let live = hqLive, !live.adFree.isEmpty else { return }
        if !live.onAdFree {
            qualityLinks = live.adFree
            qualityVariants = live.adFreeVariants
            liveSourceUsed = live.adFreeSource
        }
        hqLive = nil
        guard case .live(let channel)? = playerMode else { return }
        store.accountPlaybackSkipped.insert(channel.lowercased())
        // Le compte ne lit plus le flux : la pulsation des drops s'en charge.
        startDropsHeartbeat(channel: channel)
    }

    /// Qualité lue sur ces liens, pour les avis : « Source » par sa hauteur
    /// (« 1080p »), les autres par leur nom des menus.
    private func hqQualityLabel(_ links: QualityLinks, _ variants: [String: VariantInfo]) -> String {
        let key = currentQuality(links, variants: variants)
        if isSourceQuality(key), let height = variants[key]?.height, height > 0 { return "\(height)p" }
        return qualityText(key, store.lang)
    }

    /// Bascule annoncée dans le lecteur, 4 s.
    private func showHQNotice(_ text: String) {
        hqNotice = text
        hqNoticeTask?.cancel()
        hqNoticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            hqNotice = nil
        }
    }

    /// Autre lecture, ou fermeture : plus de bascule ni de retour prévu.
    private func resetHQLive() {
        hqReturnTask?.cancel()
        hqReturnTask = nil
        hqLive = nil
        hqNoticeTask?.cancel()
        hqNoticeTask = nil
        hqNotice = nil
        // Image verticale : cherchée de nouveau par cette lecture.
        portraitMaster = nil
        verticalOn = false
        verticalBackup = nil
    }

    // MARK: – Image verticale (Dual Format)
    /// Préférence retenue : une fois l'image verticale choisie, les directs
    /// suivants qui en ont une partent dessus (comme l'app de Twitch, téléphone
    /// tenu droit), jusqu'à ce qu'on revienne à l'habituelle.
    private static let verticalKey = "cfg_prefer_vertical"

    /// Résultat de portraitLive pour le direct en cours : le bouton apparaît,
    /// et l'image verticale est prise d'office si on l'avait choisie avant.
    private func portraitFound(_ portrait: MasterPlaylist?) {
        guard let portrait, linksAreLive, dvrSourceChannel == nil else { return }
        portraitMaster = portrait
        if UserDefaults.standard.bool(forKey: Self.verticalKey) {
            setVertical(true)
            showHQNotice(store.t("vertical_on"))
        }
    }

    /// Bouton « vertical » : l'une ou l'autre image, et le choix retenu.
    private func toggleVertical() {
        setVertical(!verticalOn)
        UserDefaults.standard.set(verticalOn, forKey: Self.verticalKey)
        logger.settingChanged("Image verticale", value: verticalOn ? "oui" : "non")
    }

    /// Image verticale à la place de l'habituelle, ou retour. Comme un
    /// changement de qualité : lecteur, chat et Live Activity restent. Les
    /// qualités supérieures par le compte s'arrêtent (leurs bascules pendant
    /// les pubs ne connaissent que l'image habituelle) ; elles reviennent au
    /// prochain lancement.
    private func setVertical(_ on: Bool) {
        guard on != verticalOn, linksAreLive, dvrSourceChannel == nil, !switchingSource else { return }
        if on {
            guard let portrait = portraitMaster, let links = qualityLinks else { return }
            if hqLive != nil {
                hqReturnTask?.cancel()
                hqReturnTask = nil
                hqLive = nil
            }
            verticalBackup = (links: links, variants: qualityVariants, source: liveSourceUsed)
            qualityLinks = store.lowLatency ? LivePlaylistLoader.wrap(portrait.links) : portrait.links
            qualityVariants = portrait.variants
            liveSourceUsed = "twitch"
            verticalOn = true
            logger.info("LECTEUR", "Image verticale (Dual Format)", "\(portrait.links.count) qualités, par Twitch")
        } else {
            if let back = verticalBackup {
                qualityLinks = back.links
                qualityVariants = back.variants
                liveSourceUsed = back.source
            }
            verticalBackup = nil
            verticalOn = false
            logger.info("LECTEUR", "Retour à l'image habituelle")
        }
    }

    // MARK: – Live timers
    private func startLiveTimers(channel: String) {
        stopLiveTimers()
        updateUptime()
        let gen = loadGeneration
        uptimeTimer  = Timer.scheduledCommon(every: 1)  { _ in updateUptime() }
        refreshTimer = Timer.scheduledCommon(every: 30) { _ in
            Task {
                // Rafraîchissement LÉGER : ne re-fetch PAS les liens du stream,
                // juste le nombre de viewers et l'uptime.
                let stats = await getStreamStats(channelName: channel)
                await MainActor.run {
                    // Autre lecture entre-temps : ces chiffres sont ceux
                    // d'une chaîne qu'on ne regarde plus.
                    guard gen == loadGeneration else { return }
                    if stats.viewerCount > 0  { liveViewerCount = stats.viewerCount }
                    if let s = stats.startedAt { liveStartedAt  = s }
                }
            }
        }
        // Drops : Twitch ne les compte que si la session du compte charge le
        // flux, ce que la lecture par proxy ne fait pas (voir DropsHeartbeat).
        // Direct lu par le compte : c'est déjà le cas, une seconde session du
        // compte ne servirait à rien ; la pulsation garde alors seulement
        // l'état de la page Drops et la réclamation automatique.
        startDropsHeartbeat(channel: channel)
    }

    /// Progression des drops pour le direct en cours. Appelée aussi quand on
    /// l'active ou qu'on connecte la session web pendant le direct : rien ne
    /// progressait avant de rouvrir le live.
    private func startDropsHeartbeat(channel: String) {
        guard store.dropsProgress, let web = store.twitchWebToken, !web.isEmpty else { return }
        // Qualités supérieures : le compte lit le flux, sauf le temps des pauses pub.
        DropsHeartbeat.shared.start(login: channel, token: web,
                                    pollSegments: liveSourceUsed != "account" && hqLive == nil)
    }

    private func stopLiveTimers() {
        refreshTimer?.invalidate(); refreshTimer = nil
        uptimeTimer?.invalidate();  uptimeTimer  = nil
        DropsHeartbeat.shared.stop()
    }

    private func updateUptime() {
        guard let start = liveStartedAt else { return }
        // Horloge de l'appareil en retard sur Twitch : « 0:-5 » sinon.
        let elapsed = max(0, Int(Date().timeIntervalSince(start)))
        let h = elapsed / 3600, m = (elapsed % 3600) / 60, s = elapsed % 60
        liveUptimeText = h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    private var modeTitle: String {
        // Le direct est déjà signalé par le badge de l'encart : ici, juste le nom.
        guard let mode = playerMode else { return statusTitle }
        if case .live(let ch) = mode { return ch }
        return statusTitle
    }
}

// MARK: – Custom Tab Bar
struct CustomTabBar: View {
    @Binding var activeTab: MainTabView.TabName
    /// Verre liquide : capsule flottante au-dessus du contenu.
    var floating = false
    @EnvironmentObject private var store: AppStore
    /// Visite guidée en cours : tous les onglets, même masqués.
    @AppStorage("onboarding_done") private var onboardingDone = false

    private var bottomInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.bottom ?? 34
    }

    /// Onglet touché, dans cette barre ou dans la colonne (SideTabRail).
    /// Déjà affiché : sa liste remonte en haut, comme dans les apps d'iOS
    /// (TabScrollView, Découvrir).
    static func select(_ tab: MainTabView.TabName, in activeTab: Binding<MainTabView.TabName>) {
        guard activeTab.wrappedValue != tab else {
            NotificationCenter.default.post(name: .tuTabReselected, object: tab)
            return
        }
        withAnimation(.easeOut(duration: 0.15)) { activeTab.wrappedValue = tab }
    }

    var body: some View {
        if floating {
            tabs
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
                .tGlass(in: Capsule(), fallback: .tCard)
                .padding(.horizontal, 28)
                .padding(.top, 6)
                .padding(.bottom, max(bottomInset - 12, 10))
        } else {
            tabs
                .padding(.top, 10)
                .padding(.bottom, bottomInset + 6)
                .background(.ultraThinMaterial)
                .overlay(Divider().background(Color.tBorder), alignment: .top)
        }
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(MainTabView.TabName.visible(store, all: !onboardingDone), id: \.self) { tab in
                let isActive = activeTab == tab
                Button {
                    Self.select(tab, in: $activeTab)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: isActive ? tab.iconFilled : tab.icon)
                            .font(.system(size: 19, weight: isActive ? .semibold : .regular))
                            .frame(height: 24)
                        Text(tab.label(store))
                            .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundColor(isActive ? .tPrimary : .tMuted)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tourAnchor(tab.tourTarget)
            }
        }
    }
}

extension Notification.Name {
    /// Onglet de la barre touché alors qu'il est déjà affiché (objet : son
    /// MainTabView.TabName) : l'écran remonte en haut de sa liste.
    static let tuTabReselected = Notification.Name("TUTabReselected")
}

/// Liste défilante d'un onglet de la barre : l'onglet touché à nouveau la
/// ramène en haut, en douceur. Le contenu est posé sous un repère sans
/// hauteur, que vise le ScrollViewReader.
struct TabScrollView<Content: View>: View {
    let tab: MainTabView.TabName
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).id("tab_top")
                    content()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .tuTabReselected)) { note in
                guard (note.object as? MainTabView.TabName) == tab else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo("tab_top", anchor: .top) }
            }
        }
    }
}

/// Chaîne affichée dans la feuille « page de chaîne ».
struct ChannelSheetItem: Identifiable {
    let login: String
    var id: String { login }
}

/// Mise en veille de l'écran suspendue tant qu'un lecteur le demande :
/// l'écran du lecteur (« player », voir MainTabView.keepScreenOn) ou le
/// multi-live (« multi »). Chacun pour soi : passer de l'un à l'autre ne
/// rend pas la veille sous celui qui s'ouvre. Fil principal seulement.
enum ScreenAwake {
    private static var owners = Set<String>()

    static func set(_ owner: String, _ on: Bool) {
        if on { owners.insert(owner) } else { owners.remove(owner) }
        let wanted = !owners.isEmpty
        guard UIApplication.shared.isIdleTimerDisabled != wanted else { return }
        UIApplication.shared.isIdleTimerDisabled = wanted
    }
}

/// Direct en qualité supérieure par le compte d'un non-abonné
/// (HigherQualities) : les liens du compte, que Twitch coupe de ses pubs, et
/// ceux de la source habituelle sans pub, lue le temps de chaque pause pub
/// (MainTabView.adBreakChanged).
private struct HQLive {
    /// Liens jouables (tulive:// en faible latence) et variantes du compte.
    let account: QualityLinks
    let accountVariants: [String: VariantInfo]
    /// Qualité de départ sur le flux du compte (au-dessus de 1080p).
    let accountQuality: String
    /// Source habituelle : vide si aucune n'a répondu, ou si c'est Twitch
    /// officiel, avec ses pubs (rien où basculer).
    var adFree: QualityLinks
    var adFreeVariants: [String: VariantInfo]
    var adFreeSource: String?
    /// Lecture de ces liens (lancement, ou relus) : adresses de séance, qui
    /// peuvent expirer ; plus de 10 min, relus avant une bascule.
    var adFreeAt = Date()
    var adFreeStale: Bool { Date().timeIntervalSince(adFreeAt) > 600 }
    /// Relecture en cours (refreshAdFree), et dernière ratée.
    var refreshing = false
    var refreshFailed: Date? = nil
    /// Sur la source sans pub en ce moment.
    var onAdFree = false
    /// Pause à l'écran sur la source sans pub (pause de la chaîne, écran
    /// violet) : secondes restantes, que le retour attend.
    var adFreeBreak: Int? = nil
    /// Dernier retour au compte, et pubs revenues juste après (voir
    /// switchToAdFree).
    var lastReturn: Date? = nil
    var quickAds = 0
    /// Bascules faites : l'avis « par ton compte » n'est plus redit après.
    var switches = 0
}
