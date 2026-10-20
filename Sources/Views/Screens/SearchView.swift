import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Recherche unifiée.
//
//  Avant, « Streamer » et « Lien / ID » étaient deux onglets distincts alors
//  que c'est le même geste : on cherche quelque chose. Ici un seul champ, et
//  c'est l'app qui reconnaît ce qu'on lui donne :
//    • un lien ou un identifiant numérique  → on ouvre la VOD directement
//    • un lien de clip                       → on le lit
//    • un lien de chaîne, ou « @pseudo »     → on ouvre la chaîne
//    • n'importe quoi d'autre               → résultats en onglets : chaînes,
//      catégories, lives et VODs (SearchResultsView)
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
    /// « Ne plus suivre » touché : on demande d'abord confirmation.
    @State private var confirmUnfollow = false

    @State private var query        = ""
    @State private var filterText   = ""
    @State private var loading      = false
    @State private var errorMsg: String? = nil
    /// Chaîne dont la page n'a pas pu se charger, Twitch n'ayant pas répondu :
    /// « Réessayer » la redemande (rien à refaire pour une chaîne introuvable).
    @State private var retryLogin: String? = nil
    @State private var searchedName = ""

    // Résultats « chaîne »
    @State private var liveData: LiveData? = nil
    /// Début du dernier live (même sans VOD), pour « hors ligne depuis ».
    @State private var lastBroadcastAt: String? = nil
    @State private var avatarURL = ""
    @State private var vods: [VodData] = []
    @State private var vodCursor: String? = nil
    @State private var hasMoreVods  = false
    @State private var isLoadingMore = false
    /// Suite des VODs : Twitch la refuse (message), ou panne réseau (bouton
    /// pour réessayer, le défilement infini ne relance pas seul).
    @State private var vodsRefused   = false
    @State private var vodsMoreFailed = false
    /// Filtre par mot-clé : pages suivantes demandées pour y chercher.
    @State private var searchingOlder = false

    // Recherche par texte : résultats en onglets, gardés pendant qu'on ouvre
    // une chaîne ou une catégorie trouvée (retour sans les redemander).
    @StateObject private var found = SearchResults()
    @State private var resultsTab: SearchTab = .channels
    /// Catégorie ouverte depuis les résultats : ses lives à la place de la page.
    @State private var openedCategory: TwitchCategory? = nil
    /// Feuille des chaînes et catégories masquées (« N masqués ici · Gérer »).
    @State private var showHidden = false

    // Onglets de la chaîne : 0 VODs, 1 Highlights, 2 Playlists, 3 Clips,
    // 4 À propos, 5 Planning (seulement si la chaîne en a un), dans l'ordre
    // choisi (Réglages → Personnaliser) ; la page ouvre le premier affiché.
    @State private var channelTab   = 0
    /// Planning de la chaîne : onglet « Planning » et ligne « Prochain live »
    /// du bandeau. nil : pas encore lu, ou Twitch n'a pas répondu.
    @State private var schedule: ChannelSchedule? = nil
    // VODs non listées (supprimées ou masquées) : diffusions récentes connues
    // d'une source externe, sans VOD dans la liste de Twitch. Rangées à leur
    // date parmi les VODs, reconstruites au toucher.
    @StateObject private var recovery = VodRecoveryService()
    @State private var resolvingID: String? = nil   // diffusion en cours de reconstruction
    /// Reconstruction en cours : annulée si on ouvre une autre chaîne ou si
    /// la page se ferme, pour qu'elle n'ouvre pas le lecteur après coup.
    @State private var recoverTask: Task<Void, Never>? = nil
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
    /// Suite des clips : GQL sans compte (Client-ID d'Android), ou Helix avec
    /// le compte si Twitch refuse GQL. nil : pas de suite.
    @State private var clipsCursor: ListCursor? = nil
    /// Twitch refuse la suite sans compte : un message remplace le bouton.
    @State private var clipsLocked  = false
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
    /// Même règle que le « + » du multi-live (TwitchAPI).
    private var queryIsVod: Bool { isVodInput(query) }
    /// Lien de clip collé : il s'ouvre directement, comme sur le site.
    private var queryIsClip: Bool { clipSlugFromInput(query) != nil }
    /// Lien de chaîne collé (« twitch.tv/xqc ») ou « @xqc » : la page de la
    /// chaîne s'ouvre directement, comme avant ; tout autre texte part en
    /// recherche (résultats en onglets).
    private var queryIsChannelLink: Bool {
        let t = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty, !queryIsVod, !queryIsClip,
              t.hasPrefix("@") || t.contains("twitch.tv/") else { return false }
        return isValidLogin(loginFromInput(t))
    }

    private var channelName: String {
        searchedName.isEmpty ? "" : searchedName
    }

    /// Chaîne affichée suivie (compte ou appareil), pour la cloche des
    /// notifications. `following` : le cœur ; lu sur Twitch (session web), il
    /// fait foi, sinon la liste des suivis du compte lue au lancement.
    private func channelFollowed(following: Bool) -> Bool {
        let l = channelName.lowercased()
        if store.isLocallyFollowed(l) { return true }
        if follow.localStore == nil { return following }
        return store.accountFollowLogins.contains(l)
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
        // Liste incomplète : suite à charger, en panne, ou refusée par Twitch.
        let oldest = vodCursor != nil || vodsRefused ? dated.map { $0.date }.min() : nil
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
        guard liveData?.error != nil else { return nil }
        // La dernière VOD, ou le dernier live s'il est plus récent (un live
        // sans VOD n'en laisse pas) : comme l'accueil, qui disait « 1 j »
        // quand la page disait « 21 j ».
        let first = vods.first
        // Chaîne vide = date illisible : on préfère ne rien dire plutôt
        // qu'afficher « Hors ligne depuis : » suivi de rien.
        guard let end = lastLiveEnd(publishedAt: first?.publishedAt,
                                    lengthSeconds: first?.lengthSeconds ?? 0,
                                    lastStart: lastBroadcastAt) else { return nil }
        let since = offlineLabel(since: end, store: store)
        return since.isEmpty ? nil : since
    }

    var body: some View {
        Group {
            // Catégorie ouverte depuis les résultats : ses lives à la place
            // de la recherche ; son bouton retour ramène aux résultats.
            if let cat = openedCategory {
                CategoryStreamsView(category: cat,
                                    followedOnTwitch: store.accountFollowedCategoryIds.contains(cat.id),
                                    onBack: { openedCategory = nil },
                                    onPlayStream: { login in leaveRecovery(); onPlayLive(login) })
            } else {
                searchPage
            }
        }
    }

    private var searchPage: some View {
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
                    TPrimaryButton(title: queryIsVod || queryIsClip || queryIsChannelLink
                                   ? store.t("btn_open") : store.t("btn_search")) {
                        queryFocused = false
                        Task { await submit() }
                    }
                }
                .tourAnchor(.searchField)

                // Indique ce qui va se passer : l'utilisateur n'a pas à deviner.
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    HStack(spacing: TSpace.xs) {
                        Image(systemName: queryIsClip ? "scissors" : queryIsVod ? "play.rectangle.fill"
                              : queryIsChannelLink ? "person.fill" : "magnifyingglass")
                            .font(.system(size: 10))
                        Text(store.t(queryIsClip ? "hint_is_clip" : queryIsVod ? "hint_is_vod"
                                     : queryIsChannelLink ? "hint_is_channel" : "hint_is_search"))
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

            // Onglet Recherche touché à nouveau : retour en haut.
            TabScrollView(tab: .search) {
                LazyVStack(alignment: .leading, spacing: TSpace.lg) {

                    // ── Suggestions de chaînes ──────────────────────
                    if queryFocused, !suggestions.isEmpty, !queryIsVod {
                        suggestionList
                    }

                    // ── Recherches récentes ─────────────────────────
                    if showsRecentSearches {
                        recentSearches
                    }

                    // ── Chaînes récentes ────────────────────────────
                    if !loading, searchedName.isEmpty, suggestions.isEmpty, found.query.isEmpty {
                        recentChannels
                    }

                    if loading {
                        TLoader()
                    } else if let err = errorMsg {
                        backToResults
                        TEmptyState(icon: "exclamationmark.triangle", title: err,
                                    actionTitle: retryLogin == nil ? nil : store.t("retry"),
                                    action: retryAction)
                    } else if !searchedName.isEmpty {
                        backToResults
                        results
                    } else if !found.query.isEmpty {
                        // ── Résultats d'une recherche par texte ─────
                        SearchResultsSection(
                            results: found,
                            tab: $resultsTab,
                            onOpenChannel: { login in
                                queryFocused = false
                                Task { await searchChannel(login) }
                            },
                            onOpenCategory: { cat in openedCategory = cat },
                            onPlayLive: { login in leaveRecovery(); onPlayLive(login) },
                            onPlayVod: { id, title, thumb, login in
                                leaveRecovery()
                                onPlayVod(id, title, thumb, login)
                            },
                            onRetry: {
                                Task { @MainActor in found.search(found.query, token: store.twitchToken) }
                            },
                            onShowHidden: { showHidden = true })
                    } else if !queryFocused, query.isEmpty, recentChannelItems.isEmpty,
                              store.searchHistory.isEmpty {
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
        // Page quittée (autre onglet, feuille fermée) : une reconstruction en
        // cours n'ouvre plus le lecteur après coup.
        .onDisappear {
            recoverTask?.cancel()
            recoverTask = nil
        }
        .sheet(isPresented: $showHidden) {
            HiddenContentSheet().environmentObject(store)
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
                            HStack(spacing: 5) {
                                Text(s.name).font(.tCardTitle).foregroundColor(.tText).lineLimit(1)
                                // Masquée des listes : la recherche la trouve quand même.
                                if store.hidden.hides(channel: s.login) {
                                    Image(systemName: "eye.slash")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.tMuted)
                                        .accessibilityLabel(store.t("hidden_badge"))
                                }
                            }
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

    // MARK: – Recherches récentes
    /// Dernières recherches par texte : sous le champ vide qu'on touche, ou
    /// quand rien d'autre n'est affiché.
    private var showsRecentSearches: Bool {
        guard initialChannel == nil, !store.searchHistory.isEmpty, suggestions.isEmpty, !loading else { return false }
        if queryFocused && query.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        return searchedName.isEmpty && found.query.isEmpty && errorMsg == nil
    }

    @ViewBuilder private var recentSearches: some View {
        VStack(alignment: .leading, spacing: TSpace.md) {
            TSectionHeader(store.t("search_recent"), icon: "magnifyingglass") {
                Button { store.clearSearchHistory() } label: {
                    Text(store.t("btn_clear"))
                        .font(.tMeta).foregroundColor(.tDanger)
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 0) {
                ForEach(store.searchHistory, id: \.self) { term in
                    HStack(spacing: TSpace.md) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 13))
                            .foregroundColor(.tMuted)
                        Text(term)
                            .font(.tBody).foregroundColor(.tText)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            store.removeSearch(term)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.tMuted)
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.leading, TSpace.md).padding(.trailing, TSpace.xs)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        query = term
                        queryFocused = false
                        runSearch(term)
                    }

                    if term != store.searchHistory.last {
                        Divider().background(Color.tBorder).padding(.leading, 42)
                    }
                }
            }
            .background(Color.tCard)
            .cornerRadius(TRadius.card)
            .padding(.horizontal, TSpace.lg)
        }
    }

    /// Chaîne (ou erreur) ouverte depuis les résultats d'une recherche : le
    /// chemin du retour vers eux.
    @ViewBuilder private var backToResults: some View {
        if initialChannel == nil, !found.query.isEmpty {
            Button { closeChannel() } label: {
                HStack(spacing: TSpace.xs) {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold))
                    Text(store.t("search_back").replacingOccurrences(of: "{q}", with: found.query))
                        .font(.tLabel)
                        .lineLimit(1)
                }
                .foregroundColor(.tPrimary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, TSpace.lg)
        }
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
            // Hors ligne : son prochain live prévu (ou ses vacances).
            let headline = schedule.flatMap { scheduleHeadline($0, store: store) }
            ChannelHeroView(
                login: channelName,
                isOnline: live.error == nil,
                title: live.error != nil ? store.t("offline_msg") : live.title,
                game: live.game,
                avatarURL: avatarURL,
                thumbnailURL: live.thumbnail,
                viewerCount: live.viewerCount,
                offlineSince: offlineSinceText,
                onWatchLive: live.error == nil ? { leaveRecovery(); onPlayLive(channelName) } : nil,
                nextLive: headline?.text,
                nextLiveIcon: headline?.icon ?? "calendar",
                onNextLive: channelTabs.contains(5) ? { channelTab = 5 } : nil
            )
            .padding(.horizontal, TSpace.lg)

            // Suivre sans compte Twitch : la chaîne apparaît dans l'accueil
            // (« Chaînes suivies ») dès qu'elle est en live.
            // Avec une session web, c'est un vrai suivi Twitch ; sans, il reste
            // sur cet appareil.
            if !channelName.isEmpty, let on = follow.isFollowing {
                let local = store.twitchWebToken == nil
                HStack(spacing: TSpace.sm) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        // Ne plus suivre se confirme (sur Twitch avec la session web).
                        if follow.isFollowing == true {
                            confirmUnfollow = true
                            return
                        }
                        let login = channelName
                        Task { @MainActor in
                            await follow.toggle(token: store.twitchWebToken)
                            // Suivie (aussi sur Twitch, sans passer par AppStore) :
                            // elle n'a plus à être masquée.
                            if follow.isFollowing == true { store.unhideChannel(login) }
                        }
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
                    .confirmationDialog(
                        store.t("unfollow_confirm").replacingOccurrences(of: "{c}", with: channelName),
                        isPresented: $confirmUnfollow, titleVisibility: .visible
                    ) {
                        Button(store.t("unfollow"), role: .destructive) {
                            Task { @MainActor in await follow.unfollow(token: store.twitchWebToken) }
                        }
                        Button(store.t("cancel"), role: .cancel) {}
                    }
                    // Cloche : notifications de live de cette chaîne seulement
                    // (affichée si elles sont activées et la chaîne suivie).
                    NotifBellButton(login: channelName, followed: channelFollowed(following: on))
                }
                .padding(.horizontal, TSpace.lg)

                // Twitch a refusé (limite de suivis, chaîne qui bloque…) : le
                // cœur garde son état, et on le dit au lieu de ne rien faire.
                if let code = follow.lastError {
                    Text(store.t("follow_failed") + (code.isEmpty ? "" : " (\(code))"))
                        .font(.tMeta).foregroundColor(.tDanger)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, TSpace.lg)
                }
            }

            // Chaîne masquée des listes de découverte : la réafficher d'ici.
            if !channelName.isEmpty, store.hidden.hides(channel: channelName) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { store.unhideChannel(channelName) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "eye")
                        Text("\(store.t("hidden_badge")) · \(store.t("unhide"))")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor(.tMuted)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Color.tSurface)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, TSpace.lg)
            }
        }

        if liveData != nil {
            TSegmented(items: channelTabs, selection: $channelTab) { channelTabLabel($0) }
                .onChange(of: channelTab) { loadChannelTab($0) }
                // Onglet masqué pendant qu'il est affiché (Réglages →
                // Personnaliser) : le premier qui reste.
                .onChange(of: channelTabs) { tabs in
                    if !tabs.contains(channelTab), let first = tabs.first { channelTab = first }
                }
        }

        if channelTab == 5 {
            scheduleSection
        } else if channelTab == 4 {
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
                                        leaveRecovery()
                                        onPlayVod(vod.id, vod.title, vod.previewThumbnailURL, channelName)
                                    }
                                    .contextMenu { multiMenu(vod) }
                                    .onAppear {
                                        // Défilement infini : charge la suite quand la
                                        // dernière VOD apparaît.
                                        guard vod.id == filteredVods.last?.id,
                                              hasMoreVods, !isLoadingMore, !searchingOlder else { return }
                                        isLoadingMore = true
                                        Task { await loadMoreVods() }
                                    }
                                case .unlisted(let s):
                                    UnlistedVodCardView(stream: s,
                                                        resolving: resolvingID == s.streamID,
                                                        gone: goneIDs.contains(s.streamID)) {
                                        // Une seule à la fois : la tâche gardée est
                                        // celle qui tourne vraiment.
                                        guard resolvingID == nil else { return }
                                        recoverTask = Task { await recover(s) }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, TSpace.lg)
                    }

                    if isLoadingMore || searchingOlder {
                        TLoader()
                    } else if vodsMoreFailed {
                        TLoadMoreButton(busy: false) {
                            isLoadingMore = true
                            Task { await loadMoreVods() }
                        }
                    } else if vodsRefused {
                        TListEndNote(key: "more_unavailable")
                    } else if !filterText.trimmingCharacters(in: .whitespaces).isEmpty, vodCursor != nil {
                        // Le filtre ne voit que les VODs chargées : sans
                        // correspondance, rien ne demandait la suite.
                        TLoadMoreButton(busy: false, titleKey: "vods_search_older") {
                            Task { await searchOlderVods() }
                        }
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
                        leaveRecovery()
                        onPlayVod(vod.id, vod.title, vod.previewThumbnailURL, channelName)
                    }
                    .contextMenu { multiMenu(vod) }
                }
            }
            .padding(.horizontal, TSpace.lg)
        }
    }

    /// Appui long sur une VOD (ou un temps fort) de la chaîne : le multi-live.
    private func multiMenu(_ vod: VodData) -> some View {
        MultiVodMenuButton(vodId: vod.id, title: vod.title, thumb: vod.previewThumbnailURL,
                           name: channelName, login: channelName)
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
                                leaveRecovery()
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
                                        leaveRecovery()
                                        onPlayVod(vod.id, vod.title, vod.previewThumbnailURL, channelName)
                                    }
                                    .contextMenu { multiMenu(vod) }
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
                        ClipCardView(clip: clip) { leaveRecovery(); onPlayClip(clip.id, clip.title) }
                    }
                }
                .padding(.horizontal, TSpace.lg)

                // Au-delà des 100 premiers : GQL sans compte ; si Twitch le
                // refuse, Helix avec le compte, sinon un message.
                if clipsCursor != nil {
                    TLoadMoreButton(busy: loadingMoreClips) { Task { await loadMoreClips() } }
                } else if clipsLocked {
                    if store.twitchToken != nil {
                        // Connecté depuis le refus : Helix reprend du début.
                        TLoadMoreButton(busy: loadingMoreClips) {
                            clipsCursor = .helix(nil); clipsLocked = false
                            Task { await loadMoreClips() }
                        }
                    } else {
                        TListEndNote(key: "more_needs_login")
                    }
                }
            }
        }
    }

    @MainActor private func loadClips() async {
        let login = searchedName.lowercased()
        guard !login.isEmpty else { return }
        let key = "\(login)|\(clipPeriod)"
        // Retour sur la période déjà affichée (« 24 h » puis aussitôt
        // « Semaine ») : la demande en route pour l'autre sera écartée, rien
        // ne remettrait le chargeur à faux.
        if clipsFor == key, !clips.isEmpty { loadingClips = false; return }
        loadingClips = true
        let result = await getClipsPage(login: login, period: clipPeriod, after: nil)
        guard key == "\(searchedName.lowercased())|\(clipPeriod)" else { return }
        clips = result?.clips ?? []
        if let next = result?.next {
            clipsCursor = .gql(next)
        } else if result?.more == true, store.twitchToken != nil {
            // Suite annoncée sans curseur GQL : Helix la donne avec le compte.
            clipsCursor = .helix(nil)
        } else {
            clipsCursor = nil
        }
        clipsLocked = false
        clipsFor = key
        loadingClips = false
    }

    /// Clips au-delà des 100 premiers : GQL sans compte (Client-ID
    /// d'Android). Si Twitch le refuse, Helix avec le compte, qui repart du
    /// début (ses 100 premiers recouvrent ceux déjà là) : loadMorePages
    /// enchaîne jusqu'à 3 pages pour trouver du neuf.
    @MainActor private func loadMoreClips() async {
        guard let c = clipsCursor, !loadingMoreClips else { return }
        let key = clipsFor
        let login = searchedName.lowercased()
        let period = clipPeriod
        loadingMoreClips = true
        defer { loadingMoreClips = false }
        var broadcaster = liveData?.userId ?? ""
        let result = await loadMorePages(
            after: c, current: clips, token: store.twitchToken,
            gql: { after in
                guard let p = await getClipsPage(login: login, period: period, after: after) else { return nil }
                return (p.clips, p.next, p.refused)
            },
            helix: { token, after in
                if broadcaster.isEmpty { broadcaster = await getUserIdGQL(login: login) ?? "" }
                guard !broadcaster.isEmpty else { return nil }
                let p = await getClipsHelix(token: token, broadcasterId: broadcaster,
                                            period: period, cursor: after)
                return (p.clips, p.cursor)
            })
        guard key == clipsFor else { return }
        clips += result.fresh
        clipsCursor = result.cursor
        clipsLocked = result.locked
    }

    // MARK: – Planning
    /// La chaîne a quelque chose de prévu (créneau à venir, vacances).
    private var hasSchedule: Bool { !(schedule?.isEmpty() ?? true) }

    /// Onglets de la chaîne affichés, dans l'ordre choisi (Réglages →
    /// Personnaliser) ; « Planning » (5) seulement si elle en a un, une
    /// chaîne sans planning n'affichant rien de plus.
    private var channelTabs: [Int] {
        store.customization.visibleChannelTabs.compactMap { key -> Int? in
            if key == "schedule" && !hasSchedule { return nil }
            return Self.channelTabIDs[key]
        }
    }

    /// Clés de la personnalisation (UICustomization.defaultChannelTabs).
    private static let channelTabIDs: [String: Int] = [
        "vods": 0, "highlights": 1, "playlists": 2, "clips": 3, "about": 4, "schedule": 5]

    /// Contenu d'un onglet, chargé quand il s'affiche (les VODs et le
    /// planning viennent avec la page).
    private func loadChannelTab(_ tab: Int) {
        switch tab {
        case 1:  Task { await loadHighlights() }
        case 2:  Task { await loadPlaylists() }
        case 3:  Task { await loadClips() }
        case 4:  Task { await loadAbout() }
        default: break
        }
    }

    private func channelTabLabel(_ tab: Int) -> String {
        switch tab {
        case 1:  return store.t("highlights")
        case 2:  return store.t("playlists")
        case 3:  return store.t("clips")
        case 4:  return store.t("about")
        case 5:  return store.t("sched_tab")
        default: return store.t("vods")
        }
    }

    @ViewBuilder private var scheduleSection: some View {
        if let schedule {
            ChannelScheduleView(schedule: schedule)
        } else {
            TEmptyState(icon: "calendar", title: store.t("sched_none"))
        }
    }

    /// Planning lu en arrière-plan, à l'ouverture de la chaîne : sans lui, la
    /// page s'affiche comme avant.
    @MainActor private func loadSchedule(login: String, channelId: String?) async {
        let result = await getChannelSchedule(login: login, channelId: channelId, token: store.twitchToken)
        // Autre chaîne ouverte pendant l'attente : pas son planning.
        guard login == searchedName else { return }
        // Page encore sur l'onglet qu'elle a ouvert : le planning, placé en
        // tête (Réglages → Personnaliser), prend sa place.
        let untouched = channelTab == channelTabs.first
        schedule = result
        if untouched, !(result?.isEmpty() ?? true),
           store.customization.visibleChannelTabs.first == "schedule" {
            channelTab = 5
        }
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
        let login = searchedName
        resolvingID = s.streamID
        goneIDs.remove(s.streamID)
        let links = await recovery.resolve(s)
        // Abandonnée (autre chaîne ouverte, page quittée) : rien ne s'ouvre,
        // et la carte n'est pas marquée perdue.
        guard !Task.isCancelled, login == searchedName else {
            if resolvingID == s.streamID { resolvingID = nil }
            return
        }
        resolvingID = nil
        recoverTask = nil
        if let links, !links.isEmpty {
            onRecovered(RecoveredVod(
                streamID: s.streamID,
                title: s.title.isEmpty ? s.login : s.title,
                streamer: s.login, links: links))
        } else {
            goneIDs.insert(s.streamID)
        }
    }

    /// Autre lecture lancée d'ici (direct, VOD, playlist, clip) : la
    /// reconstruction en cours est abandonnée. Dans l'onglet Recherche, la
    /// page reste sous le lecteur et rien ne l'annulait : en aboutissant, elle
    /// ouvrait la VOD retrouvée à la place de ce qu'on venait de lancer.
    private func leaveRecovery() {
        recoverTask?.cancel()
        recoverTask = nil
        resolvingID = nil
    }

    // MARK: – Actions
    /// « Réessayer » sous l'erreur : la page de la même chaîne, redemandée.
    private var retryAction: (() -> Void)? {
        guard let login = retryLogin else { return nil }
        return { Task { await searchChannel(login) } }
    }

    /// Aiguille selon ce qui a été saisi : VOD, clip ou chaîne collés
    /// s'ouvrent directement ; tout autre texte part en recherche.
    @MainActor private func submit() async {
        let raw = query.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        // Lien de clip : lu tout de suite. Avant, « clips.twitch.tv/Slug »
        // cherchait une chaîne « slug » et « twitch.tv/x/clip/… » ouvrait x.
        if let slug = clipSlugFromInput(raw) {
            suggestions = []
            leaveRecovery()
            onPlayClip(slug, nil)
            return
        }
        if queryIsVod {
            await openVod(raw)
        } else if queryIsChannelLink {
            await searchChannel(raw)
        } else {
            runSearch(raw)
        }
    }

    /// Recherche par texte : la page de chaîne se referme, les résultats en
    /// onglets la remplacent, et le texte rejoint les recherches récentes.
    @MainActor private func runSearch(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        suggestTask?.cancel()
        suggestions = []
        closeChannel()
        openedCategory = nil
        resultsTab = .channels
        store.saveSearch(t)
        found.search(t, token: store.twitchToken)
    }

    /// Page de chaîne (ou message d'erreur) refermée : retour aux résultats
    /// de la recherche. Ce qui était en route pour elle est écarté.
    @MainActor private func closeChannel() {
        leaveRecovery()
        // Chargement d'une chaîne en route : il n'aboutira plus (son nom n'est
        // plus celui affiché) et ne remettrait pas le chargeur à faux.
        loading = false
        searchedName = ""; liveData = nil; schedule = nil
        errorMsg = nil; retryLogin = nil
        follow.reset(); confirmUnfollow = false
    }

    @MainActor private func openVod(_ raw: String) async {
        guard let vodId = extractVodId(raw) else {
            errorMsg = store.t("err_bad_vod"); retryLogin = nil; return
        }
        loading = true; errorMsg = nil; retryLogin = nil; searchedName = ""
        suggestions = []

        async let metaTask = getVodMetaGQL(vodId)
        async let m3u8Task = getM3U8(vodId: vodId)
        let (meta, m3u8) = await (metaTask, m3u8Task)
        loading = false

        guard !(m3u8.links.isEmpty && m3u8.error != nil) else {
            errorMsg = m3u8.error.map { store.t(apiErrorKey($0)) }; return
        }
        // « ?t=1h2m3s » du lien : la VOD part de là (le lecteur reprend à la
        // position enregistrée).
        if let start = vodStartFromInput(raw) { store.setVodProgress(vodId, time: start) }
        // La lecture passe par le lecteur global : l'historique y est enregistré.
        onPlayVod(vodId, meta?.title ?? "VOD \(vodId)", meta?.thumb,
                  meta.flatMap { $0.streamer.isEmpty ? nil : $0.streamer })
    }

    @MainActor private func searchChannel(_ name: String) async {
        // Lien Twitch collé (« twitch.tv/xqc », « https://www.twitch.tv/xqc/clips ») :
        // on en garde la chaîne ; « @xqc » donne xqc (TwitchAPI).
        let login = loginFromInput(name)
        guard !login.isEmpty else { return }

        loading = true; errorMsg = nil; retryLogin = nil; liveData = nil; lastBroadcastAt = nil; vods = []
        // Le suivi de la chaîne précédente ne doit ni s'afficher ni se modifier ici.
        follow.reset(); confirmUnfollow = false
        filterText = ""; searchedName = login; suggestions = []
        clips = []; clipsFor = ""; loadingClips = false
        clipsLocked = false; clipsCursor = nil; loadingMoreClips = false
        about = nil; aboutFor = ""; loadingAbout = false; schedule = nil
        // Le premier onglet affiché ; le planning, lu après la page, n'y
        // est pas encore (loadSchedule y passe s'il est en tête).
        channelTab = channelTabs.first(where: { $0 != 5 }) ?? 0
        // Reconstruction de la chaîne précédente : abandonnée.
        recoverTask?.cancel(); recoverTask = nil
        resolvingID = nil; goneIDs = []
        playlists = []; playlistsFor = ""; loadingPlaylists = false
        highlights = []; highlightsFor = ""; loadingHighlights = false
        vodCursor = nil; hasMoreVods = false; isLoadingMore = false
        vodsRefused = false; vodsMoreFailed = false; searchingOlder = false

        // Lien vers une page du site (« twitch.tv/settings »), ou saisie qui
        // ne peut pas être un nom de chaîne : inutile de demander à Twitch.
        guard isValidLogin(login) else {
            errorMsg = store.t("not_found")
            searchedName = ""
            loading = false
            return
        }

        // Le bandeau ne demande que les infos de la chaîne : plus de
        // résolution du direct (proxys, jusqu'à une minute par miroir muet),
        // que « Regarder » refait de toute façon.
        async let infoTask   = getChannelInfo(channelName: login)
        async let videosTask = getChannelVideos(channelName: login)
        let (info, ch) = await (infoTask, videosTask)
        let live = info.live

        // Une autre recherche est partie pendant l'attente (ou une VOD a été
        // ouverte) : c'est elle qui conclut ; ces résultats ne s'écrivent pas
        // sous son nom.
        guard login == searchedName else { return }

        avatarURL = live.avatar ?? ch.avatar ?? ""

        if live.error != nil && ch.error != nil && live.avatar == nil {
            // Twitch n'a pas répondu : ce n'est pas « introuvable », et on
            // peut réessayer.
            errorMsg = store.t(live.error == "network" ? "err_loading" : "not_found")
            if live.error == "network" { retryLogin = login }
            searchedName = ""
        } else {
            // Photo gardée dans l'historique, comme le site l'y met.
            store.saveToHistory(HistoryItem(
                term: login, type: .channel, display: login,
                thumb: nil, streamer: nil,
                addedAt: Date().timeIntervalSince1970 * 1000,
                avatar: avatarURL.isEmpty ? nil : avatarURL))
            liveData    = live
            lastBroadcastAt = info.lastStart
            Task { await loadFollowState(login: login, channelId: live.userId) }
            // Planning : onglet et « Prochain live » s'il y en a un.
            Task { await loadSchedule(login: login, channelId: live.userId) }
            vods        = ch.videos
            vodCursor   = ch.cursor
            hasMoreVods = ch.cursor != nil
            // VODs non listées : en arrière-plan, la grille s'affiche sans attendre.
            Task { await recovery.load(channel: login) }
            // Page ouverte sur un autre onglet que les VODs : son contenu.
            loadChannelTab(channelTab)
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

    /// Suite des VODs (défilement infini) : au-delà des 100 premières, Twitch
    /// ne la donne qu'au Client-ID d'Android (getChannelVideosPage).
    @MainActor private func loadMoreVods() async {
        let login = searchedName.lowercased()
        guard let cursor = vodCursor, !login.isEmpty else {
            isLoadingMore = false; return
        }
        vodsMoreFailed = false
        let ch = await getChannelVideosPage(channelName: login, cursor: cursor)
        // Autre chaîne ouverte pendant l'attente : cette page n'est pas la sienne.
        guard login == searchedName.lowercased() else { return }
        isLoadingMore = false
        if ch.refused {
            // Se connecter n'y changerait rien : pas de secours Helix ici.
            vodCursor = nil; hasMoreVods = false; vodsRefused = true
            return
        }
        if ch.error != nil {
            // Panne réseau : on garde le curseur, un bouton permet de réessayer.
            hasMoreVods = false; vodsMoreFailed = true
            return
        }
        let known = Set(vods.map(\.id))
        let fresh = ch.videos.filter { !known.contains($0.id) }
        vods += fresh
        vodCursor   = ch.cursor
        hasMoreVods = ch.cursor != nil && !fresh.isEmpty
    }

    /// Filtre par mot-clé : il ne voit que les VODs chargées. Page après
    /// page (5 au plus par toucher, soit 500 VODs), jusqu'à ce que la suite
    /// apporte une nouvelle correspondance, s'arrête ou échoue.
    @MainActor private func searchOlderVods() async {
        let login = searchedName.lowercased()
        guard !login.isEmpty, !searchingOlder, !isLoadingMore else { return }
        searchingOlder = true
        defer { searchingOlder = false }
        let before = filteredVods.count
        for _ in 0..<5 {
            guard vodCursor != nil, login == searchedName.lowercased() else { break }
            isLoadingMore = true
            await loadMoreVods()
            guard login == searchedName.lowercased() else { break }
            if filteredVods.count > before || vodsMoreFailed || vodsRefused { break }
        }
    }

    /// Suggestions de chaînes, différées de 300 ms pour ne pas appeler à chaque frappe.
    private func suggest(_ text: String) {
        suggestTask?.cancel()
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, !queryIsVod, !queryIsClip else { suggestions = []; return }
        suggestTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let found = await searchUsersGQL(t)
            guard !Task.isCancelled else { return }
            await MainActor.run { suggestions = Array(found.prefix(5)) }
        }
    }
}
