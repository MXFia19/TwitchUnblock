import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var store: AppStore
    @State private var activeTab: TabName = .discovery

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

    /// Décalage à appliquer au chat : la latence mesurée, si la synchro est active.
    private var chatDelay: Double {
        guard store.autoChatDelay, isLivePlaying else { return 0 }
        return max(0, min(liveLatency, 60))   // borne haute : évite un décalage absurde
    }

    enum TabName: String, CaseIterable {
        case discovery, streamer, history, direct, settings
        var icon: String {
            switch self { case .discovery: "🌟"; case .streamer: "👤"; case .history: "🕒"; case .direct: "🔗"; case .settings: "⚙️" }
        }
        func label(_ store: AppStore) -> String {
            switch self {
            case .discovery: store.t("tab_discovery")
            case .streamer:  store.t("tab_streamer")
            case .history:   store.t("tab_history")
            case .direct:    store.t("tab_direct")
            case .settings:  store.t("settings")
            }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.tDark.ignoresSafeArea()

            VStack(spacing: 0) {
                HeaderView().zIndex(10)

                Group {
                    switch activeTab {
                    case .discovery: DiscoveryView(onPlayStream: playLive, onPlayVod: playVod)
                    case .streamer:  StreamerView(onPlayVod: playVod, onPlayLive: playLive)
                    case .history:   HistoryView(onPlayVod: playVod)
                    case .direct:    DirectView(onPlayVod: playVod)
                    case .settings:  SettingsView()
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
        // Réglage rapide du minuteur depuis le lecteur.
        .sheet(isPresented: $showSleepSheet) {
            SleepTimerSheet()
                .presentationDetents([.medium])
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

                // ── Header fixe ─────────────────────────────────────
                // Espacement serré : avec le chat ouvert la barre porte déjà les
                // stats live, le minuteur, « Chat » et la croix.
                HStack(spacing: 8) {
                    Button(store.t("reduce")) { withAnimation { playerVisible = false } }
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.tPrimary)

                    // Live + chat ouvert : stats live (le nom de chaîne est déjà affiché
                    // « #chaine » dans la barre du chat). Sinon : le titre.
                    // NB : ce Group ne doit JAMAIS être vide — une EmptyView ignore
                    // .frame(maxWidth:.infinity) et la barre du header se rétracte.
                    Group {
                        if showChat, isLivePlaying {
                            headerLiveStats
                        } else {
                            Text(modeTitle)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
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

                    // Minuteur de veille : compte à rebours si armé, sinon simple accès
                    Button { showSleepSheet = true } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "moon.zzz.fill").font(.system(size: 10))
                            // Le compte à rebours n'est affiché que si la place le
                            // permet : chat ouvert, les stats live occupent la barre.
                            if sleepTimer.isActive, !showChat {
                                Text(sleepTimer.label)
                                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                            }
                        }
                        .foregroundColor(sleepTimer.isActive ? .tPurple : .tMuted)
                        .fixedSize()
                        .padding(.horizontal, 7).padding(.vertical, 5)
                        .background(sleepTimer.isActive ? Color.tPurple.opacity(0.15) : Color.tSurface)
                        .cornerRadius(6)
                    }

                    // Fermer le chat (revenir au lecteur + infos complètes)
                    if showChat {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                showChat = false
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                                Text("Chat").font(.system(size: 12, weight: .bold))
                            }
                            .foregroundColor(.tPrimary)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(Color.tPrimary.opacity(0.15))
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.tPrimary, lineWidth: 1))
                        }
                    }

                    Button { stopPlayer() } label: {
                        Text("✕")
                            .foregroundColor(.tMuted)
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 32, height: 32)
                            .background(Color.tSurface)
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 12)
                .background(Color.tCard)
                .overlay(Divider().background(Color.tBorder), alignment: .bottom)

                // ── Contenu ──────────────────────────────────────────
                if loading {
                    Spacer()
                    VStack(spacing: 16) {
                        ProgressView().tint(.tPrimary).scaleEffect(1.4)
                        Text(store.t("loading_vod"))
                            .foregroundColor(.tWarning).fontWeight(.semibold)
                    }
                    Spacer()

                } else if let err = errorMsg {
                    Spacer()
                    VStack(spacing: 20) {
                        Text(err)
                            .foregroundColor(.tDanger).fontWeight(.semibold)
                            .multilineTextAlignment(.center)
                        Button(store.t("back")) { stopPlayer() }
                            .foregroundColor(.white).fontWeight(.bold)
                            .padding(.horizontal, 24).padding(.vertical, 12)
                            .background(Color.tSurface).cornerRadius(10)
                    }
                    .padding(.horizontal, 24)
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
                    .padding(.horizontal, 12)
                    .padding(.top, 12)

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
                        .cornerRadius(12)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))

                    } else if showChat, let vid = currentVodId {
                        // ── Chat de VOD (relecture synchronisée) ─────
                        VodChatView(videoId: vid, playbackTime: vodPlaybackTime)
                            .id(vid)
                            .frame(maxHeight: .infinity)
                            .cornerRadius(12)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 12)
                            .transition(.move(edge: .bottom).combined(with: .opacity))

                    } else {
                        // ── Mode normal ──────────────────────────────
                        fullInfoBox
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
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
        HStack(spacing: 8) {
            Text(store.t("live_badge"))
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.tLive).cornerRadius(3)
                .fixedSize()

            if liveViewerCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "eye.fill").font(.system(size: 9))
                    Text(formatViewers(liveViewerCount))
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.tMuted)
                .fixedSize()
            }

            if !liveUptimeText.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "clock.fill").font(.system(size: 9))
                    Text(liveUptimeText)
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.tMuted)
                .fixedSize()
            }
        }
        .lineLimit(1)
    }

    // MARK: – Info box complète (chat fermé)
    @ViewBuilder
    private var fullInfoBox: some View {
        if let mode = playerMode {
            // Infos en haut, actions sur leur PROPRE ligne : sinon les boutons
            // compriment le titre et font passer les stats à la ligne.
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(statusTitle)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(titleExpanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                titleExpanded.toggle()
                            }
                        }

                    if case .vod(_, _, _, let streamer) = mode, let s = streamer {
                        Text("\(store.t("points_by")) \(s)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.tPrimary)
                    }

                    if case .live = mode {
                        HStack(spacing: 8) {
                            Text(store.t("live_badge"))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.tLive).cornerRadius(4)
                                .fixedSize()

                            if liveViewerCount > 0 {
                                HStack(spacing: 3) {
                                    Image(systemName: "eye.fill").font(.system(size: 10))
                                    Text(formatViewers(liveViewerCount))
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .foregroundColor(.tMuted)
                                .fixedSize()
                            }

                            if !liveUptimeText.isEmpty {
                                HStack(spacing: 3) {
                                    Image(systemName: "clock.fill").font(.system(size: 10))
                                    Text(liveUptimeText)
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .foregroundColor(.tMuted)
                                .fixedSize()
                            }
                            Spacer(minLength: 0)
                        }
                        .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            }
            .padding(16)
            .background(Color.tCard)
            .cornerRadius(12)
        }
    }

    // MARK: – Mini bar
    private var miniBarPrefix: String {
        guard let mode = playerMode else { return "▶️ " }
        if case .live = mode { return "🔴 " }
        return "▶️ "
    }

    @ViewBuilder
    private var miniBar: some View {
        HStack(spacing: 12) {
            Text(miniBarPrefix + statusTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { stopPlayer() } label: {
                Text("✕").foregroundColor(.tMuted).font(.system(size: 16, weight: .bold))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color.tCard)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.tPrimary.opacity(0.4), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 90)
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
        uptimeTimer  = Timer.scheduledTimer(withTimeInterval: 1,  repeats: true) { _ in updateUptime() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
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
        guard let mode = playerMode else { return statusTitle }
        if case .live(let ch) = mode { return "🔴 \(ch)" }
        return statusTitle
    }
}

// MARK: – Custom Tab Bar
struct CustomTabBar: View {
    @Binding var activeTab: MainTabView.TabName
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MainTabView.TabName.allCases, id: \.self) { tab in
                let isActive = activeTab == tab
                Button { activeTab = tab } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(isActive ? Color.tPrimary.opacity(0.2) : .clear)
                                .frame(width: 40, height: 32)
                            Text(tab.icon).font(.system(size: 18))
                        }
                        Text(tab.label(store))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(isActive ? .tPrimary : .tMuted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.bottom ?? 34) + 8)
        .background(Color.tCard)
        .overlay(Divider().background(Color.tBorder), alignment: .top)
    }
}
