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
            VStack(spacing: 0) {
                HeaderView()
                    .zIndex(10)

                // Screen content
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
            .background(Color.tDark)

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
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: – Player Overlay
    @ViewBuilder
    private var playerOverlay: some View {
        ZStack(alignment: .top) {
            Color.tDark.ignoresSafeArea()
            VStack(spacing: 0) {
                // Header
                HStack(spacing: 12) {
                    Button(store.t("reduce")) { withAnimation { playerVisible = false } }
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.tPrimary)

                    Text(modeTitle)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        stopPlayer()
                    } label: {
                        Text("✕")
                            .foregroundColor(.tMuted)
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 32, height: 32)
                            .background(Color.tSurface)
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 52)
                .padding(.bottom, 12)
                .background(Color.tCard)
                .overlay(Divider().background(Color.tBorder), alignment: .bottom)

                ScrollView {
                    VStack(spacing: 16) {
                        if loading {
                            VStack(spacing: 16) {
                                ProgressView().tint(.tPrimary).scaleEffect(1.4)
                                Text(store.t("loading_vod")).foregroundColor(.tWarning).fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 60)
                        } else if let err = errorMsg {
                            VStack(spacing: 20) {
                                Text(err).foregroundColor(.tDanger).fontWeight(.semibold).multilineTextAlignment(.center)
                                Button(store.t("back")) { stopPlayer() }
                                    .foregroundColor(.white).fontWeight(.bold)
                                    .padding(.horizontal, 24).padding(.vertical, 12)
                                    .background(Color.tSurface).cornerRadius(10)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 60)
                        } else if let links = qualityLinks {
                            VideoPlayerView(
                                qualityLinks: links,
                                vodId: { if case .vod(let id, _, _, _) = playerMode { return id }; return nil }()
                            )
                            // Info box
                            infoBox
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    @ViewBuilder
    private var infoBox: some View {
        if let mode = playerMode {
            VStack(alignment: .leading, spacing: 6) {
                Text(statusTitle)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                if case .vod(_, _, _, let streamer) = mode, let s = streamer {
                    Text("par \(s)").font(.system(size: 13, weight: .semibold)).foregroundColor(.tPrimary)
                }
                if case .live = mode {
                    Text(store.t("live_badge"))
                        .font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.tLive).cornerRadius(4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.tCard)
            .cornerRadius(12)
        }
    }

    @ViewBuilder
    private var miniBar: some View {
        HStack(spacing: 12) {
            Text("\(playerMode.map { if case .live = $0 { return "🔴 " } else { return "▶️ " } }() ?? "▶️ ")\(statusTitle)")
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
        playerMode = mode
        playerVisible = true
        loading = true
        errorMsg = nil
        qualityLinks = nil

        Task {
            do {
                switch mode {
                case .vod(let id, let title, _, _):
                    let data = await getM3U8(vodId: id)
                    if let err = data.error, data.links.isEmpty {
                        await MainActor.run { errorMsg = err; loading = false }
                    } else {
                        await MainActor.run {
                            qualityLinks  = data.links
                            statusTitle   = title ?? "VOD \(id)"
                            loading       = false
                        }
                    }
                case .live(let channel):
                    let data = await getLive(channelName: channel)
                    if let err = data.error, err != "offline" {
                        await MainActor.run { errorMsg = err; loading = false }
                    } else if let links = data.links, !links.isEmpty {
                        await MainActor.run {
                            qualityLinks  = links
                            statusTitle   = data.title.isEmpty ? channel : data.title
                            loading       = false
                        }
                    } else {
                        await MainActor.run { errorMsg = "Stream indisponible"; loading = false }
                    }
                }
            }
        }
    }

    private func stopPlayer() {
        withAnimation {
            playerVisible = false
            playerMode    = nil
            qualityLinks  = nil
            statusTitle   = ""
        }
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
        .padding(.bottom, 28)
        .background(Color.tCard)
        .overlay(Divider().background(Color.tBorder), alignment: .top)
    }
}
