import SwiftUI

struct StreamerView: View {
    let onPlayVod:  (String, String?, String?, String?) -> Void
    let onPlayLive: (String) -> Void

    @EnvironmentObject private var store: AppStore

    @State private var channelInput  = ""
    @State private var keywordInput  = ""
    @State private var loading       = false
    @State private var liveData:   LiveData? = nil
    @State private var vods:       [VodData] = []
    @State private var avatarURL   = ""
    @State private var errorMsg:   String? = nil
    @State private var searched    = false

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    private var filteredVods: [VodData] {
        guard !keywordInput.trimmingCharacters(in: .whitespaces).isEmpty else { return vods }
        let kw = keywordInput.lowercased()
        return vods.filter { $0.title.lowercased().contains(kw) }
    }

    private var offlineSinceText: String? {
        guard liveData?.error != nil, let first = vods.first else { return nil }
        return getTimeSince(publishedAt: first.publishedAt, lengthSeconds: first.lengthSeconds, store: store)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                   // ── Search bar ──────────────────────────────────────
                VStack(spacing: 8) {
                    // ✨ L'ajout de alignment: .top est ici :
                    HStack(alignment: .top, spacing: 10) { 
                        AutocompleteInputView(
                            text: $channelInput,
                            placeholder: store.t("ph_streamer"),
                            onSubmit: { Task { await search() } }
                        )

                        Button { Task { await search() } } label: {
                            Text("🔍")
                                .font(.system(size: 20))
                                .frame(width: 48, height: 48)
                                .background(Color.tPrimary)
                                .cornerRadius(10)
                        }
                    }

                    if !vods.isEmpty {
                        TextField(store.t("ph_keyword"), text: $keywordInput)
                            .autocorrectionDisabled()
                            .foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(Color.tSurface)
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.tBorder, lineWidth: 2))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .zIndex(100)

                // ── Channel history ─────────────────────────────────
                ChannelHistoryTagsView { name in
                    channelInput = name
                    Task { await search(name) }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                // ── Loading / Error ─────────────────────────────────
                if loading {
                    ProgressView().tint(.tPrimary).scaleEffect(1.4)
                        .frame(maxWidth: .infinity).padding(.vertical, 32)
                } else if let err = errorMsg {
                    Text(err).foregroundColor(.tDanger).fontWeight(.semibold)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                }

                // ── Results ─────────────────────────────────────────
                if !loading && searched {
                    if let live = liveData {
                        LiveCardView(
                            isOnline: live.error == nil,
                            title: live.error != nil ? store.t("offline_msg") : live.title,
                            game: live.game,
                            avatarURL: avatarURL,
                            thumbnailURL: live.thumbnail,
                            offlineSince: offlineSinceText,
                            onWatchLive: live.error == nil
                                ? { onPlayLive(channelInput.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "") }
                                : nil
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    }

                    if filteredVods.isEmpty && !vods.isEmpty {
                        Text("Aucune VOD pour \"\(keywordInput)\"")
                            .foregroundColor(.tMuted).frame(maxWidth: .infinity).padding(.vertical, 16)
                    } else if filteredVods.isEmpty && vods.isEmpty && errorMsg == nil {
                        Text(store.t("no_vod")).foregroundColor(.tMuted)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                    } else if !filteredVods.isEmpty {
                        Text(keywordInput.isEmpty ? "\(vods.count) \(store.t("vods_found"))" : "\(filteredVods.count) résultat(s)")
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(.tSuccess)
                            .padding(.horizontal, 16).padding(.top, 8)

                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(filteredVods) { vod in
                                let saved    = store.getVodProgress(vod.id)
                                let progress = vod.lengthSeconds > 0 ? saved / Double(vod.lengthSeconds) : 0
                                VodCardView(vod: vod, progress: progress) {
                                    onPlayVod(vod.id, vod.title, vod.previewThumbnailURL,
                                              channelInput.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first)
                                }
                            }
                        }
                        .padding(.horizontal, 16).padding(.top, 8)
                    }
                }

                Spacer(minLength: 40)
            }
        }
        .background(Color.tDark)
    }

    // MARK: – Search
    private func search(_ channel: String? = nil) async {
        let name = (channel ?? channelInput).trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
        guard !name.isEmpty else { errorMsg = store.t("err_missing"); return }
        loading = true; errorMsg = nil; liveData = nil; vods = []; searched = true

        async let liveTask    = getLive(channelName: name)
        async let videosTask  = getChannelVideos(channelName: name)
        let (live, ch) = await (liveTask, videosTask)

        avatarURL = live.avatar ?? ch.avatar ??
            "https://static-cdn.jtvnw.net/user-default-pictures-uv/cdd517fe-def4-11e9-948e-784f43822e80-profile_image-70x70.png"

        if live.error != nil && ch.error != nil && live.avatar == nil {
            errorMsg = store.t("not_found")
        } else {
            let item = HistoryItem(term: name, type: .channel, display: name, thumb: nil, streamer: nil, addedAt: Date().timeIntervalSince1970 * 1000)
            store.saveToHistory(item)
            liveData = live
            vods = ch.videos
        }
        loading = false
    }
}
