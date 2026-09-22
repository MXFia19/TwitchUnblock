import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var store: AppStore
    @State private var activeTab: TabName = .home

    // ── Player state ─────────────────────────────────────────────────────
    @State private var playerMode: PlayerMode? = nil
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
    /// Latence mesurée du direct, arrondie à la seconde (synchro auto du chat).
    @State private var liveLatency: Double = 0

    // ── Minuteur de veille ────────────────────────────────────────────────
    @ObservedObject private var sleepTimer = SleepTimerService.shared
    @State private var showSleepSheet  = false
    @State private var showSettings    = false
    @State private var showPlayerMenu  = false
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

    /// Décalage à appliquer au chat : la latence mesurée, si la synchro est active.
    private var chatDelay: Double {
        guard store.autoChatDelay, isLivePlaying else { return 0 }
        return max(0, min(liveLatency, 60))   // borne haute : évite un décalage absurde
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
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.tDark.ignoresSafeArea()

            VStack(spacing: 0) {
                HeaderView(title: activeTab.label(store)) { showSettings = true }
                    .zIndex(10)

                Group {
                    switch activeTab {
                    // Les fermetures sont explicites : Swift n'applique pas les
                    // valeurs par défaut (`soft:`) quand une méthode est passée
                    // comme valeur, donc `playLive` vaudrait ici
                    // `(String, Bool) -> Void` et ne collerait pas au callback.
                    case .home:    HomeView(onPlayStream: { playLive($0) })
                    case .search:  SearchView(onPlayVod: { playVod($0, $1, $2, $3) },
                                              onPlayLive: { playLive($0) })
                    case .library: LibraryView(onPlayVod: { playVod($0, $1, $2, $3) })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                CustomTabBar(activeTab: $activeTab)
            }
            .ignoresSafeArea()

            // ── Mini bar ──────────────────────────────────────────────
            // `!closingPlayer` : sans lui, la mini-barre apparaîtrait le temps du
            // fondu de fermeture, le lecteur étant encore en place mais masqué.
            if playerMode != nil && !playerVisible && qualityLinks != nil && !closingPlayer {
                miniBar.zIndex(99)
            }

            // ── Player overlay ────────────────────────────────────────
            if playerMode != nil {
                playerOverlay
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
                onSelectQuality: { q in immersiveQuality = q; showPlayerMenu = false },
                onRewind: { showPlayerMenu = false; rewindAction?() },
                onBackToLive: { showPlayerMenu = false; backToLiveAction?() },
                onSleepTimer: { showPlayerMenu = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                    showSleepSheet = true } },
                onSettings: { showPlayerMenu = false
                              DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                  showSettings = true } }
            )
            .presentationDetents([.medium])
        }
        // Réglages : ouverts depuis l'avatar de l'en-tête.
        .sheet(isPresented: $showSettings) {
            SettingsView()
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
                sleepLabel: sleepTimer.isActive ? sleepTimer.label : nil,
                chatMode: store.landscapeChat,
                isLandscape: landscape,
                controlsInset: controlsInset,
                fillScreen: store.fillScreen,
                canReturnToLive: dvrSourceChannel != nil,
                streamStartedAt: liveStartedAt,
                archiveAvailable: liveDvrVideoId != nil,
                onProgress: { time in
                    vodPlaybackTime = time
                    if let id = currentVodId { store.setVodProgress(id, time: time) }
                },
                onLatency: { updateLatency($0) },
                onReduce: { withAnimation { playerVisible = false } },
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
                onTime: { vodPlaybackTime = $0 },
                onLatency: { updateLatency($0) },
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
            Button { withAnimation { playerVisible = false } } label: {
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
    }

    /// Qualité en cours pour le lecteur immersif : celle choisie, sinon la meilleure.
    private func currentQuality(_ links: QualityLinks) -> String {
        if !immersiveQuality.isEmpty, links[immersiveQuality] != nil { return immersiveQuality }
        return sortQualities(Array(links.keys)).first ?? ""
    }

    /// Arrondi à la seconde : sinon la vue se recalculerait à chaque tick.
    private func updateLatency(_ value: Double?) {
        let rounded = (value ?? 0).rounded()
        if abs(rounded - liveLatency) >= 1 { liveLatency = rounded }
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
        .background(Color.tCard)
        .cornerRadius(TRadius.card)
        .overlay(RoundedRectangle(cornerRadius: TRadius.card)
            .stroke(Color.tPrimary.opacity(0.4), lineWidth: 1))
        .padding(.horizontal, TSpace.md)
        .padding(.bottom, 92)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { playerVisible = true } }
    }

    // MARK: – Playback
    private func playVod(_ id: String, _ title: String? = nil,
                         _ thumb: String? = nil, _ streamer: String? = nil,
                         soft: Bool = false) {
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
    private func playLive(_ channel: String, soft: Bool = false) {
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

        Task {
            switch mode {
            case .vod(let id, let title, _, let streamer):
                // Le bandeau du lecteur montrait un rond gris sur les VODs :
                // `getM3U8` ne ramène aucune photo de profil. On la demande à
                // part, depuis le nom de chaîne que tous les points d'entrée
                // transmettent déjà.
                if let who = streamer, !who.isEmpty {
                    Task { @MainActor in
                        liveAvatar = await channelAvatar(login: who.lowercased(),
                                                         token: store.twitchToken)
                    }
                }
                let data = await getM3U8(vodId: id)
                if let err = data.error, data.links.isEmpty {
                    await MainActor.run {
                        errorMsg = err; loading = false; switchingSource = false
                    }
                } else {
                    await MainActor.run {
                        qualityLinks    = data.links
                        statusTitle     = title ?? "VOD \(id)"
                        loading         = false
                        switchingSource = false
                    }
                }

            case .live(let channel):
                let data = await getLive(channelName: channel)
                if let err = data.error, err != "offline" {
                    await MainActor.run {
                        errorMsg = err; loading = false; switchingSource = false
                    }
                } else if let links = data.links, !links.isEmpty {
                    await MainActor.run {
                        qualityLinks      = links
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
                        await MainActor.run { liveAvatar = fallback }
                    }
                } else {
                    await MainActor.run {
                        errorMsg = store.t("offline_msg")
                        loading = false; switchingSource = false
                    }
                }
            }
        }
    }

    private func stopPlayer() {
        UIApplication.shared.isIdleTimerDisabled = false   // ré-autorise la veille
        stopLiveTimers()

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
            liveAvatar         = nil
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
    @EnvironmentObject private var store: AppStore

    private var bottomInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.bottom ?? 34
    }

    var body: some View {
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
            }
        }
        .padding(.top, 10)
        .padding(.bottom, bottomInset + 6)
        .background(.ultraThinMaterial)
        .overlay(Divider().background(Color.tBorder), alignment: .top)
    }
}
