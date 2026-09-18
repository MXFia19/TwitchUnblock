import SwiftUI

// MARK: – Chat de VOD (lecture seule, synchronisé à la position de lecture)
struct VodChatView: View {
    let videoId: String
    /// Position de lecture (secondes) fournie par le lecteur.
    let playbackTime: Double

    @EnvironmentObject private var store: AppStore
    @StateObject private var vod = VodChatService()

    @State private var autoScroll      = true
    @State private var sentinelVisible = true
    @State private var isDragging      = false

    private let bottomAnchor = "vod_chat_bottom"

    var body: some View {
        VStack(spacing: 0) {

            // ── Barre de statut ─────────────────────────────────────
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.tPurple)
                Text(store.t("vod_chat"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.tMuted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(VodChatService.formatOffset(playbackTime))
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundColor(.tPurple)
                    .lineLimit(1).fixedSize()
                if !vod.channelLogin.isEmpty {
                    Text("#\(vod.channelLogin)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.tPrimary)
                        .lineLimit(1).fixedSize()
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.tCard)
            .overlay(Divider().background(Color.tBorder), alignment: .bottom)

            // ── Messages ────────────────────────────────────────────
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottomTrailing) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(vod.messages.reversed()) { msg in
                                    ChatMessageRow(message: msg, availableWidth: geo.size.width)
                                        .id(msg.id)
                                }
                                Color.clear
                                    .frame(height: 1)
                                    .id(bottomAnchor)
                                    .onAppear    { sentinelVisible = true; autoScroll = true }
                                    .onDisappear { sentinelVisible = false }
                            }
                            .frame(width: geo.size.width, alignment: .leading)
                            .padding(.vertical, 4)
                        }
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 10)
                                .onChanged { _ in
                                    isDragging = true
                                    if !sentinelVisible { autoScroll = false }
                                }
                                .onEnded { _ in isDragging = false }
                        )
                        .onChange(of: vod.messages.first?.id) { _ in
                            guard autoScroll, !isDragging else { return }
                            proxy.scrollTo(bottomAnchor, anchor: .bottom)
                        }

                        // État vide / chargement
                        if vod.messages.isEmpty {
                            VStack(spacing: 8) {
                                if vod.isLoading || !vod.ready {
                                    ProgressView().tint(.tPrimary)
                                    Text(store.t("vod_chat_loading"))
                                        .font(.system(size: 12)).foregroundColor(.tMuted)
                                } else if let err = vod.errorMsg {
                                    Image(systemName: "exclamationmark.triangle")
                                        .font(.system(size: 26)).foregroundColor(.tDanger)
                                    Text(err)
                                        .font(.system(size: 11)).foregroundColor(.tDanger)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 20)
                                } else {
                                    Image(systemName: "bubble.left.and.bubble.right")
                                        .font(.system(size: 26)).foregroundColor(.tMuted)
                                    Text(store.t("vod_chat_empty"))
                                        .font(.system(size: 12)).foregroundColor(.tMuted)
                                        .multilineTextAlignment(.center)
                                }
                            }
                            .frame(width: geo.size.width, height: geo.size.height)
                        }

                        if !autoScroll {
                            Button {
                                autoScroll = true
                                proxy.scrollTo(bottomAnchor, anchor: .bottom)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.down")
                                    Text(store.t("chat_follow"))
                                        .font(.system(size: 11, weight: .bold))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.tPrimary)
                                .cornerRadius(20)
                            }
                            .padding(10)
                        }
                    }
                }
            }
        }
        .background(Color.tDark)
        .task(id: videoId) { await vod.start(videoId: videoId) }
        // La position de lecture pilote la libération des messages.
        .onChange(of: playbackTime) { t in
            Task { await vod.update(offset: t) }
        }
        .onChange(of: vod.ready) { ready in
            guard ready else { return }
            Task { await vod.update(offset: playbackTime) }
        }
        .onDisappear { vod.stop() }
    }
}
