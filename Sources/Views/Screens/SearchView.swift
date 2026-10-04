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
    var onPlayClip: (String, String?) -> Void = { _, _ in }

    @EnvironmentObject private var store: AppStore
    /// Suivre pour de vrai (session web) depuis la page de la chaîne.
    @StateObject private var follow = FollowService()

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

    // Clips de la chaîne (onglet « Clips »)
    @State private var showClips    = false
    @State private var clips: [ClipData] = []
    @State private var clipPeriod   = "LAST_WEEK"
    @State private var clipsFor     = ""
    @State private var loadingClips = false

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
        // Chaîne vide = date illisible : on préfère ne rien dire plutôt
        // qu'afficher « Hors ligne depuis : » suivi de rien.
        let since = getTimeSince(publishedAt: first.publishedAt,
                                 lengthSeconds: first.lengthSeconds, store: store)
        return since.isEmpty ? nil : since
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
                        // Anneau rouge : la chaîne est en live.
                        .overlay(Circle().stroke(s.isLive ? Color.tLive : .clear, lineWidth: 2).padding(-2))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(.tCardTitle).foregroundColor(.tText).lineLimit(1)
                            if let viewers = s.viewers {
                                HStack(spacing: 5) {
                                    Text("LIVE")
                                        .font(.system(size: 9, weight: .heavy))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(Color.tLive).cornerRadius(3)
                                    Text(formatViewers(viewers) + (s.game.map { " · \($0)" } ?? ""))
                                        .font(.tMeta).foregroundColor(.tMuted).lineLimit(1)
                                }
                            }
                        }
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

            // Suivre sans compte Twitch : la chaîne apparaît dans l'accueil
            // (« Chaînes suivies ») dès qu'elle est en live.
            // Avec une session web, c'est un vrai suivi Twitch ; sans, il reste
            // sur cet appareil.
            if !channelName.isEmpty, let on = follow.isFollowing {
                let local = store.twitchWebToken == nil
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    Task { await follow.toggle(token: store.twitchWebToken) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: on ? "heart.fill" : "heart")
                        Text(store.t(on ? "following" : "follow")).font(.system(size: 14, weight: .bold))
                        if local {
                            Text("· " + store.t("on_this_device")).font(.system(size: 12)).opacity(0.8)
                        }
                    }
                    .foregroundColor(on ? .tDanger : .tPrimary)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background((on ? Color.tDanger : Color.tPrimary).opacity(0.14))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(on ? Color.tDanger : Color.tPrimary, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(follow.busy)
                .opacity(follow.busy ? 0.5 : 1)
                .padding(.horizontal, TSpace.lg)
            }
        }

        if liveData != nil {
            TSegmented(items: [false, true], selection: $showClips) { $0 ? store.t("clips") : store.t("vods") }
                .onChange(of: showClips) { on in if on { Task { await loadClips() } } }
        }

        if showClips {
            clipsSection
        } else {
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
    }

    // MARK: – Clips
    @ViewBuilder private var clipsSection: some View {
        VStack(alignment: .leading, spacing: TSpace.md) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach([("LAST_DAY", "period_day"), ("LAST_WEEK", "period_week"),
                             ("LAST_MONTH", "period_month"), ("ALL_TIME", "period_all")], id: \.0) { p in
                        TChip(title: store.t(p.1), isOn: clipPeriod == p.0) {
                            clipPeriod = p.0
                            Task { await loadClips() }
                        }
                    }
                }
                .padding(.horizontal, TSpace.lg)
            }
            if loadingClips {
                TLoader()
            } else if clips.isEmpty {
                TEmptyState(icon: "scissors", title: store.t("no_clips"))
            } else {
                LazyVGrid(columns: columns, spacing: TSpace.md) {
                    ForEach(clips) { clip in
                        ClipCardView(clip: clip) { onPlayClip(clip.id, clip.title) }
                    }
                }
                .padding(.horizontal, TSpace.lg)
            }
        }
    }

    @MainActor private func loadClips() async {
        let login = searchedName.lowercased()
        guard !login.isEmpty else { return }
        let key = "\(login)|\(clipPeriod)"
        if clipsFor == key, !clips.isEmpty { return }
        loadingClips = true
        let result = await getClips(login: login, period: clipPeriod)
        guard key == "\(searchedName.lowercased())|\(clipPeriod)" else { return }
        clips = result
        clipsFor = key
        loadingClips = false
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
        showClips = false; clips = []; clipsFor = ""
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
            Task { await loadFollowState(login: login, channelId: live.userId) }
            vods        = ch.videos
            vodCursor   = ch.cursor
            hasMoreVods = ch.cursor != nil
        }
        loading = false
    }

    /// Session web : statut de suivi Twitch réel. Sinon, suivi sur l'appareil.
    @MainActor private func loadFollowState(login: String, channelId: String?) async {
        guard let web = store.twitchWebToken else { follow.loadLocal(login: login, store: store); return }
        var cid = channelId ?? ""
        if cid.isEmpty { cid = await getUserIdGQL(login: login) ?? "" }
        guard !cid.isEmpty, login == channelName.lowercased() else { return }
        await follow.load(login: login, channelId: cid, token: web)
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
