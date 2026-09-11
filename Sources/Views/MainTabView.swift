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
    /// Titre déplié : un titre long est tronqué, on le déplie au toucher.
    @State private var titleExpanded = false

    // ── Chat state ───────────────────────────────────────────────────────
    @State private var showChat = false
    @State private var keepChatOnLoad = false   // raid → rouvrir le chat sur la chaîne raidée
    @State private var vodPlaybackTime: Double = 0   // pilote le chat des VODs
    // ── DVR (rembobiner un live) ─────────────────────────────────────────
    @State private var liveDvrVideoId: String? = nil    // VOD en cours du live regardé
    @State private var pendingDvrChannel: String? = nil // passe le relais à startPlayback
    @State private var dvrSourceChannel: String? = nil  // on regarde le DVR de cette chaîne
    @State private var currentChannelName: String? = nil
    @State private var currentChannelId: String? = nil   // ← branché sur data.userId

    // ── Live stats ────────────────────────────────────────────────────────
    @State private var liveViewerCount: Int = 0
    @State private var liveStartedAt: Date? = nil
    @State private var liveUptimeText: String = ""
    @State private var refreshTimer: Timer? = nil
    @State private var uptimeTimer: Timer? = nil

    // ── Débogage / synchro ────────────────────────────────────────────────
    /// Latence mesurée du direct, arrondie à la seconde (synchro auto du chat).
    @State private var liveLatency: Double = 0

    // ── Minuteur de veille ────────────────────────────────────────────────
    @ObservedObject private var sleepTimer = SleepTimerService.shared
    @State private var showSleepSheet = false
    @State private var showSettings   = false

    /// Décalage à appliquer au chat : la latence mesurée, si la synchro est active.
    private var chatDelay: Double {
        guard store.autoChatDelay, isLivePlaying else { return 0 }
        return max(0, min(liveLatency, 60))   // borne haute : évite un décalage absurde
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
                    case .home:    HomeView(onPlayStream: playLive)
                    case .search:  SearchView(onPlayVod: playVod, onPlayLive: playLive)
                    case .library: LibraryView(onPlayVod: playVod)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                CustomTabBar(activeTab: $activeTab)
            }
            .ignoresSafeArea()

            // ── Mini bar ──────────────────────────────────────────────
            if playerMode != nil && !playerVisible && qualityLinks != nil {
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
        // Réglages : ouverts depuis l'avatar de l'en-tête.
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        // Réglage rapide du minuteur depuis le lecteur.
        .sheet(isPresented: $showSleepSheet) {
            SleepTimerSheet()
                .presentationDetents([.medium, .large])
        }
        // Minuteur de veille écoulé → on coupe la lecture.
        .onChange(of: sleepTimer.fireCount) { _ in
            guard playerMode != nil else { return }
            logger.info("SLEEP", "Arrêt du lecteur par le minuteur de veille", nil)
            stopPlayer()
        }
    }

    // MARK: – Player Overlay (non scrollable)
    @ViewBuilder
    private var playerOverlay: some View {
        ZStack(alignment: .top) {
            Color.tDark.ignoresSafeArea()

            VStack(spacing: 0) {

                // ── Barre du lecteur ────────────────────────────────
                HStack(spacing: TSpace.sm) {
                    Button { withAnimation { playerVisible = false } } label: {
                        HStack(spacing: TSpace.xs) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12, weight: .bold))
                            Text(store.t("reduce")).font(.tLabel)
                        }
                        .foregroundColor(.tPrimary)
                    }
                    .buttonStyle(.plain)

                    // Chat ouvert : stats du direct (le nom de chaîne est déjà
                    // dans la barre du chat). Sinon : le titre, dépliable au toucher.
                    // Ce Group ne doit jamais être vide — une EmptyView ignore
                    // .frame(maxWidth:.infinity) et la barre se rétracte.
                    Group {
                        if showChat, isLivePlaying {
                            headerLiveStats
                        } else {
                            Text(modeTitle)
                                .font(.tCardTitle)
                                .foregroundColor(.tText)
                                .lineLimit(titleExpanded ? nil : 1)
                                .fixedSize(horizontal: false, vertical: true)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        titleExpanded.toggle()
                                    }
                                }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Minuteur de veille : compte à rebours si armé, sinon accès simple.
                    Button { showSleepSheet = true } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "moon.zzz.fill").font(.system(size: 11))
                            // Le compte à rebours n'est affiché que s'il reste de la
                            // place : chat ouvert, les stats occupent la barre.
                            if sleepTimer.isActive, !showChat {
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

                    if showChat {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                showChat = false
                            }
                        } label: {
                            Image(systemName: "bubble.left.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, TSpace.sm)
                                .frame(height: 32)
                                .background(Color.tPrimary)
                                .cornerRadius(TRadius.chip)
                        }
                        .buttonStyle(.plain)
                    }

                    TIconButton(icon: "xmark", size: 32) { stopPlayer() }
                }
                .padding(.horizontal, TSpace.lg)
                .padding(.top, TSpace.sm)
                .padding(.bottom, TSpace.md)
                .background(Color.tCard)
                .overlay(Divider().background(Color.tBorder), alignment: .bottom)

                // ── Contenu ──────────────────────────────────────────
                if loading {
                    Spacer()
                    VStack(spacing: TSpace.md) {
                        ProgressView().tint(.tPrimary).scaleEffect(1.3)
                        Text(store.t("loading_vod"))
                            .font(.tCardTitle).foregroundColor(.tMuted)
                    }
                    Spacer()

                } else if let err = errorMsg {
                    Spacer()
                    TEmptyState(icon: "exclamationmark.triangle", title: err,
                                actionTitle: store.t("back"), action: { stopPlayer() })
                    Spacer()

                } else if let links = qualityLinks {

                    // Vidéo fixe 16:9
                    VideoPlayerView(
                        qualityLinks: links,
                        vodId: {
                            if case .vod(let id, _, _, _) = playerMode { return id }
                            return nil
                        }(),
                        compact: showChat,  // chat ouvert → masque Source/lien, place au chat
                        onTime: { vodPlaybackTime = $0 },
                        onLatency: { value in
                            // Arrondi à la seconde : sinon la vue se recalculerait
                            // à chaque tick de l'observateur (1 s) pour rien.
                            let rounded = (value ?? 0).rounded()
                            if abs(rounded - liveLatency) >= 1 { liveLatency = rounded }
                        },
                        onChat: chatAction,
                        onRewind: rewindAction,
                        onBackToLive: backToLiveAction
                    )
                    .padding(.horizontal, TSpace.md)
                    .padding(.top, TSpace.md)

                    if showChat, let channel = currentChannelName {
                        // ── Mode chat ouvert ─────────────────────────
                        // (les stats live sont remontées dans le header pour laisser
                        //  un maximum de place au chat)
                        ChatView(
                            channelName: channel,
                            channelId: currentChannelId,   // ← userId Twitch du canal
                            token: store.twitchToken,
                            login: store.twitchLogin,
                            chatDelay: chatDelay,
                            onJoinChannel: { target in    // raid → suit la chaîne raidée
                                keepChatOnLoad = true
                                playLive(target)
                            }
                        )
                        .id(channel)   // change de chaîne (raid) → ChatView reconstruit à neuf
                        .frame(maxHeight: .infinity)
                        .cornerRadius(TRadius.card)
                        .padding(.horizontal, TSpace.md)
                        .padding(.bottom, TSpace.md)
                        .transition(.move(edge: .bottom).combined(with: .opacity))

                    } else if showChat, let vid = currentVodId {
                        // ── Chat de VOD (relecture synchronisée) ─────
                        VodChatView(videoId: vid, playbackTime: vodPlaybackTime)
                            .id(vid)
                            .frame(maxHeight: .infinity)
                            .cornerRadius(TRadius.card)
                            .padding(.horizontal, TSpace.md)
                            .padding(.bottom, TSpace.md)
                            .transition(.move(edge: .bottom).combined(with: .opacity))

                    } else {
                        // ── Mode normal ──────────────────────────────
                        fullInfoBox
                            .padding(.horizontal, TSpace.md)
                            .padding(.top, TSpace.md)
                            .transition(.opacity)

                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: – Actions du lecteur (nil ⇒ bouton masqué)
    private var chatAction: (() -> Void)? {
        guard currentChannelName != nil || currentVodId != nil else { return nil }
        return {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showChat = true }
        }
    }

    /// Rembobiner un live : lit le VOD en cours d'enregistrement.
    private var rewindAction: (() -> Void)? {
        guard let ch = currentChannelName, let dvr = liveDvrVideoId else { return nil }
        return {
            pendingDvrChannel = ch
            playVod(dvr, statusTitle, nil, ch)
        }
    }

    private var backToLiveAction: (() -> Void)? {
        guard let ch = dvrSourceChannel else { return nil }
        return { playLive(ch) }
    }

    /// Identifiant de la VOD en cours de lecture (nil en live).
    private var currentVodId: String? {
        if case .vod(let id, _, _, _) = playerMode { return id }
        return nil
    }

    // MARK: – Stats live (remontées dans le header quand le chat est ouvert)
    private var isLivePlaying: Bool {
        guard let mode = playerMode else { return false }
        if case .live = mode { return true }
        return false
    }

    @ViewBuilder
    private var headerLiveStats: some View {
        HStack(spacing: TSpace.sm) {
            TLiveBadge(compact: true)
            if liveViewerCount > 0 {
                TMeta(icon: "eye.fill", text: formatViewers(liveViewerCount))
            }
            if !liveUptimeText.isEmpty {
                TMeta(icon: "clock.fill", text: liveUptimeText)
            }
        }
        .lineLimit(1)
    }

    // MARK: – Encart d'infos (chat fermé)
    @ViewBuilder
    private var fullInfoBox: some View {
        if let mode = playerMode {
            VStack(alignment: .leading, spacing: TSpace.sm) {
                Text(statusTitle)
                    .font(.tSection)
                    .foregroundColor(.tText)
                    .lineLimit(titleExpanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) { titleExpanded.toggle() }
                    }

                if case .vod(_, _, _, let streamer) = mode, let s = streamer {
                    Text(s)
                        .font(.tCardTitle)
                        .foregroundColor(.tPurple)
                }

                if case .live = mode {
                    HStack(spacing: TSpace.md) {
                        TLiveBadge()
                        if liveViewerCount > 0 {
                            TMeta(icon: "eye.fill", text: formatViewers(liveViewerCount))
                        }
                        if !liveUptimeText.isEmpty {
                            TMeta(icon: "clock.fill", text: liveUptimeText)
                        }
                        Spacer(minLength: 0)
                    }
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tCard()
        }
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
                         _ thumb: String? = nil, _ streamer: String? = nil) {
        // Historique des VODs vues : centralisé ici pour couvrir TOUS les points
        // d'entrée (Découverte, Streamer, Lien/ID, rembobinage…). Avant, seul
        // l'onglet Lien/ID enregistrait, donc l'onglet VODs restait vide.
        store.saveToHistory(HistoryItem(
            term: id, type: .vod,
            display: title ?? "VOD \(id)",
            thumb: thumb, streamer: streamer,
            addedAt: Date().timeIntervalSince1970 * 1000
        ))
        startPlayback(.vod(id: id, title: title, thumb: thumb, streamer: streamer))
    }
    private func playLive(_ channel: String) {
        startPlayback(.live(channelName: channel))
    }

    private func startPlayback(_ mode: PlayerMode) {
        // Referme le clavier s'il était ouvert (recherche en cours) : sinon il
        // restait affiché par-dessus le lecteur.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        // Empêche la mise en veille pendant la lecture (utile en audio-only où
        // l'écran ne joue pas de vidéo et s'éteindrait sinon).
        UIApplication.shared.isIdleTimerDisabled = true
        playerMode    = mode
        playerVisible = true
        loading       = true
        errorMsg      = nil
        qualityLinks  = nil
        showChat      = false
        vodPlaybackTime = 0
        titleExpanded   = false
        liveDvrVideoId  = nil
        liveLatency     = 0
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
            case .vod(let id, let title, _, _):
                let data = await getM3U8(vodId: id)
                if let err = data.error, data.links.isEmpty {
                    await MainActor.run { errorMsg = err; loading = false }
                } else {
                    await MainActor.run {
                        qualityLinks = data.links
                        statusTitle  = title ?? "VOD \(id)"
                        loading      = false
                    }
                }

            case .live(let channel):
                let data = await getLive(channelName: channel)
                if let err = data.error, err != "offline" {
                    await MainActor.run { errorMsg = err; loading = false; keepChatOnLoad = false }
                } else if let links = data.links, !links.isEmpty {
                    await MainActor.run {
                        qualityLinks      = links
                        statusTitle       = data.title.isEmpty ? channel : data.title
                        liveViewerCount   = data.viewerCount
                        liveStartedAt     = data.startedAt
                        currentChannelId  = data.userId   // ← userId Twitch → emotes canal
                        liveDvrVideoId    = data.dvrVideoId
                        loading           = false
                        if keepChatOnLoad { showChat = true; keepChatOnLoad = false }
                        startLiveTimers(channel: channel)
                    }
                } else {
                    await MainActor.run { errorMsg = store.t("offline_msg"); loading = false; keepChatOnLoad = false }
                }
            }
        }
    }

    private func stopPlayer() {
        UIApplication.shared.isIdleTimerDisabled = false   // ré-autorise la veille
        stopLiveTimers()
        showChat           = false
        currentChannelName = nil
        currentChannelId   = nil
        liveDvrVideoId     = nil
        dvrSourceChannel   = nil
        pendingDvrChannel  = nil
        liveViewerCount    = 0
        liveStartedAt      = nil
        liveUptimeText     = ""
        liveLatency        = 0
        withAnimation {
            playerVisible = false
            playerMode    = nil
            qualityLinks  = nil
            statusTitle   = ""
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
