import SwiftUI
import AVFoundation

struct MainTabView: View {
    @EnvironmentObject private var store: AppStore
    @State private var activeTab: TabName = .home

    // ── Player state ─────────────────────────────────────────────────────
    @State private var playerMode: PlayerMode? = nil
    /// Playlist lancée avec « Tout lire » : la VOD suivante démarre à la fin.
    @State private var vodQueue: [VodData] = []
    @State private var vodQueueStreamer: String? = nil
    @State private var qualityLinks: QualityLinks? = nil
    @State private var playerVisible = false
    @State private var loading = false
    @State private var errorMsg: String? = nil
    @State private var statusTitle = ""

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
    @State private var liveStartedAt: Date? = nil
    @State private var liveUptimeText: String = ""
    @State private var refreshTimer: Timer? = nil
    @State private var uptimeTimer: Timer? = nil

    // ── Débogage / synchro ────────────────────────────────────────────────
    /// Latence mesurée du direct, arrondie à la seconde (affichée).
    @State private var liveLatency: Double = 0
    /// Distance au bord du direct, arrondie à la seconde (synchro auto du chat).
    @State private var liveBehind: Double = 0
    /// Glissé vers le bas du lecteur en cours : décalage suivi au doigt.
    /// Objet gardé en @State sans être observé ici : seul PlayerPullEffect
    /// se redessine pendant le geste (voir PlayerPull.swift).
    @State private var pull = PlayerPull()
    /// Glissé du bandeau du lecteur natif en cours (revient seul à faux,
    /// même si le geste est interrompu).
    @GestureState private var topBarDragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // ── Minuteur de veille ────────────────────────────────────────────────
    @ObservedObject private var sleepTimer = SleepTimerService.shared
    @State private var showSleepSheet  = false
    @State private var showSettings    = false
    @State private var showPlayerMenu  = false
    /// Formulaire de retour, et ce qui se lisait quand on l'a ouvert depuis
    /// le lecteur (joint au message).
    @State private var showFeedback    = false
    @State private var feedbackContext: String? = nil
    /// Qualité retenue par le lecteur immersif (vide = meilleure disponible).
    @State private var immersiveQuality = ""
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
    /// Incrémenté à chaque ouverture et fermeture du lecteur : la réponse
    /// d'un chargement dépassé (chaîne A arrivée après la chaîne B, lecteur
    /// déjà fermé) est ignorée au lieu d'écraser l'état ou de relancer les
    /// minuteries du direct sans lecteur.
    @State private var loadGeneration = 0
    @ObservedObject private var updater = UpdateChecker.shared
    @State private var showDiscordPrompt = false
    /// Page d'une chaîne ouverte en feuille (sans passer par l'onglet Recherche).
    @State private var channelSheet: ChannelSheetItem? = nil
    /// Visite guidée du tout premier lancement (revue depuis les réglages).
    @AppStorage("onboarding_done") private var onboardingDone = false
    /// Clip en cours : VOD d'origine et position, pour en rejouer le chat.
    @State private var clipVodId: String? = nil
    @State private var clipOffset: Double = 0
    /// Chapitres de la VOD en cours (changements de jeu).
    @State private var vodChapters: [VodChapter] = []
    /// Passages de la VOD dont Twitch a coupé le son (et que l'app n'a pas pu
    /// rétablir), et nombre de segments rétablis (VodUnmuteLoader).
    @State private var vodMuted: [MutedRange] = []
    @State private var vodUnmuted = 0

    /// Décalage à appliquer au chat, si la synchro est active : notre retard
    /// sur le bord du direct. Les messages viennent de spectateurs qui
    /// regardent eux-mêmes près de ce bord. La latence totale (horodatage de
    /// Twitch → écran) compte en plus leur propre retard et, surtout, le délai
    /// que certaines chaînes ajoutent à leur diffusion — que ces spectateurs
    /// subissent aussi : le chat arrivait alors 10 s trop tard, ou plus.
    private var chatDelay: Double {
        guard store.autoChatDelay, isLivePlaying else { return 0 }
        // Borne haute : évite un décalage absurde. La retouche manuelle
        // (pastille du chat, réglages) s'ajoute à l'estimation.
        return max(0, min(liveBehind + store.chatSyncNudge, 60))
    }

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

    /// Ce qui se lit, joint à un signalement fait depuis le lecteur.
    private var playerFeedbackContext: String? {
        guard playerMode != nil else { return nil }
        let parts: [String?] = [isLivePlaying ? "live" : "vod", playerChannelLogin,
                                isLivePlaying ? nil : currentVodId]
        return parts.compactMap { $0 }.joined(separator: " ")
    }

    /// Y a-t-il un chat à afficher sous le lecteur ?
    private var chatTarget: String? {
        if let ch = currentChannelName { return ch }
        return currentVodId
    }

    /// Trois destinations seulement. « Streamer » et « Lien / ID » ont fusionné
    /// dans Recherche, et les Réglages sont passés derrière l'avatar de l'en-tête.
    enum TabName: String, CaseIterable {
        case home, search, library

        var icon: String {
            switch self {
            case .home:    return "play.tv"
            case .search:  return "magnifyingglass"
            case .library: return "clock.arrow.circlepath"
            }
        }
        var iconFilled: String {
            switch self {
            case .home:    return "play.tv.fill"
            case .search:  return "magnifyingglass"
            case .library: return "clock.arrow.circlepath"
            }
        }
        func label(_ store: AppStore) -> String {
            switch self {
            case .home:    return store.t("tab_home")
            case .search:  return store.t("tab_search")
            case .library: return store.t("tab_library")
            }
        }
        /// Onglets que la visite guidée fait toucher.
        var tourTarget: TourTarget? {
            switch self {
            case .home:    return nil
            case .search:  return .tabSearch
            case .library: return .tabLibrary
            }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.tDark.ignoresSafeArea()

            VStack(spacing: 0) {
                HeaderView(title: activeTab.label(store),
                           onOpenSettings: { showSettings = true },
                           onFeedback: { feedbackContext = nil; showFeedback = true })
                    .zIndex(10)

                Group {
                    switch activeTab {
                    // Les fermetures sont explicites : Swift n'applique pas les
                    // valeurs par défaut (`soft:`) quand une méthode est passée
                    // comme valeur, donc `playLive` vaudrait ici
                    // `(String, Bool) -> Void` et ne collerait pas au callback.
                    case .home:    HomeView(onPlayStream: { playLive($0) })
                    case .search:  SearchView(onPlayVod: { playVod($0, $1, $2, $3) },
                                              onPlayLive: { playLive($0) },
                                              onPlayClip: { playClip($0, $1) },
                                              onPlayQueue: { playQueue($0, $1) },
                                              onRecovered: { playRecovered($0) })
                    case .library: LibraryView(onPlayVod: { playVod($0, $1, $2, $3) })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Verre liquide (iOS 26) : la barre d'onglets flotte sur le
                // contenu, qui défile dessous et transparaît à travers.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if store.liquidGlass && Theme.glassSupported {
                        CustomTabBar(activeTab: $activeTab, floating: true)
                    }
                }

                if !(store.liquidGlass && Theme.glassSupported) {
                    CustomTabBar(activeTab: $activeTab)
                }
            }
            .ignoresSafeArea()
            // Thème changé dans les réglages : les onglets sont reconstruits,
            // pour qu'aucune vue ne garde les anciennes couleurs. Le lecteur et
            // la feuille des réglages, hors de ce bloc, restent en place.
            .id(store.themeID)

            // ── Mini bar ──────────────────────────────────────────────
            // `!closingPlayer` : sans lui, la mini-barre apparaîtrait le temps du
            // fondu de fermeture, le lecteur étant encore en place mais masqué.
            if playerMode != nil && !playerVisible && qualityLinks != nil && !closingPlayer {
                miniBar.zIndex(99)
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
                qualities: sortQualities(Array((qualityLinks ?? [:]).keys)),
                selected: currentQuality(qualityLinks ?? [:]),
                canRewind: liveDvrVideoId != nil,
                isDvr: dvrSourceChannel != nil,
                onSelectQuality: { q in immersiveQuality = q; store.rememberQualityChoice(q); showPlayerMenu = false },
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
                                  showFeedback = true } }
            )
            .presentationDetents([.medium])
        }
        // Réglages : ouverts depuis l'avatar de l'en-tête.
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        // Signaler un bug ou proposer une idée (en-tête, menu du lecteur).
        .sheet(isPresented: $showFeedback) {
            FeedbackSheet(context: feedbackContext)
                .environmentObject(store)
                .presentationDetents([.large])
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
                TPromptCard(
                    icon: "arrow.down.circle.fill",
                    title: store.t("update_title"),
                    message: store.t(up.changes.isEmpty ? "update_msg_short" : "update_whats_new"),
                    detail: "\(UpdateChecker.installedVersion)  →  \(up.version)",
                    primary: store.t("update_open"),
                    secondary: store.t("later"),
                    onPrimary: { withAnimation(.spring(response: 0.3)) { updater.dismiss() }; UpdateChecker.openSource() },
                    onSecondary: { withAnimation(.spring(response: 0.3)) { updater.dismiss() } },
                    // Nouveautés de chaque build manquant, du plus récent au plus ancien.
                    sections: up.changes.map { .init(title: $0.version, items: $0.items) })
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
        // Visite guidée (premier lancement, ou revue depuis les réglages) :
        // par-dessus tout, elle éclaire les vrais boutons de l'app, dont les
        // positions remontent par `TourAnchorKey`.
        .overlayPreferenceValue(TourAnchorKey.self) { anchors in
            Group {
                if !onboardingDone {
                    GeometryReader { proxy in
                        OnboardingTour(rects: anchors.mapValues { proxy[$0] },
                                       size: proxy.size,
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
        // par Recherche ; le lecteur se réduit en mini-barre.
        .onChange(of: store.pendingChannel) { login in
            guard let login else { return }
            store.pendingChannel = nil
            withAnimation(.easeInOut(duration: 0.2)) { playerVisible = false }
            channelSheet = ChannelSheetItem(login: login)
        }
        .sheet(item: $channelSheet) { item in
            SearchView(onPlayVod: { id, t, th, s in channelSheet = nil; playVod(id, t, th, s) },
                       onPlayLive: { l in channelSheet = nil; playLive(l) },
                       onPlayClip: { slug, t in channelSheet = nil; playClip(slug, t) },
                       onPlayQueue: { list, s in channelSheet = nil; playQueue(list, s) },
                       onRecovered: { rec in channelSheet = nil; playRecovered(rec) },
                       initialChannel: item.login,
                       onClose: { channelSheet = nil })
                .environmentObject(store)
                .presentationDragIndicator(.visible)
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
        .onReceive(NotificationCenter.default.publisher(for: .openLiveChannel)) { note in
            if let login = note.userInfo?["login"] as? String, !login.isEmpty { playLive(login) }
        }
        // Réglage rapide du minuteur depuis le lecteur.
        .sheet(isPresented: $showSleepSheet) {
            SleepTimerSheet()
                .presentationDetents([.medium, .large])
        }
        // Session web : vérifiée une fois au lancement. Sans ça on ne s'aperçoit
        // de son expiration que quand les points cessent de répondre.
        .task { await store.validateWebSession() }
        // Minuteur de veille écoulé → on coupe la lecture.
        .onChange(of: sleepTimer.fireCount) { _ in
            guard playerMode != nil else { return }
            logger.info("SLEEP", "Arrêt du lecteur par le minuteur de veille", nil)
            stopPlayer()
        }
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
                    VStack(spacing: TSpace.md) {
                        ProgressView().tint(.tPrimary).scaleEffect(1.3)
                        Text(store.t("loading_vod"))
                            .font(.tCardTitle).foregroundColor(.tMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                } else if let err = errorMsg {
                    TEmptyState(icon: "exclamationmark.triangle", title: err,
                                actionTitle: store.t("back"), action: { stopPlayer() })
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
                    .frame(height: 34)
                    .background(Color.black.opacity(0.65))
                    .clipShape(Capsule())
                    .padding(.top, TSpace.lg)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: switchingSource)
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
        // Portrait : hauteur 16:9 imposée, le chat prend le reste.
        // Paysage : libre, la colonne donne toute sa hauteur à l'image.
        let videoHeight: CGFloat? = split ? nil : size.width * 9 / 16
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
                // Un trait marque le bord du chat dans les deux dispositions :
                // posé sur l'image, sans lui, on ne sait plus où il commence.
                // Il sert aussi de poignée de redimensionnement.
                .overlay(alignment: .leading) {
                    if split { chatResizeHandle(totalWidth: size.width) }
                }
                .frame(width: chatColumn, alignment: .trailing)
                .opacity(chatVisible ? 1 : 0)
                .allowsHitTesting(chatVisible)
        }
    }

    /// Trait de séparation vidéo / chat, qui se saisit pour régler la largeur.
    ///
    /// Le trait visible reste fin ; c'est une bande transparente de 24 pt qui
    /// reçoit le geste, sous peine de viser un fil de 2 pt avec un pouce.
    @ViewBuilder
    private func chatResizeHandle(totalWidth: CGFloat) -> some View {
        let overlaying = store.landscapeChat == .overlay
        let dragging   = chatDragRatio != nil
        Rectangle()
            .fill(dragging ? Color.tPrimary
                           : (overlaying ? Color.tPrimary.opacity(0.75) : Color.tBorder))
            .frame(width: overlaying || dragging ? 2 : 1)
            .overlay {
                // Sans repère, personne ne devine qu'on peut tirer.
                Capsule()
                    .fill(Color.white.opacity(dragging ? 0.95 : 0.35))
                    .frame(width: dragging ? 5 : 4, height: dragging ? 48 : 36)
            }
            .overlay {
                Color.clear
                    .frame(width: 28)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
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
        if let channel = currentChannelName {
            ChatView(
                channelName: channel,
                channelId: currentChannelId,
                token: store.twitchToken,
                login: store.twitchLogin,
                chatDelay: chatDelay,
                chatOnly: $chatOnly,
                style: style,
                onJoinChannel: { target in   // raid → suit la chaîne raidée
                    playLive(target)
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
                isLive: isLivePlaying,
                dvrEnabled: isLivePlaying,
                savedTime: currentVodId.map { store.getVodProgress($0) } ?? 0,
                info: overlayInfo,
                onChannel: playerChannelLogin.map { l in { store.openChannelPage(l) } },
                sleepLabel: sleepTimer.isActive ? sleepTimer.label : nil,
                chatMode: store.landscapeChat,
                isLandscape: landscape,
                controlsInset: controlsInset,
                fillScreen: store.fillScreen,
                canReturnToLive: dvrSourceChannel != nil,
                streamStartedAt: liveStartedAt,
                archiveAvailable: liveDvrVideoId != nil,
                chapters: vodChapters,
                mutedRanges: vodMuted,
                unmutedCount: vodUnmuted,
                nowPlaying: nowPlayingMeta,
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
                onPull: { pullPlayer($0) },
                onPullEnd: { endPull($0, predicted: $1) },
                onReduce: { reducePlayer() },
                onClose:  { stopPlayer() },
                onMenu:   { showPlayerMenu = true },
                onRefresh: { reloadCurrent() },
                onToggleChat: { withAnimation { store.landscapeChat = store.landscapeChat.next } },
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
                }
            )
        } else {
            VideoPlayerView(
                qualityLinks: links,
                vodId: currentVodId,
                compact: false,  // garde qualité / rembobiner ; le bouton Chat, lui,
                                 // n'a plus lieu d'être (le chat est toujours affiché)
                nowPlaying: nowPlayingMeta,
                onTime: { vodPlaybackTime = $0 },
                onLatency: { updateLatency($0) },
                onBehind: { updateBehind($0) },
                onChat: nil,
                onRewind: rewindAction,
                onBackToLive: backToLiveAction
            )
        }
    }

    /// Bandeau au-dessus de la vidéo (mode natif) : qui regarde-t-on, et quoi.
    @ViewBuilder
    private var playerTopBar: some View {
        HStack(spacing: TSpace.sm) {
            Button { reducePlayer() } label: {
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
                    .onTapGesture { if let l = playerChannelLogin { store.openChannelPage(l) } }

                HStack(spacing: TSpace.sm) {
                    if isLivePlaying {
                        if !liveUptimeText.isEmpty {
                            TMeta(icon: "dot.radiowaves.left.and.right",
                                  text: liveUptimeText, tint: .tLive)
                        }
                        if liveViewerCount > 0 {
                            TMeta(icon: "eye.fill", text: formatViewers(liveViewerCount))
                        }
                        if store.showLatency, liveLatency > 0 {
                            TMeta(icon: "waveform.path.ecg",
                                  text: String(format: "%.0f s", liveLatency))
                        }
                    } else {
                        Text(statusTitle).font(.tMeta).foregroundColor(.tMuted).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Minuteur de veille
            Button { showSleepSheet = true } label: {
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

            TIconButton(icon: "xmark", size: 32) { stopPlayer() }
        }
        .padding(.horizontal, TSpace.md)
        .padding(.top, TSpace.sm)
        .padding(.bottom, TSpace.sm)
        .background(Color.tCard)
        .overlay(Divider().background(Color.tBorder), alignment: .bottom)
        .contentShape(Rectangle())
        .gesture(topBarPull)
        // Geste interrompu en plein glissé : le lecteur reprend sa place.
        .onChange(of: topBarDragging) { active in
            if !active, playerVisible, pull.y > 0 { pullPlayer(0) }
        }
    }

    /// Qualité en cours pour le lecteur immersif : celle choisie, sinon la meilleure.
    private func currentQuality(_ links: QualityLinks) -> String {
        if !immersiveQuality.isEmpty, links[immersiveQuality] != nil { return immersiveQuality }
        if store.preferAudioOnly, links["audio_only"] != nil { return "audio_only" }
        return sortQualities(Array(links.keys)).first ?? ""
    }

    /// Arrondi à la seconde : sinon la vue se recalculerait à chaque tick.
    private func updateLatency(_ value: Double?) {
        let rounded = (value ?? 0).rounded()
        if abs(rounded - liveLatency) >= 1 { liveLatency = rounded }
    }

    private func updateBehind(_ value: Double?) {
        let rounded = max(0, value ?? 0).rounded()
        if abs(rounded - liveBehind) >= 1 { liveBehind = rounded }
    }

    /// Réduit le lecteur en mini-barre (flèche, ou glissé vers le bas) : il
    /// file jusqu'en bas en s'effaçant, comme dans l'app Twitch. Avec
    /// « Réduire les animations », un simple fondu.
    private func reducePlayer() {
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
    /// franchement, on réduit ; sinon le lecteur revient à sa place.
    private func endPull(_ distance: CGFloat, predicted: CGFloat) {
        let threshold = PlayerPull.threshold(for: pull.height)
        if distance >= threshold || (distance > 20 && predicted >= threshold * 1.8) {
            reducePlayer()
        } else {
            pullPlayer(0)
        }
    }

    /// Le lecteur suit le doigt ; 0 = relâché trop tôt, il revient en place.
    private func pullPlayer(_ y: CGFloat) {
        if y <= 0 {
            guard pull.y != 0 else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { pull.y = 0 }
        } else {
            pull.y = y
        }
    }

    /// Bandeau du lecteur natif : le tirer vers le bas réduit le lecteur.
    /// (Sur l'image, le lecteur d'Apple garde ses propres gestes.)
    /// Repère global : le bandeau descend avec le doigt ; mesuré dans son
    /// propre repère, le déplacement se fausserait à chaque image (à-coups).
    private var topBarPull: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: CoordinateSpace.global)
            .updating($topBarDragging) { _, active, _ in active = true }
            .onChanged { v in pullPlayer(max(0, v.translation.height)) }
            .onEnded { v in
                endPull(max(0, v.translation.height), predicted: v.predictedEndTranslation.height)
            }
    }

    /// Recharge le flux courant (bouton ⟳ du lecteur).
    private func reloadCurrent() {
        guard let mode = playerMode else { return }
        logger.info("LECTEUR", "Rechargement du flux demandé", nil)
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

    // MARK: – Mini-barre (lecteur réduit)
    @ViewBuilder
    private var miniBar: some View {
        HStack(spacing: TSpace.md) {
            Image(systemName: isLivePlaying ? "dot.radiowaves.left.and.right" : "play.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(isLivePlaying ? .tLive : .tPrimary)

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
        .padding(.horizontal, TSpace.md)
        .padding(.bottom, 92)
    }

    // MARK: – Playback
    private func playVod(_ id: String, _ title: String? = nil,
                         _ thumb: String? = nil, _ streamer: String? = nil,
                         soft: Bool = false) {
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
        startPlayback(.vod(id: id, title: title, thumb: thumb, streamer: streamer), soft: soft)
    }
    private func playQueue(_ list: [VodData], _ streamer: String?) {
        guard let first = list.first else { return }
        vodQueue = list
        vodQueueStreamer = streamer
        playVod(first.id, first.title, first.previewThumbnailURL, streamer)
    }
    /// Fin d'une vidéo : la suivante de la playlist, s'il y en a une.
    private func playNextInQueue() {
        guard case .vod(let id, _, _, _) = playerMode,
              let i = vodQueue.firstIndex(where: { $0.id == id }) else { return }
        guard i + 1 < vodQueue.count else { vodQueue = []; return }
        let next = vodQueue[i + 1]
        playVod(next.id, next.title, next.previewThumbnailURL, vodQueueStreamer)
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
    private func playLive(_ channel: String, soft: Bool = false) {
        vodQueue = []
        startPlayback(.live(channelName: channel), soft: soft)
    }

    /// `soft` : on reste sur la même chaîne (direct ↔ enregistrement). Le
    /// lecteur en place continue de jouer pendant que la nouvelle source se
    /// résout, au lieu d'être démonté et remplacé par un écran d'attente.
    private func startPlayback(_ mode: PlayerMode, soft: Bool = false) {
        // Referme le clavier s'il était ouvert (recherche en cours) : sinon il
        // restait affiché par-dessus le lecteur.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        // Empêche la mise en veille pendant la lecture (utile en audio-only où
        // l'écran ne joue pas de vidéo et s'éteindrait sinon).
        UIApplication.shared.isIdleTimerDisabled = true
        playerMode    = mode
        playerVisible = true
        errorMsg      = nil
        chatOnly      = false
        vodPlaybackTime = 0
        liveDvrVideoId  = nil
        liveLatency     = 0
        liveBehind      = 0
        pull.y          = 0

        if soft {
            switchingSource = true
        } else {
            loading          = true
            qualityLinks     = nil
            // Avatar, jeu et qualité retenue ne sont vidés qu'à l'ouverture
            // d'une autre chaîne : en bascule, ils sont toujours les bons, et
            // les effacer ne ferait que les faire clignoter.
            liveAvatar       = nil
            liveGame         = ""
            immersiveQuality = ""
        }
        // Un VOD lancé depuis le bouton Rembobiner garde le lien vers sa chaîne,
        // pour pouvoir revenir au direct. Un VOD normal, non.
        if case .live = mode { dvrSourceChannel = nil }
        else { dvrSourceChannel = pendingDvrChannel }
        pendingDvrChannel = nil

        if case .live(let channel) = mode {
            currentChannelName = channel.lowercased()
            currentChannelId   = nil   // reset — sera rempli après getLive
        } else {
            currentChannelName = nil
            currentChannelId   = nil
        }

        loadGeneration += 1
        let gen = loadGeneration
        clipVodId = nil; clipOffset = 0
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
                if let err = data.error, data.links.isEmpty {
                    await MainActor.run {
                        guard gen == loadGeneration else { return }
                        errorMsg = err; loading = false; switchingSource = false
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
                    statusTitle     = rec.title.isEmpty ? store.t("recover_title") : rec.title
                    loading         = false
                    switchingSource = false
                }

            case .live(let channel):
                let data = await getLive(channelName: channel)
                if let err = data.error, err != "offline" {
                    await MainActor.run {
                        guard gen == loadGeneration else { return }
                        errorMsg = err; loading = false; switchingSource = false
                    }
                } else if let links = data.links, !links.isEmpty {
                    // Mode faible latence : playlist réécrite avec la vraie
                    // durée des segments (LivePlaylistLoader), relue toutes les
                    // 2 s au lieu de 6 — le lecteur peut tenir près du bord.
                    let playable = store.lowLatency ? LivePlaylistLoader.wrap(links) : links
                    await MainActor.run {
                        guard gen == loadGeneration else { return }
                        qualityLinks      = playable
                        statusTitle       = data.title.isEmpty ? channel : data.title
                        liveViewerCount   = data.viewerCount
                        liveStartedAt     = data.startedAt
                        currentChannelId  = data.userId   // ← userId Twitch → emotes canal
                        liveAvatar        = data.avatar
                        liveGame          = data.game
                        liveDvrVideoId    = data.dvrVideoId
                        loading           = false
                        switchingSource   = false
                        startLiveTimers(channel: channel)
                    }
                    // GQL ne rend pas toujours `profileImageURL` : repli Helix,
                    // plutôt qu'un rond gris pour le reste de la session.
                    if data.avatar == nil {
                        let fallback = await channelAvatar(login: channel.lowercased(),
                                                           token: store.twitchToken)
                        await MainActor.run { if gen == loadGeneration { liveAvatar = fallback } }
                    }
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

    private func stopPlayer() {
        UIApplication.shared.isIdleTimerDisabled = false   // ré-autorise la veille
        loadGeneration += 1   // un chargement encore en cours sera ignoré
        stopLiveTimers()
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
            liveBehind         = 0
            pull.y             = 0
            liveAvatar         = nil
            clipVodId          = nil
            liveGame           = ""
            playerMode         = nil
            qualityLinks       = nil
            statusTitle        = ""
            closingPlayer      = false
        }
    }

    // MARK: – Live timers
    private func startLiveTimers(channel: String) {
        stopLiveTimers()
        updateUptime()
        uptimeTimer  = Timer.scheduledCommon(every: 1)  { _ in updateUptime() }
        refreshTimer = Timer.scheduledCommon(every: 30) { _ in
            Task {
                // Rafraîchissement LÉGER : ne re-fetch PAS les liens du stream,
                // juste le nombre de viewers et l'uptime.
                let stats = await getStreamStats(channelName: channel)
                await MainActor.run {
                    if stats.viewerCount > 0  { liveViewerCount = stats.viewerCount }
                    if let s = stats.startedAt { liveStartedAt  = s }
                }
            }
        }
    }

    private func stopLiveTimers() {
        refreshTimer?.invalidate(); refreshTimer = nil
        uptimeTimer?.invalidate();  uptimeTimer  = nil
    }

    private func updateUptime() {
        guard let start = liveStartedAt else { return }
        let elapsed = Int(Date().timeIntervalSince(start))
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

    private var bottomInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.bottom ?? 34
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
            ForEach(MainTabView.TabName.allCases, id: \.self) { tab in
                let isActive = activeTab == tab
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { activeTab = tab }
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

/// Chaîne affichée dans la feuille « page de chaîne ».
struct ChannelSheetItem: Identifiable {
    let login: String
    var id: String { login }
}
