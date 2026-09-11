import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Recherche unifiée.
//
//  Avant, « Streamer » et « Lien / ID » étaient deux onglets distincts alors
//  que c'est le même geste : on cherche quelque chose. Ici un seul champ, et
//  c'est l'app qui reconnaît ce qu'on lui donne :
//    • un lien ou un identifiant numérique  → on ouvre la VOD directement
//    • n'importe quoi d'autre               → on cherche la chaîne
// ═══════════════════════════════════════════════════════════════════════════

struct SearchView: View {
    let onPlayVod:  (String, String?, String?, String?) -> Void
    let onPlayLive: (String) -> Void

    @EnvironmentObject private var store: AppStore

    @State private var query        = ""
    @State private var filterText   = ""
    @State private var loading      = false
    @State private var errorMsg: String? = nil
    @State private var searchedName = ""

    // Résultats « chaîne »
    @State private var liveData: LiveData? = nil
    @State private var avatarURL = ""
    @State private var vods: [VodData] = []
    @State private var vodCursor: String? = nil
    @State private var hasMoreVods  = false
    @State private var isLoadingMore = false

    // Suggestions de chaînes pendant la frappe
    @State private var suggestions: [AutocompleteSuggestion] = []
    @State private var suggestTask: Task<Void, Never>? = nil
    @FocusState private var queryFocused: Bool

    private let columns = [GridItem(.flexible(), alignment: .top),
                           GridItem(.flexible(), alignment: .top)]

    /// Le texte saisi désigne-t-il une VOD (lien twitch.tv/videos/… ou ID) ?
    private var queryIsVod: Bool {
        let t = query.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        // Un identifiant de VOD est un nombre long ; un lien contient /videos/.
        if t.lowercased().contains("/videos/") { return true }
        return t.allSatisfy(\.isNumber) && t.count >= 8
    }

    private var channelName: String {
        searchedName.isEmpty ? "" : searchedName
    }

    private var filteredVods: [VodData] {
        let kw = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !kw.isEmpty else { return vods }
        return vods.filter { $0.title.lowercased().contains(kw) }
    }

    private var offlineSinceText: String? {
        guard liveData?.error != nil, let first = vods.first else { return nil }
        return getTimeSince(publishedAt: first.publishedAt,
                            lengthSeconds: first.lengthSeconds, store: store)
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Barre de recherche ──────────────────────────────────
            VStack(spacing: TSpace.sm) {
                HStack(spacing: TSpace.sm) {
                    searchField
                    TPrimaryButton(title: queryIsVod ? store.t("btn_open") : store.t("btn_search")) {
                        queryFocused = false
                        Task { await submit() }
                    }
                }

                // Indique ce qui va se passer : l'utilisateur n'a pas à deviner.
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    HStack(spacing: TSpace.xs) {
                        Image(systemName: queryIsVod ? "play.rectangle.fill" : "person.fill")
                            .font(.system(size: 10))
                        Text(queryIsVod ? store.t("hint_is_vod") : store.t("hint_is_channel"))
                            .font(.tMeta)
                    }
                    .foregroundColor(.tMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, TSpace.lg)
            .padding(.top, TSpace.md)
            .padding(.bottom, TSpace.sm)
            .zIndex(10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: TSpace.lg) {

                    // ── Suggestions de chaînes ──────────────────────
                    if queryFocused, !suggestions.isEmpty, !queryIsVod {
                        suggestionList
                    }

                    // ── Chaînes récentes ────────────────────────────
                    if !loading, searchedName.isEmpty, suggestions.isEmpty {
                        recentChannels
                    }

                    if loading {
                        TLoader()
                    } else if let err = errorMsg {
                        TEmptyState(icon: "exclamationmark.triangle", title: err)
                    } else if !searchedName.isEmpty {
                        results
                    } else if !queryFocused, query.isEmpty, recentChannelItems.isEmpty {
                        TEmptyState(icon: "magnifyingglass",
                                    title: store.t("search_empty_title"),
                                    message: store.t("search_empty_msg"))
                    }

                    Spacer(minLength: 40)
                }
                .padding(.top, TSpace.sm)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tDark)
    }

    // MARK: – Champ + suggestions
    @ViewBuilder private var searchField: some View {
        HStack(spacing: TSpace.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(queryFocused ? .tPrimary : .tMuted)

            TextField(store.t("ph_search"), text: $query)
                .font(.tBody)
                .foregroundColor(.tText)
                .focused($queryFocused)
                .autocorrectionDisabled()
                .autocapitalization(.none)
                .submitLabel(.search)
                .onSubmit { queryFocused = false; Task { await submit() } }
                .onChange(of: query) { suggest($0) }

            if !query.isEmpty {
                Button {
                    query = ""; suggestions = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15)).foregroundColor(.tMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, TSpace.md)
        .frame(height: 44)
        .tControlSurface(focused: queryFocused)
    }

    @ViewBuilder private var suggestionList: some View {
        VStack(spacing: 0) {
            ForEach(suggestions) { s in
                Button {
                    query = s.login
                    queryFocused = false
                    suggestions = []
                    Task { await searchChannel(s.login) }
                } label: {
                    HStack(spacing: TSpace.md) {
                        AsyncImage(url: URL(string: s.avatar ?? "")) { img in
                            img.resizable().scaledToFill()
                        } placeholder: {
                            Circle().fill(Color.tSurface)
                        }
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())

                        Text(s.name).font(.tCardTitle).foregroundColor(.tText)
                        Spacer()
                        Image(systemName: "arrow.up.left")
                            .font(.system(size: 11)).foregroundColor(.tMuted)
                    }
                    .padding(.horizontal, TSpace.md)
                    .frame(height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if s.id != suggestions.last?.id {
                    Divider().background(Color.tBorder).padding(.leading, 56)
                }
            }
        }
        .background(Color.tCard)
        .cornerRadius(TRadius.card)
        .padding(.horizontal, TSpace.lg)
    }

    // MARK: – Chaînes récentes
    private var recentChannelItems: [HistoryItem] {
        store.history.filter { $0.type == .channel }.prefix(10).map { $0 }
    }

    @ViewBuilder private var recentChannels: some View {
        if !recentChannelItems.isEmpty {
            VStack(alignment: .leading, spacing: TSpace.md) {
                TSectionHeader(store.t("lbl_channel_history"), icon: "clock.arrow.circlepath") {
                    Button { store.clearChannelHistory() } label: {
                        Text(store.t("btn_clear"))
                            .font(.tMeta).foregroundColor(.tDanger)
                    }
                    .buttonStyle(.plain)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: TSpace.sm) {
                        ForEach(recentChannelItems) { item in
                            HStack(spacing: TSpace.sm) {
                                Text(item.display)
                                    .font(.tLabel).foregroundColor(.tText)
                                    .lineLimit(1)
                                Button {
                                    store.removeFromHistory(term: item.term)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.tMuted)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.leading, TSpace.md).padding(.trailing, TSpace.sm)
                            .frame(height: 34)
                            .background(Color.tSurface)
                            .clipShape(Capsule())
                            .contentShape(Capsule())
                            .onTapGesture {
                                query = item.term
                                Task { await searchChannel(item.term) }
                            }
                        }
                    }
                    .padding(.horizontal, TSpace.lg)
                }
            }
        }
    }

    // MARK: – Résultats d'une chaîne
    @ViewBuilder private var results: some View {
        if let live = liveData {
            ChannelHeroView(
                login: channelName,
                isOnline: live.error == nil,
                title: live.error != nil ? store.t("offline_msg") : live.title,
                game: live.game,
                avatarURL: avatarURL,
                thumbnailURL: live.thumbnail,
                viewerCount: live.viewerCount,
                offlineSince: offlineSinceText,
                onWatchLive: live.error == nil ? { onPlayLive(channelName) } : nil
            )
            .padding(.horizontal, TSpace.lg)
        }

        if !vods.isEmpty {
            VStack(alignment: .leading, spacing: TSpace.md) {
                TSectionHeader("\(vods.count) \(store.t("vods_found"))", icon: "film")

                // Filtre par mot-clé : n'apparaît que s'il y a de quoi filtrer.
                TSearchField(text: $filterText, placeholder: store.t("ph_keyword"))
                    .padding(.horizontal, TSpace.lg)

                if filteredVods.isEmpty {
                    TEmptyState(icon: "line.3.horizontal.decrease.circle",
                                title: store.t("no_result"))
                } else {
                    LazyVGrid(columns: columns, spacing: TSpace.md) {
                        ForEach(filteredVods) { vod in
                            let saved = store.getVodProgress(vod.id)
                            let progress = vod.lengthSeconds > 0
                                ? saved / Double(vod.lengthSeconds) : 0
                            VodCardView(vod: vod, progress: progress) {
                                onPlayVod(vod.id, vod.title, vod.previewThumbnailURL, channelName)
                            }
                            .onAppear {
                                // Défilement infini : charge la suite quand la
                                // dernière carte apparaît.
                                guard vod.id == filteredVods.last?.id,
                                      hasMoreVods, !isLoadingMore else { return }
                                isLoadingMore = true
                                Task { await loadMoreVods() }
                            }
                        }
                    }
                    .padding(.horizontal, TSpace.lg)

                    if isLoadingMore { TLoader() }
                }
            }
        } else if liveData != nil, errorMsg == nil {
            TEmptyState(icon: "film", title: store.t("no_vod"))
        }
    }

    // MARK: – Actions
    /// Aiguille vers la VOD ou la chaîne selon ce qui a été saisi.
    @MainActor private func submit() async {
        let raw = query.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        if queryIsVod { await openVod(raw) } else { await searchChannel(raw) }
    }

    @MainActor private func openVod(_ raw: String) async {
        guard let vodId = extractVodId(raw) else {
            errorMsg = store.t("err_bad_vod"); return
        }
        loading = true; errorMsg = nil; searchedName = ""
        suggestions = []

        async let metaTask = getVodMetaGQL(vodId)
        async let m3u8Task = getM3U8(vodId: vodId)
        let (meta, m3u8) = await (metaTask, m3u8Task)
        loading = false

        guard !(m3u8.links.isEmpty && m3u8.error != nil) else {
            errorMsg = m3u8.error; return
        }
        // La lecture passe par le lecteur global : l'historique y est enregistré.
        onPlayVod(vodId, meta?.title ?? "VOD \(vodId)", meta?.thumb, meta?.streamer)
    }

    @MainActor private func searchChannel(_ name: String) async {
        let login = name.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ").first?.lowercased() ?? ""
        guard !login.isEmpty else { return }

        loading = true; errorMsg = nil; liveData = nil; vods = []
        filterText = ""; searchedName = login; suggestions = []
        vodCursor = nil; hasMoreVods = false; isLoadingMore = false

        async let liveTask   = getLive(channelName: login)
        async let videosTask = getChannelVideos(channelName: login)
        let (live, ch) = await (liveTask, videosTask)

        avatarURL = live.avatar ?? ch.avatar ?? ""

        if live.error != nil && ch.error != nil && live.avatar == nil {
            errorMsg = store.t("not_found")
            searchedName = ""
        } else {
            store.saveToHistory(HistoryItem(
                term: login, type: .channel, display: login,
                thumb: nil, streamer: nil,
                addedAt: Date().timeIntervalSince1970 * 1000))
            liveData    = live
            vods        = ch.videos
            vodCursor   = ch.cursor
            hasMoreVods = ch.cursor != nil
        }
        loading = false
    }

    @MainActor private func loadMoreVods() async {
        guard let cursor = vodCursor, !channelName.isEmpty else {
            isLoadingMore = false; return
        }
        let ch = await getChannelVideos(channelName: channelName, cursor: cursor)
        let known = Set(vods.map(\.id))
        let fresh = ch.videos.filter { !known.contains($0.id) }
        vods += fresh
        vodCursor   = ch.cursor
        hasMoreVods = ch.cursor != nil && !fresh.isEmpty
        isLoadingMore = false
    }

    /// Suggestions de chaînes, différées de 300 ms pour ne pas appeler à chaque frappe.
    private func suggest(_ text: String) {
        suggestTask?.cancel()
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, !queryIsVod else { suggestions = []; return }
        suggestTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let found = await searchUsersGQL(t)
            guard !Task.isCancelled else { return }
            await MainActor.run { suggestions = Array(found.prefix(5)) }
        }
    }
}
