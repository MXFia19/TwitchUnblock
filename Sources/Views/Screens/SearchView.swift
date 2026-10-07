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
    /// « Tout lire » d'une playlist : la liste, et le nom de la chaîne.
    var onPlayQueue: ([VodData], String?) -> Void = { _, _ in }
    /// VOD supprimée reconstruite : liens prêts à lire.
    var onRecovered: (RecoveredVod) -> Void = { _ in }
    /// Ouverte en feuille sur une chaîne précise (pseudo du lecteur, chaîne
    /// hors ligne de l'accueil) : pas de barre de recherche, un bouton fermer.
    var initialChannel: String? = nil
    var onClose: (() -> Void)? = nil

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

    // Onglets de la chaîne : 0 VODs, 1 Highlights, 2 Playlists, 3 Clips, 4 À propos
    @State private var channelTab   = 0
    // VODs non listées (supprimées ou masquées) : diffusions récentes connues
    // d'une source externe, sans VOD dans la liste de Twitch. Rangées à leur
    // date parmi les VODs, reconstruites au toucher.
    @StateObject private var recovery = VodRecoveryService()
    @State private var resolvingID: String? = nil   // diffusion en cours de reconstruction
    /// Diffusions dont le CDN ne sert plus les segments.
    @State private var goneIDs: Set<String> = []
    @State private var highlights: [VodData] = []
    @State private var highlightsFor = ""
    @State private var loadingHighlights = false
    @State private var playlists: [PlaylistData] = []
    @State private var playlistsFor = ""
    @State private var loadingPlaylists = false

    // Clips de la chaîne (onglet « Clips »)
    @State private var clips: [ClipData] = []
    @State private var clipPeriod   = "LAST_WEEK"
    @State private var clipsFor     = ""
    @State private var loadingClips = false
    /// Twitch en a d'autres que les 100 premiers ; la suite vient de Helix
    /// (compte connecté), à partir de ce curseur.
    @State private var clipsMore    = false
    @State private var clipsCursor: String? = nil
    @State private var loadingMoreClips = false

    // Onglet « À propos » (description, réseaux, panneaux)
    @State private var about: ChannelAbout? = nil
    @State private var aboutFor     = ""
    @State private var loadingAbout = false

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

    /// Entrée de la grille des VODs : une vraie VOD, ou une diffusion dont la
    /// VOD n'est pas listée.
    private enum VodEntry: Identifiable {
        case vod(VodData)
        case unlisted(RecoverableStream)
        var id: String {
            switch self {
            case .vod(let v):      return "v\(v.id)"
            case .unlisted(let s): return "u\(s.streamID)"
            }
        }
    }

    /// Diffusions récentes sans VOD dans la liste de Twitch. Une VOD les
    /// couvre si sa vignette porte leur id de diffusion, ou si elle commence
    /// à la même heure (vignette « en cours de traitement »). Plus ancienne
    /// que la dernière VOD chargée, une diffusion reste de côté tant que la
    /// liste n'est pas complète : sa VOD est peut-être à la page suivante.
    private var unlistedStreams: [RecoverableStream] {
        guard !channelName.isEmpty, recovery.channel == channelName.lowercased() else { return [] }
        let window: TimeInterval = 15 * 60
        var dated: [(vod: VodData, date: Date)] = []
        for v in vods {
            if let d = parseTwitchDate(v.publishedAt) { dated.append((vod: v, date: d)) }
        }
        let oldest = hasMoreVods ? dated.map { $0.date }.min() : nil
        // Le direct en cours a sa propre page : pas une VOD perdue.
        let liveStart = liveData?.error == nil ? liveData?.startedAt : nil
        return recovery.streams.filter { s in
            if dated.contains(where: { $0.vod.previewThumbnailURL.contains("_\(s.streamID)_")
                                       || abs($0.date.timeIntervalSince(s.startedAt)) < window }) { return false }
            if let liveStart, abs(liveStart.timeIntervalSince(s.startedAt)) < window { return false }
            if let oldest, s.startedAt < oldest.addingTimeInterval(-window) { return false }
            return true
        }
    }

    /// VODs et diffusions non listées, de la plus récente à la plus ancienne,
    /// filtrées par le mot-clé.
    private var vodEntries: [VodEntry] {
        let kw = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        let extra = unlistedStreams.filter { kw.isEmpty || $0.title.lowercased().contains(kw) }
        guard !extra.isEmpty else { return filteredVods.map { VodEntry.vod($0) } }
        var items: [(date: Date, entry: VodEntry)] = []
        for v in filteredVods {
            items.append((date: parseTwitchDate(v.publishedAt) ?? .distantPast, entry: .vod(v)))
        }
        for s in extra {
            items.append((date: s.startedAt, entry: .unlisted(s)))
        }
        return items.sorted { $0.date > $1.date }.map { $0.entry }
    }

    private var offlineSinceText: String? {
        guard liveData?.error != nil, let first = vods.first else { return nil }
        // Chaîne vide = date illisible : on préfère ne rien dire plutôt
        // qu'afficher « Hors ligne depuis : » suivi de rien.
        guard let end = lastLiveEnd(publishedAt: first.publishedAt,
                                    lengthSeconds: first.lengthSeconds, lastStart: nil) else { return nil }
        let since = offlineLabel(since: end, store: store)
        return since.isEmpty ? nil : since
    }

    var body: some View {
        VStack(spacing: 0) {

            if initialChannel != nil {
                // ── En-tête de la feuille « chaîne » ─────────────────────
                HStack(spacing: TSpace.sm) {
                    Text(searchedName.isEmpty ? (initialChannel ?? "") : searchedName)
                        .font(.tSection).foregroundColor(.tText).lineLimit(1)
                    Spacer(minLength: 0)
                    TIconButton(icon: "xmark") { onClose?() }
                }
                .padding(.horizontal, TSpace.lg)
                .padding(.top, TSpace.lg)
                .padding(.bottom, TSpace.sm)
            } else {
            // ── Barre de recherche ──────────────────────────────────
            VStack(spacing: TSpace.sm) {
                HStack(spacing: TSpace.sm) {
                    searchField
                    TPrimaryButton(title: queryIsVod ? store.t("btn_open") : store.t("btn_search")) {
                        queryFocused = false
                        Task { await submit() }
                    }
                }
                .tourAnchor(.searchField)

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
            }

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
        // Chaîne demandée ailleurs (pseudo dans le lecteur, chaîne hors ligne
        // dans l'accueil) : on l'ouvre directement.
        .onAppear {
            if let login = initialChannel, searchedName.isEmpty, !loading {
                Task { await searchChannel(login) }
            }
        }
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
        // Masquables dans les réglages (« Streamers récents »).
        guard store.showRecentChannels else { return [] }
        return store.history.filter { $0.type == .channel }.prefix(10).map { $0 }
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
            TSegmented(items: [0, 1, 2, 3, 4], selection: $channelTab) {
                [store.t("vods"), store.t("highlights"), store.t("playlists"),
                 store.t("clips"), store.t("about")][$0]
            }
                .onChange(of: channelTab) { tab in
                    if tab == 1 { Task { await loadHighlights() } }
                    if tab == 2 { Task { await loadPlaylists() } }
                    if tab == 3 { Task { await loadClips() } }
                    if tab == 4 { Task { await loadAbout() } }
                }
        }

        if channelTab == 4 {
            aboutSection
        } else if channelTab == 3 {
            clipsSection
        } else if channelTab == 2 {
            playlistsSection
        } else if channelTab == 1 {
            highlightsSection
        } else {
            let entries = vodEntries
            let unlistedCount = unlistedStreams.count
            if !vods.isEmpty || unlistedCount > 0 {
                VStack(alignment: .leading, spacing: TSpace.md) {
                    TSectionHeader("\(vods.count) \(store.t("vods_found"))", icon: "film")

                    // Filtre par mot-clé : n'apparaît que s'il y a de quoi filtrer.
                    TSearchField(text: $filterText, placeholder: store.t("ph_keyword"))
                        .padding(.horizontal, TSpace.lg)

                    // D'où viennent les cartes « VOD non listée », une fois.
                    if unlistedCount > 0 {
                        Label(store.t("unlisted_hint"), systemImage: "eye.slash")
                            .font(.tMeta)
                            .foregroundColor(.tMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, TSpace.lg)
                    }

                    if entries.isEmpty {
                        TEmptyState(icon: "line.3.horizontal.decrease.circle",
                                    title: store.t("no_result"))
                    } else {
                        LazyVGrid(columns: columns, spacing: TSpace.md) {
                            ForEach(entries) { entry in
                                switch entry {
                                case .vod(let vod):
                                    let saved = store.getVodProgress(vod.id)
                                    let progress = vod.lengthSeconds > 0
                                        ? saved / Double(vod.lengthSeconds) : 0
                                    VodCardView(vod: vod, progress: progress) {
                                        onPlayVod(vod.id, vod.title, vod.previewThumbnailURL, channelName)
                                    }
                                    .onAppear {
                                        // Défilement infini : charge la suite quand la
                                        // dernière VOD apparaît.
                                        guard vod.id == filteredVods.last?.id,
                                              hasMoreVods, !isLoadingMore else { return }
                                        isLoadingMore = true
                                        Task { await loadMoreVods() }
                                    }
                                case .unlisted(let s):
                                    UnlistedVodCardView(stream: s,
                                                        resolving: resolvingID == s.streamID,
                                                        gone: goneIDs.contains(s.streamID)) {
                                        Task { await recover(s) }
                                    }
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

    // MARK: – Highlights
    @ViewBuilder private var highlightsSection: some View {
        if loadingHighlights {
            TLoader()
        } else if highlights.isEmpty {
            TEmptyState(icon: "star", title: store.t("no_highlights"))
        } else {
            LazyVGrid(columns: columns, spacing: TSpace.md) {
                ForEach(highlights) { vod in
                    let saved = store.getVodProgress(vod.id)
                    let progress = vod.lengthSeconds > 0 ? saved / Double(vod.lengthSeconds) : 0
                    VodCardView(vod: vod, progress: progress) {
                        onPlayVod(vod.id, vod.title, vod.previewThumbnailURL, channelName)
                    }
                }
            }
            .padding(.horizontal, TSpace.lg)
        }
    }

    @MainActor private func loadHighlights() async {
        let login = searchedName.lowercased()
        guard !login.isEmpty, highlightsFor != login else { return }
        loadingHighlights = true
        let result = await getHighlights(login: login)
        guard login == searchedName.lowercased() else { return }
        highlights = result
        highlightsFor = login
        loadingHighlights = false
    }

    // MARK: – Playlists
    @ViewBuilder private var playlistsSection: some View {
        if loadingPlaylists {
            TLoader()
        } else if playlists.isEmpty {
            TEmptyState(icon: "list.bullet.rectangle", title: store.t("no_playlists"))
        } else {
            VStack(alignment: .leading, spacing: TSpace.lg) {
                ForEach(playlists) { list in
                    VStack(alignment: .leading, spacing: TSpace.sm) {
                        HStack(alignment: .firstTextBaseline, spacing: TSpace.sm) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(list.title)
                                    .font(.system(size: 16, weight: .bold)).foregroundColor(.tText)
                                    .lineLimit(2)
                                Text(list.description.isEmpty
                                     ? String(format: store.t("videos_count"), list.total)
                                     : "\(list.description) · \(String(format: store.t("videos_count"), list.total))")
                                    .font(.system(size: 12)).foregroundColor(.tMuted)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            Button {
                                onPlayQueue(list.videos, channelName)
                            } label: {
                                Label(store.t("play_all"), systemImage: "play.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(Capsule().fill(Color.tPrimary.opacity(0.18)))
                                    .foregroundColor(.tPrimary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, TSpace.lg)

                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: TSpace.md) {
                                ForEach(list.videos) { vod in
                                    let saved = store.getVodProgress(vod.id)
                                    let progress = vod.lengthSeconds > 0 ? saved / Double(vod.lengthSeconds) : 0
                                    VodCardView(vod: vod, progress: progress) {
                                        onPlayVod(vod.id, vod.title, vod.previewThumbnailURL, channelName)
                                    }
                                    .frame(width: 200)
                                }
                            }
                            .padding(.horizontal, TSpace.lg)
                        }
                    }
                }
            }
        }
    }

    @MainActor private func loadPlaylists() async {
        let login = searchedName.lowercased()
        guard !login.isEmpty, playlistsFor != login else { return }
        loadingPlaylists = true
        let result = await getCollections(login: login)
        guard login == searchedName.lowercased() else { return }
        playlists = result
        playlistsFor = login
        loadingPlaylists = false
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

                // Au-delà des 100 premiers : il faut le compte (Helix).
                if clipsMore {
                    if store.twitchToken != nil {
                        TLoadMoreButton(busy: loadingMoreClips) { Task { await loadMoreClips() } }
                    } else {
                        Text(store.t("more_needs_login"))
                            .font(.tMeta).foregroundColor(.tMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.top, TSpace.sm)
                    }
                }
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
        clips = result.clips
        clipsMore = result.more
        clipsCursor = nil
        clipsFor = key
        loadingClips = false
    }

    /// Clips au-delà des 100 premiers : Helix, avec le compte. Helix repart du
    /// début (ses 100 premiers recouvrent ceux déjà là) : jusqu'à 3 pages pour
    /// trouver du neuf.
    @MainActor private func loadMoreClips() async {
        guard clipsMore, !loadingMoreClips, let token = store.twitchToken else { return }
        let key = clipsFor
        let login = searchedName.lowercased()
        loadingMoreClips = true
        defer { loadingMoreClips = false }
        var broadcaster = liveData?.userId ?? ""
        if broadcaster.isEmpty { broadcaster = await getUserIdGQL(login: login) ?? "" }
        guard !broadcaster.isEmpty else { clipsMore = false; return }
        var known = Set(clips.map(\.id))
        var cursor = clipsCursor
        var fresh: [ClipData] = []
        for _ in 0..<3 {
            let page = await getClipsHelix(token: token, broadcasterId: broadcaster,
                                           period: clipPeriod, cursor: cursor)
            cursor = page.cursor
            for c in page.clips where !known.contains(c.id) {
                known.insert(c.id)
                fresh.append(c)
            }
            if !fresh.isEmpty || cursor == nil { break }
        }
        guard key == clipsFor else { return }
        clips += fresh
        clipsCursor = cursor
        clipsMore = cursor != nil
    }

    // MARK: – À propos
    @ViewBuilder private var aboutSection: some View {
        if loadingAbout {
            TLoader()
        } else if let about {
            ChannelAboutView(about: about, name: channelName)
                .padding(.horizontal, TSpace.lg)
        } else {
            TEmptyState(icon: "info.circle", title: store.t("about_empty"))
        }
    }

    @MainActor private func loadAbout() async {
        let login = searchedName.lowercased()
        guard !login.isEmpty, aboutFor != login else { return }
        loadingAbout = true
        let result = await getChannelAbout(login: login)
        guard login == searchedName.lowercased() else { return }
        about = result
        // Échec réseau : on retentera en revenant sur l'onglet.
        if result != nil { aboutFor = login }
        loadingAbout = false
    }

    // MARK: – VODs non listées (reconstruction)
    /// Reconstruit les liens d'une diffusion non listée, puis la lit. Si le CDN
    /// ne la sert plus, sa carte le dit ; un nouvel essai reste possible.
    @MainActor private func recover(_ s: RecoverableStream) async {
        guard resolvingID == nil else { return }
        resolvingID = s.streamID
        goneIDs.remove(s.streamID)
        let links = await recovery.resolve(s)
        resolvingID = nil
        if let links, !links.isEmpty {
            onRecovered(RecoveredVod(
                streamID: s.streamID,
                title: s.title.isEmpty ? s.login : s.title,
                streamer: s.login, links: links))
        } else {
            goneIDs.insert(s.streamID)
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
        var login = name.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ").first?.lowercased() ?? ""
        // Lien Twitch collé (« twitch.tv/xqc », « https://www.twitch.tv/xqc/clips ») :
        // on en garde la chaîne.
        if let r = login.range(of: #"twitch\.tv/([a-z0-9_]{1,25})"#, options: .regularExpression) {
            let path = login[r].replacingOccurrences(of: "twitch.tv/", with: "")
            if !["videos", "directory"].contains(path) { login = path }
        }
        guard !login.isEmpty else { return }

        loading = true; errorMsg = nil; liveData = nil; vods = []
        filterText = ""; searchedName = login; suggestions = []
        channelTab = 0; clips = []; clipsFor = ""
        clipsMore = false; clipsCursor = nil; loadingMoreClips = false
        about = nil; aboutFor = ""; loadingAbout = false
        resolvingID = nil; goneIDs = []
        playlists = []; playlistsFor = ""; loadingPlaylists = false
        highlights = []; highlightsFor = ""; loadingHighlights = false
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
            // VODs non listées : en arrière-plan, la grille s'affiche sans attendre.
            Task { await recovery.load(channel: login) }
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
