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

    // ── Chat state ───────────────────────────────────────────────────────
    @State private var showChat = false
    @State private var currentChannelName: String? = nil
    @State private var currentChannelId: String? = nil

    // ── Live stats ────────────────────────────────────────────────────────
    @State private var liveViewerCount: Int = 0
    @State private var liveStartedAt: Date? = nil
    @State private var liveUptimeText: String = ""
    @State private var refreshTimer: Timer? = nil
    @State private var uptimeTimer: Timer? = nil

    enum TabName: String, CaseIterable {
        case discovery, streamer, direct, settings
        var icon: String {
            switch self { case .discovery: "🌟"; case .streamer: "👤"; case .direct: "🔗"; case .settings: "⚙️" }
        }
        func label(_ store: AppStore) -> String {
            switch self {
            case .discovery: store.t("tab_discovery")
            case .streamer:  store.t("tab_streamer")
            case .direct:    store.t("tab_direct")
            case .settings:  store.t("settings")
            }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.tDark.ignoresSafeArea()

            VStack(spacing: 0) {
                HeaderView()
                    .zIndex(10)

                Group {
                    switch activeTab {
                    case .discovery:
                        DiscoveryView(onPlayStream: playLive, onPlayVod: playVod)
                    case .streamer:
                        StreamerView(onPlayVod: playVod, onPlayLive: playLive)
                    case .direct:
                        DirectView(onPlayVod: playVod)
                    case .settings:
                        SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                CustomTabBar(activeTab: $activeTab)
            }
            .ignoresSafeArea()

            // ── Mini bar (player réduit) ──────────────────────────────
            if playerMode != nil && !playerVisible && qualityLinks != nil {
                miniBar
                    .zIndex(99)
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
    }

    // MARK: – Player Overlay
    @ViewBuilder
    private var playerOverlay: some View {
        ZStack(alignment: .top) {
            Color.tDark.ignoresSafeArea()
            VStack(spacing: 0) {
                // ── Header ──────────────────────────────────────────────
                HStack(spacing: 12) {
                    Button(store.t("reduce")) { withAnimation { playerVisible = false } }
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.tPrimary)

                    Text(modeTitle)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

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
                // ✅ FIX : le ZStack place déjà la VStack sous la safe area —
                //    52pt était une sur-compensation qui créait le vide noir.
                //    6pt suffit comme marge visuelle.
                .padding(.top, 6)
                .padding(.bottom, 12)
                .background(Color.tCard)
                .overlay(Divider().background(Color.tBorder), alignment: .bottom)

                // ── Contenu scrollable ───────────────────────────────────
                ScrollView {
                    VStack(spacing: 16) {
                        if loading {
                            VStack(spacing: 16) {
                                ProgressView().tint(.tPrimary).scaleEffect(1.4)
                                Text(store.t("loading_vod"))
                                    .foregroundColor(.tWarning)
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 60)

                        } else if let err = errorMsg {
                            VStack(spacing: 20) {
                                Text(err)
                                    .foregroundColor(.tDanger)
                                    .fontWeight(.semibold)
                                    .multilineTextAlignment(.center)
                                Button(store.t("back")) { stopPlayer() }
                                    .foregroundColor(.white).fontWeight(.bold)
                                    .padding(.horizontal, 24).padding(.vertical, 12)
                                    .background(Color.tSurface).cornerRadius(10)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 60)

                        } else if let links = qualityLinks {
                            VideoPlayerView(
                                qualityLinks: links,
                                vodId: {
                                    if case .vod(let id, _, _, _) = playerMode { return id }
                                    return nil
                                }()
                            )
                            infoBox
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    // MARK: – Info box
    @ViewBuilder
    private var infoBox: some View {
        if let mode = playerMode {
            VStack(alignment: .leading, spacing: 0) {

                // ── Info row ─────────────────────────────────────────
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(statusTitle)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                        if case .vod(_, _, _, let streamer) = mode, let s = streamer {
                            Text("par \(s)")
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

                                if liveViewerCount > 0 {
                                    HStack(spacing: 3) {
                                        Image(systemName: "eye.fill").font(.system(size: 10))
                                        Text(formatViewers(liveViewerCount))
                                            .font(.system(size: 12, weight: .semibold))
                                    }
                                    .foregroundColor(.tMuted)
                                }

                                if !liveUptimeText.isEmpty {
                                    HStack(spacing: 3) {
                                        Image(systemName: "clock.fill").font(.system(size: 10))
                                        Text(liveUptimeText)
                                            .font(.system(size: 12, weight: .semibold))
                                    }
                                    .foregroundColor(.tMuted)
                                }
                            }
                        }
                    }
                    Spacer()

                    // Bouton Chat (live uniquement)
                    if case .live = mode, let channel = currentChannelName {
                        Button {
                            withAnimation(.spring(response: 0.35)) { showChat.toggle() }
                            logger.info("CHAT", showChat ? "Chat ouvert" : "Chat fermé", channel)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: showChat ? "bubble.left.fill" : "bubble.left")
                                Text("Chat").font(.system(size: 13, weight: .bold))
                            }
                            .foregroundColor(showChat ? .white : .tPrimary)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(showChat ? Color.tPrimary : Color.tPrimary.opacity(0.15))
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.tPrimary, lineWidth: 1))
                        }
                    }
                }
                .padding(16)
                .background(Color.tCard)
                .cornerRadius(12)

                // ── Chat panel ───────────────────────────────────────
                if showChat, let channel = currentChannelName {
                    ChatView(
                        channelName: channel,
                        channelId: currentChannelId,
                        token: store.twitchToken,
                        login: store.twitchLogin
                    )
                    .frame(height: store.twitchLogin != nil ? 400 : 340)
                    .cornerRadius(12)
                    .padding(.top, 8)
                }
            }
        }
    }

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
    private func playVod(_ id: String, _ title: String? = nil, _ thumb: String? = nil, _ streamer: String? = nil) {
        startPlayback(.vod(id: id, title: title, thumb: thumb, streamer: streamer))
    }
    private func playLive(_ channel: String) {
        startPlayback(.live(channelName: channel))
    }

    private func startPlayback(_ mode: PlayerMode) {
        playerMode    = mode
        playerVisible = true
        loading       = true
        errorMsg      = nil
        qualityLinks  = nil
        showChat      = false

        if case .live(let channel) = mode {
            currentChannelName = channel.lowercased()
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
                    await MainActor.run { errorMsg = err; loading = false }
                } else if let links = data.links, !links.isEmpty {
                    await MainActor.run {
                        qualityLinks    = links
                        statusTitle     = data.title.isEmpty ? channel : data.title
                        liveViewerCount = data.viewerCount
                        liveStartedAt   = data.startedAt
                        loading         = false
                        startLiveTimers(channel: channel)
                    }
                } else {
                    await MainActor.run { errorMsg = "Stream indisponible"; loading = false }
                }
            }
        }
    }

    private func stopPlayer() {
        stopLiveTimers()
        showChat           = false
        currentChannelName = nil
        currentChannelId   = nil
        liveViewerCount    = 0
        liveStartedAt      = nil
        liveUptimeText     = ""
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
        uptimeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in updateUptime() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task {
                let data = await getLive(channelName: channel)
                await MainActor.run {
                    if data.viewerCount > 0 { liveViewerCount = data.viewerCount }
                    if let s = data.startedAt { liveStartedAt = s }
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
