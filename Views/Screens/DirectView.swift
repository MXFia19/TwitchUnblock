import SwiftUI

struct DirectView: View {
    let onPlayVod: (String, String?, String?, String?) -> Void

    @EnvironmentObject private var store: AppStore
    @State private var input      = ""
    @State private var loading    = false
    @State private var errorMsg:  String? = nil
    @State private var statusMsg  = ""
    @State private var qualityLinks: QualityLinks? = nil
    @State private var currentVodId: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {

                // ── Input row ───────────────────────────────────────
                HStack(spacing: 10) {
                    TextField(store.t("ph_id"), text: $input)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
                        .foregroundColor(.white)
                        .submitLabel(.go)
                        .onSubmit { Task { await unlock() } }
                        .padding(.horizontal, 12).padding(.vertical, 12)
                        .background(Color.tSurface)
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.tBorder, lineWidth: 2))

                    Button {
                        Task { await unlock() }
                    } label: {
                        Text(store.t("btn_unlock"))
                            .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                            .padding(.vertical, 12).padding(.horizontal, 18)
                            .background(loading ? Color.tMuted : Color.tPrimary)
                            .cornerRadius(10)
                    }
                    .disabled(loading)
                }

                // ── Status ──────────────────────────────────────────
                if !statusMsg.isEmpty && !loading {
                    Text(statusMsg)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(errorMsg != nil ? .tDanger : .tSuccess)
                        .lineLimit(2)
                }

                if loading {
                    ProgressView().tint(.tPrimary).scaleEffect(1.4)
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                }

                if let err = errorMsg, !loading {
                    Text(err).foregroundColor(.tDanger).fontWeight(.semibold)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }

                // ── Player ──────────────────────────────────────────
                if let links = qualityLinks, !loading {
                    VideoPlayerView(qualityLinks: links, vodId: currentVodId)
                }

                // ── VOD history ─────────────────────────────────────
                VodHistoryRowView { item in
                    Task { await loadFromHistory(item) }
                }

                Spacer(minLength: 40)
            }
            .padding(16)
        }
        .background(Color.tDark)
    }

    // MARK: – Actions
    private func unlock() async {
        guard let vodId = extractVodId(input) else {
            errorMsg = "ID invalide. Format: 12345678 ou https://twitch.tv/videos/12345678"
            return
        }
        loading = true; errorMsg = nil; qualityLinks = nil; statusMsg = store.t("loading_vod")

        async let metaTask = getVodMetaGQL(vodId)
        async let m3u8Task = getM3U8(vodId: vodId)
        let (meta, m3u8) = await (metaTask, m3u8Task)

        if let err = m3u8.error, m3u8.links.isEmpty {
            errorMsg = err; statusMsg = ""; loading = false; return
        }

        let item = HistoryItem(
            term: vodId, type: .vod,
            display: meta?.title ?? "VOD \(vodId)",
            thumb: meta?.thumb, streamer: meta?.streamer,
            addedAt: Date().timeIntervalSince1970 * 1000
        )
        store.saveToHistory(item)
        currentVodId = vodId
        qualityLinks = m3u8.links
        statusMsg    = meta?.title ?? store.t("vod_ready")
        loading      = false
    }

    private func loadFromHistory(_ item: HistoryItem) async {
        let vodId = extractVodId(item.term) ?? item.term
        input = item.term; loading = true; errorMsg = nil
        qualityLinks = nil; statusMsg = store.t("loading_vod")
        let m3u8 = await getM3U8(vodId: vodId)
        if let err = m3u8.error, m3u8.links.isEmpty {
            errorMsg = err; loading = false; return
        }
        currentVodId = vodId
        qualityLinks = m3u8.links
        statusMsg    = item.display
        loading      = false
    }
}
