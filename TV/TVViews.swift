import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Écrans de l'app Apple TV : onglets en haut, cartes à la télécommande
//  (style « card » de tvOS : la carte qui a le focus se soulève).
// ═══════════════════════════════════════════════════════════════════════════

/// Ce que le lecteur doit lire.
enum TVPlayback: Identifiable, Hashable {
    case live(login: String, name: String)
    case vod(id: String, title: String, channel: String)

    var id: String {
        switch self {
        case .live(let login, _): return "live-\(login)"
        case .vod(let id, _, _):  return "vod-\(id)"
        }
    }

    /// Chaîne regardée (login) : le chat garde sa place propre à chacune.
    var channel: String {
        switch self {
        case .live(let login, _):   return login.lowercased()
        case .vod(_, _, let login): return login.lowercased()
        }
    }
}

/// Page d'une chaîne ouverte depuis le lecteur (bouton « Chaîne »).
struct TVChannelRoute: Identifiable {
    let login: String
    var id: String { login }
}

/// Chaîne hors ligne choisie avec le bouton Play : sa page s'ouvre et sa
/// dernière vidéo (ou son live, s'il a commencé entre-temps) se lance.
struct TVAutoplay: Hashable {
    let login: String
}

struct TVRootView: View {
    @EnvironmentObject private var session: TVSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var playing: TVPlayback?
    /// « Chaîne » touché dans le lecteur : sa page s'ouvre une fois celui-ci fermé.
    @State private var pendingChannel: String?
    @State private var channelPage: TVChannelRoute?

    enum Tab: Hashable { case following, top, categories, search, account }
    @State private var tab = Tab.following

    var body: some View {
        // Choisir de nouveau « Suivies » ne passe pas par la sélection sur
        // tvOS (elle suit le focus) : l'onglet se recharge quand le focus
        // revient de la barre des onglets (TVFollowingTab.cardFocus).
        TabView(selection: $tab) {
            TVFollowingTab(play: play)
                .tabItem { Text(session.t("tv_following")) }
                .tag(Tab.following)
            TVTopTab(play: play)
                .tabItem { Text(session.t("tv_top")) }
                .tag(Tab.top)
            TVCategoriesTab(play: play)
                .tabItem { Text(session.t("tv_categories")) }
                .tag(Tab.categories)
            TVSearchTab(play: play)
                .tabItem { Text(session.t("tv_search")) }
                .tag(Tab.search)
            TVAccountTab()
                .tabItem { Text(session.t("tv_account")) }
                .tag(Tab.account)
        }
        .fullScreenCover(item: $playing, onDismiss: openPendingChannel) { item in
            TVPlayerScreen(item: item, onChannel: { login in
                pendingChannel = login
                playing = nil
            })
            .environmentObject(session)
        }
        .fullScreenCover(item: $channelPage) { route in
            TVChannelCover(login: route.login)
                .environmentObject(session)
        }
        .task {
            await session.restore()
            await TVUsage.ping(token: session.token, lang: session.lang)
        }
        // Retour dans l'app : signal d'utilisation (/stats), un par heure au plus.
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task { await TVUsage.ping(token: session.token, lang: session.lang) }
        }
    }

    private func play(_ item: TVPlayback) { playing = item }

    private func openPendingChannel() {
        guard let login = pendingChannel else { return }
        pendingChannel = nil
        channelPage = TVChannelRoute(login: login)
    }
}

/// Page d'une chaîne par-dessus les onglets, avec son propre lecteur : une
/// vidéo lancée d'ici s'ouvre au-dessus, Menu ramène à la page puis aux onglets.
struct TVChannelCover: View {
    let login: String
    @EnvironmentObject private var session: TVSession
    @Environment(\.dismiss) private var dismiss
    @State private var playing: TVPlayback?

    var body: some View {
        NavigationStack {
            TVChannelView(login: login, play: { playing = $0 })
                // Sur la page elle-même (pas une page ouverte depuis) : Menu
                // referme et rend les onglets.
                .onExitCommand { dismiss() }
                .navigationDestination(for: String.self) { other in
                    TVChannelView(login: other, play: { playing = $0 })
                }
        }
        // Fond opaque : la feuille plein écran de tvOS n'en a pas, l'onglet
        // d'où l'on venait se voyait à travers la page.
        .background(Color.black.ignoresSafeArea())
        // « Chaîne » dans ce lecteur-ci : la page est juste dessous.
        .fullScreenCover(item: $playing) { item in
            TVPlayerScreen(item: item, onChannel: { _ in playing = nil })
                .environmentObject(session)
        }
    }
}

// MARK: – Suivies
struct TVFollowingTab: View {
    let play: (TVPlayback) -> Void
    @EnvironmentObject private var session: TVSession
    @Environment(\.scenePhase) private var scenePhase
    /// Chargée une fois, la liste gardait des lives finis jusqu'au
    /// redémarrage de l'app : relue au retour sur l'onglet ou dans l'app (au
    /// bout d'une minute), et toutes les 2 minutes tant qu'elle est affichée.
    @State private var lastLoad = Date.distantPast
    @State private var visible = false
    @State private var streams: [TwitchStream] = []
    /// Chaînes suivies hors ligne, dernier live le plus récent d'abord : leur
    /// page s'ouvre pour voir leurs vidéos.
    @State private var offline: [ChannelBrief] = []
    @State private var loading = false
    @State private var failed = false
    @State private var path = NavigationPath()
    /// Cartes de la liste qui ont le focus (0 : il est dans la barre des
    /// onglets, ou sur une page ouverte d'ici), et depuis quand aucune.
    @State private var focusedCards = 0
    @State private var unfocusedSince = Date.distantPast
    private let offlineColumns = Array(repeating: GridItem(.flexible(), spacing: 40), count: 6)

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                if session.token == nil {
                    TVMessage(text: session.t("tv_need_login"))
                } else {
                    if streams.isEmpty {
                        TVMessage(text: loading ? session.t("loading")
                                  : (failed ? session.t("tv_error") : session.t("tv_no_live")))
                    } else {
                        TVStreamGrid(streams: streams, play: play)
                    }
                    if !offline.isEmpty { offlineSection }
                }
            }
            .environment(\.tvCardFocusReport, cardFocus)
            .navigationDestination(for: String.self) { login in
                TVChannelView(login: login, play: play)
            }
            .navigationDestination(for: TVAutoplay.self) { target in
                TVChannelView(login: target.login, play: play, autoplay: true)
            }
        }
        // Relancé quand le compte arrive (connexion, ou lancement).
        .task(id: session.user?.id) { await load() }
        .onAppear {
            visible = true
            if Date().timeIntervalSince(lastLoad) > 60 { Task { await load() } }
        }
        .onDisappear { visible = false }
        .onChange(of: scenePhase) { phase in
            if phase == .active, visible, Date().timeIntervalSince(lastLoad) > 60 { Task { await load() } }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
                if visible, scenePhase == .active { await load() }
            }
        }
    }

    private var offlineSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text(session.t("tv_offline_channels")).font(.title3.bold())
            LazyVGrid(columns: offlineColumns, spacing: 48) {
                ForEach(offline) { c in
                    NavigationLink(value: c.login) {
                        VStack(spacing: 12) {
                            TVAvatar(url: c.avatar, size: 120)
                            Text(c.name).font(.callout.bold()).lineLimit(1)
                            if let end = c.lastEnd {
                                Text(lastLive(end)).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity)
                    }
                    .tvCard()
                    // Play : la page de la chaîne, et sa dernière vidéo lancée.
                    .onPlayPauseCommand { path.append(TVAutoplay(login: c.login)) }
                }
            }
        }
        .padding(.horizontal, 64)
        .padding(.vertical, 32)
    }

    /// Le focus revient sur la liste depuis la barre des onglets (Sélection
    /// sur « Suivies » déjà affiché), ou depuis une page ouverte d'ici : la
    /// liste est relue, au plus toutes les 10 s. Passer d'une carte à
    /// l'autre ne laisse aucune carte sans focus plus d'un instant.
    private func cardFocus(_ on: Bool) {
        if on {
            if focusedCards == 0, Date().timeIntervalSince(unfocusedSince) > 0.4,
               Date().timeIntervalSince(lastLoad) > 10 {
                Task { await load() }
            }
            focusedCards += 1
        } else {
            focusedCards = max(0, focusedCards - 1)
            if focusedCards == 0 { unfocusedSince = Date() }
        }
    }

    /// « il y a 2 j » : fin du dernier live, dans la langue de l'app.
    private func lastLive(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: session.lang.rawValue)
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func load() async {
        // Compte pas chargé au lancement (Apple TV sortie de veille avant le
        // Wi-Fi) : relu ici. Sinon « Aucun live » restait toute la séance ;
        // toujours absent, c'est une erreur (Réessayer en revenant), pas un vide.
        if session.user == nil, session.token != nil { await session.restore() }
        guard let uid = session.user?.id, let token = session.token else {
            streams = []; offline = []
            failed = session.token != nil
            return
        }
        // Deux demandes rapprochées (retour sur l'onglet, puis minuterie) : une seule.
        guard !loading else { return }
        lastLoad = Date()
        loading = true
        if let list = try? await getFollowedStreams(token: token, userId: uid) {
            streams = list
            failed = false
        } else if let fresh = await session.renewToken(),
                  let list = try? await getFollowedStreams(token: fresh, userId: uid) {
            // Jeton expiré : renouvelé une fois.
            streams = list
            failed = false
        } else {
            failed = true
        }
        loading = false
        // Ensuite : les lives s'affichent sans attendre la liste hors ligne.
        await loadOffline(userId: uid)
    }

    /// Tous les suivis (Helix, les 200 plus récents) sauf ceux en live, avec
    /// avatar et fin du dernier live (GQL public). Échec : la liste reste.
    private func loadOffline(userId: String) async {
        guard let token = session.token,
              let logins = await getFollowedLogins(token: token, userId: userId) else { return }
        let live = Set(streams.map { $0.userLogin.lowercased() })
        let rest = Array(logins.map { $0.lowercased() }.filter { !live.contains($0) }.prefix(200))
        guard let infos = await getChannelsGQL(logins: rest) else { return }
        offline = infos.filter { $0.stream == nil }
            .sorted { ($0.lastEnd ?? .distantPast) > ($1.lastEnd ?? .distantPast) }
    }
}

// MARK: – Top
struct TVTopTab: View {
    let play: (TVPlayback) -> Void
    @EnvironmentObject private var session: TVSession
    @State private var worldwide = false
    /// 1ʳᵉ page du top (30), telle que Twitch l'envoie.
    @State private var streams: [TwitchStream] = []
    /// Sa suite (page 2, Client-ID d'Android), chargée seulement quand des
    /// lives masqués laissent moins de 24 cartes ; `next` : son curseur.
    @State private var extra: [TwitchStream] = []
    @State private var next: String? = nil
    @State private var loading = false

    var body: some View {
        // Masqués écartés, dans l'ordre de Twitch, 30 au plus comme avant.
        // L'Apple TV ne connaît pas les suivis ici : pas d'exception pour eux.
        let top = HiddenContent.fill(top: streams, extra: extra,
                                     keep: { session.hidden.allows($0) }, limit: 30)
        NavigationStack {
            ScrollView {
                Picker("", selection: $worldwide) {
                    Text(TopLanguage.name(TopLanguage.device, in: session.lang)).tag(false)
                    Text(session.t("tv_world")).tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 800)
                .padding(.top, 24)

                if top.streams.isEmpty {
                    TVMessage(text: loading ? session.t("loading") : session.t("tv_no_live"))
                } else {
                    TVStreamGrid(streams: top.streams, play: play, hideable: true)
                }
            }
        }
        .task(id: worldwide) {
            loading = true
            extra = []
            next = nil
            let page = await getTopStreamsPageGQL(lang: worldwide ? nil : TopLanguage.device, after: nil)
            streams = page?.streams ?? []
            next = page?.next
            loading = false
            await refill()
        }
        .onChange(of: session.hidden) { _ in Task { await refill() } }
    }

    /// Moins de 24 lives visibles une fois les masqués écartés : la page 2
    /// du top, exacte et dans l'ordre de Twitch. Une seule fois par top.
    private func refill() async {
        guard extra.isEmpty, let after = next, !session.hidden.isEmpty else { return }
        let visible = HiddenContent.fill(top: streams, keep: { session.hidden.allows($0) }).streams.count
        guard visible < 24 else { return }
        let w = worldwide
        guard let page = await getTopStreamsPageGQL(lang: w ? nil : TopLanguage.device, after: after),
              !page.refused else { return }
        // Top rechargé entre-temps (autre langue) : cette suite n'est plus la sienne.
        guard w == worldwide, next == after else { return }
        extra = page.streams
    }
}

// MARK: – Catégories
struct TVCategoriesTab: View {
    let play: (TVPlayback) -> Void
    @EnvironmentObject private var session: TVSession
    @State private var categories: [TwitchCategory] = []
    @State private var loaded = false
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 40), count: 6)

    var body: some View {
        NavigationStack {
            ScrollView {
                if categories.isEmpty {
                    TVMessage(text: loaded ? session.t("tv_error") : session.t("loading"))
                } else {
                    LazyVGrid(columns: columns, spacing: 48) {
                        ForEach(categories.filter { !session.hidden.hides(category: $0.id) }) { c in
                            NavigationLink(value: c) {
                                TVCategoryCard(category: c)
                            }
                            .tvCard()
                            // Bouton central maintenu : masquer la catégorie.
                            .contextMenu {
                                Button(role: .destructive) {
                                    session.hidden.hide(category: c.id, name: c.name, box: c.boxArtURL)
                                } label: {
                                    Label(session.t("hide_this_category"), systemImage: "eye.slash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 64)
                    .padding(.vertical, 32)
                }
            }
            .navigationDestination(for: TwitchCategory.self) { c in
                TVCategoryStreams(category: c, play: play)
            }
        }
        .task {
            guard categories.isEmpty else { return }
            categories = await getTopCategoriesGQL() ?? []
            loaded = true
        }
    }
}

struct TVCategoryCard: View {
    let category: TwitchCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TVThumbnail(url: sharpBoxArt(category.boxArtURL), ratio: 3 / 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(category.name).font(.headline).lineLimit(1)
                if let v = category.viewers {
                    Text(formatViewers(v)).font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TVCategoryStreams: View {
    let category: TwitchCategory
    let play: (TVPlayback) -> Void
    @EnvironmentObject private var session: TVSession
    @State private var streams: [TwitchStream] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            Text(category.name)
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 64)
            // Chaînes masquées écartées ; la catégorie, ouverte exprès, reste
            // consultable même masquée.
            let shown = streams.filter { !session.hidden.hides(channel: $0.userLogin) }
            if shown.isEmpty {
                TVMessage(text: loaded ? session.t("tv_no_live") : session.t("loading"))
            } else {
                TVStreamGrid(streams: shown, play: play, hideable: true, hideCategory: false)
            }
        }
        .task {
            streams = await getStreamsByCategoryGQL(gameId: category.id) ?? []
            loaded = true
        }
    }
}

// MARK: – Recherche
struct TVSearchTab: View {
    let play: (TVPlayback) -> Void
    @EnvironmentObject private var session: TVSession
    @State private var query = ""
    @State private var results: [AutocompleteSuggestion] = []
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(results) { r in
                        NavigationLink(value: r.login) {
                            HStack(spacing: 24) {
                                TVAvatar(url: r.avatar, size: 80)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(r.name).font(.headline)
                                    if let v = r.viewers {
                                        Text(session.t("tv_live") + " · " + formatViewers(v) + (r.game.map { " · \($0)" } ?? ""))
                                            .font(.caption)
                                            .foregroundColor(Color.tLive)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                        }
                        // Play : le live s'il y en a un, sinon la page de la
                        // chaîne et sa dernière vidéo.
                        .onPlayPauseCommand {
                            if r.viewers != nil { play(.live(login: r.login, name: r.name)) }
                            else { path.append(TVAutoplay(login: r.login)) }
                        }
                    }
                }
                .padding(.horizontal, 64)
            }
            .searchable(text: $query, prompt: session.t("tv_search_prompt"))
            .navigationDestination(for: String.self) { login in
                TVChannelView(login: login, play: play)
            }
            .navigationDestination(for: TVAutoplay.self) { target in
                TVChannelView(login: target.login, play: play, autoplay: true)
            }
        }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { results = []; return }
            // Une requête après la frappe, pas une par lettre.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            results = await searchUsersGQL(q)
        }
    }
}

// MARK: – Chaîne : live éventuel et VODs
struct TVChannelView: View {
    let login: String
    let play: (TVPlayback) -> Void
    /// Ouverte avec le bouton Play : le live, sinon la dernière vidéo, se
    /// lance une fois chargée (une seule fois : pas à chaque retour du lecteur).
    var autoplay = false
    @EnvironmentObject private var session: TVSession
    @State private var videos: [VodData] = []
    @State private var avatar: String?
    @State private var live: TwitchStream?
    @State private var loaded = false
    @State private var autoplayed = false
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 48), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack(spacing: 28) {
                    TVAvatar(url: avatar, size: 120)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(live?.userName ?? login).font(.title2.bold())
                        if let live {
                            Text(live.title).font(.callout).foregroundColor(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    if let live {
                        Button {
                            play(.live(login: login, name: live.userName))
                        } label: {
                            Label(session.t("tv_watch_live"), systemImage: "play.fill")
                        }
                        .onPlayPauseCommand { play(.live(login: login, name: live.userName)) }
                    }
                }
                // Toute la largeur reçoit le focus : « Regarder le live », à
                // droite, n'était atteint en montant que depuis la vidéo
                // juste dessous (tvOS cherche ce qui est au-dessus).
                .focusSection()

                Text(session.t("tv_videos")).font(.title3.bold())
                if videos.isEmpty {
                    TVMessage(text: loaded ? session.t("tv_no_videos") : session.t("loading"))
                } else {
                    LazyVGrid(columns: columns, spacing: 56) {
                        ForEach(videos) { v in
                            Button {
                                play(.vod(id: v.id, title: v.title, channel: login))
                            } label: {
                                TVVodCard(video: v)
                            }
                            .tvCard()
                            .onPlayPauseCommand { play(.vod(id: v.id, title: v.title, channel: login)) }
                        }
                    }
                }
            }
            .padding(.horizontal, 64)
            .padding(.vertical, 32)
        }
        .task {
            async let channelVideos = getChannelVideos(channelName: login)
            async let liveStreams = getLiveStreamsGQL(logins: [login])
            let result = await channelVideos
            let streams = await liveStreams
            videos = result.videos
            avatar = result.avatar
            live = streams?.first
            loaded = true
            if autoplay, !autoplayed {
                autoplayed = true
                if let live {
                    play(.live(login: login, name: live.userName))
                } else if let last = videos.first {
                    // Vidéos du plus récent au plus ancien : le dernier live.
                    play(.vod(id: last.id, title: last.title, channel: login))
                }
            }
        }
    }
}

// MARK: – Compte et réglages
struct TVAccountTab: View {
    @EnvironmentObject private var session: TVSession
    @ObservedObject private var appLogger = AppLogger.shared
    /// Signal d'utilisation pour /stats (TVUsage) : coupé, le serveur oublie tout.
    @AppStorage(TVUsage.enabledKey) private var shareUsage = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 56) {
                if session.token != nil {
                    HStack(spacing: 28) {
                        TVAvatar(url: session.user?.profileImageURL, size: 120)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(session.user?.displayName ?? "…").font(.title2.bold())
                            Text(session.t("tv_logged_in")).foregroundColor(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button(session.t("tv_logout")) { session.logout() }
                    }
                    // Toute la largeur : en remontant depuis « Langue », le
                    // focus trouve ce bouton puis la barre des onglets.
                    .focusSection()
                } else if let code = session.pendingCode {
                    loginPanel(code)
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        Text(session.t("tv_login_intro")).font(.title3)
                        Button(session.t("tv_login")) { session.startLogin() }
                        if session.loginFailed {
                            Text(session.t("tv_login_expired")).foregroundColor(Color.tWarning)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusSection()
                }

                VStack(alignment: .leading, spacing: 32) {
                    Text(session.t("tv_settings")).font(.title3.bold())
                    TVChoiceRow(title: session.t("tv_language"),
                                options: Lang.allCases.map { ($0.rawValue, $0.label) },
                                selection: Binding(get: { session.lang.rawValue },
                                                   set: { session.lang = Lang(rawValue: $0) ?? .en }))
                    TVChoiceRow(title: session.t("live_source"),
                                options: kLiveSourceChoices.map { ($0, session.t("src_\($0)")) },
                                selection: $session.liveSource)
                    TVChoiceRow(title: session.t("pref_quality"),
                                options: kQualityPrefs.map { pref -> (String, String) in
                                    (pref, pref == "source" ? session.t("q_source")
                                         : pref == "audio" ? session.t("tv_audio") : "\(pref)p")
                                },
                                selection: $session.qualityPref)
                    TVChoiceRow(title: session.t("tv_chat_default"),
                                options: [("on", session.t("tv_chat_on")), ("off", session.t("tv_chat_off"))],
                                selection: Binding(get: { session.tvChat ? "on" : "off" },
                                                   set: { session.tvChat = $0 == "on" }))
                    TVChoiceRow(title: session.t("tv_chat_side"),
                                options: TVChatLayout.Side.allCases.map { ($0.rawValue, session.t("tv_chat_\($0.rawValue)")) },
                                selection: Binding(get: { session.chatLayout.side.rawValue },
                                                   set: { session.chatLayout.side = TVChatLayout.Side(rawValue: $0) ?? .right }))
                    TVChoiceRow(title: session.t("tv_chat_height"),
                                options: TVChatLayout.Height.allCases.map { ($0.rawValue, session.t("tv_chat_\($0.rawValue)")) },
                                selection: Binding(get: { session.chatLayout.height.rawValue },
                                                   set: { session.chatLayout.height = TVChatLayout.Height(rawValue: $0) ?? .full }))
                    Text(session.t("tv_chat_layout_hint")).foregroundColor(.secondary)
                    if session.channelsWithOwnChat > 0 {
                        Button("\(session.t("tv_chat_forget")) (\(session.channelsWithOwnChat))") {
                            session.forgetChannelChatLayouts()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .focusSection()
                    }
                    TVChoiceRow(title: session.t("usage_share"),
                                options: [("on", session.t("tv_on")), ("off", session.t("tv_off"))],
                                selection: Binding(get: { shareUsage ? "on" : "off" }, set: { value in
                                    let on = value == "on"
                                    guard on != shareUsage else { return }
                                    shareUsage = on
                                    let token = session.token, lang = session.lang
                                    Task {
                                        if on { await TVUsage.ping(token: token, lang: lang) }
                                        else { await TVUsage.forget(token: token) }
                                    }
                                }))
                    Text(session.t("tv_usage_sub")).foregroundColor(.secondary)
                }

                hiddenSection

                logsSection
            }
            .padding(64)
        }
        // L'attente du code n'est plus annulée en quittant l'onglet (TVSession).
    }

    /// Erreurs et alertes récentes du journal (gardé entre les lancements) :
    /// l'Apple TV n'avait aucun moyen de les voir pour décrire un problème.
    @ViewBuilder private var logsSection: some View {
        let recent = Array(appLogger.logs.filter { $0.level == .error || $0.level == .warn }.prefix(30))
        VStack(alignment: .leading, spacing: 24) {
            Text(session.t("tv_logs_title")).font(.title3.bold())
            if recent.isEmpty {
                Text(session.t("tv_logs_empty")).foregroundColor(.secondary)
            } else {
                ForEach(recent) { e in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(e.timestamp) · \(e.category)\(e.repeats > 1 ? " ×\(e.repeats)" : "")")
                            .font(.caption)
                            .foregroundColor(e.level == .error ? .red : .orange)
                        Text(LogTranslator.translate(e.message, session.lang)).font(.callout)
                        if let d = e.detail {
                            Text(LogTranslator.translate(d, session.lang))
                                .font(.caption2).foregroundColor(.secondary).lineLimit(3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Lignes atteignables à la télécommande : la liste défile.
                    .focusable()
                }
                Button(session.t("logs_clear")) { appLogger.clear() }
            }
        }
        .focusSection()
    }

    /// Chaînes et catégories masquées : un bouton par élément pour le
    /// réafficher (les 50 plus récents), et « Tout réafficher ».
    @ViewBuilder private var hiddenSection: some View {
        let hidden = session.hidden
        VStack(alignment: .leading, spacing: 24) {
            Text(session.t("hidden_title")).font(.title3.bold())
            Text(session.t("tv_hidden_hint")).foregroundColor(.secondary)
            if !hidden.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 24) {
                        ForEach(hidden.channels.prefix(50)) { c in
                            Button {
                                session.hidden.unhide(channel: c.login)
                            } label: {
                                Label("\(c.name) · \(session.t("unhide"))", systemImage: "person.fill")
                            }
                        }
                        ForEach(hidden.categories.prefix(50)) { c in
                            Button {
                                session.hidden.unhide(category: c.id)
                            } label: {
                                Label("\(c.name.isEmpty ? c.id : c.name) · \(session.t("unhide"))",
                                      systemImage: "square.grid.2x2")
                            }
                        }
                    }
                    .padding(.vertical, 20)
                }
                .focusSection()
                Button(session.t("unhide_all")) { session.hidden.unhideAll() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusSection()
            }
        }
    }

    private func loginPanel(_ c: TVSession.DeviceCode) -> some View {
        HStack(alignment: .center, spacing: 80) {
            if let qr = tvQRCode(c.verificationURL) {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 360, height: 360)
                    .padding(20)
                    .background(Color.white)
                    .cornerRadius(16)
            }
            VStack(alignment: .leading, spacing: 24) {
                Text(session.t("tv_login_steps")).font(.title3)
                Text("twitch.tv/activate").font(.title2.bold()).foregroundColor(Color.tPurple)
                Text(session.t("tv_login_code")).font(.title3)
                Text(c.userCode)
                    .font(.system(size: 72, weight: .heavy, design: .monospaced))
                HStack(spacing: 16) {
                    ProgressView()
                    Text(session.t("tv_login_waiting")).foregroundColor(.secondary)
                }
                // L'attente ne s'arrête plus en changeant d'onglet : on peut
                // l'abandonner ici.
                Button(session.t("cancel")) { session.cancelLogin() }
            }
        }
    }
}

/// Un choix parmi quelques valeurs : une rangée de boutons, coche sur la valeur
/// retenue (plus simple à la télécommande qu'un menu).
struct TVChoiceRow: View {
    let title: String
    let options: [(String, String)]
    @Binding var selection: String
    @FocusState private var focused: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline).foregroundColor(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(options.indices, id: \.self) { i in
                        Button {
                            selection = options[i].0
                        } label: {
                            HStack(spacing: 10) {
                                if options[i].0 == selection { Image(systemName: "checkmark") }
                                Text(options[i].1)
                            }
                        }
                        .focused($focused, equals: options[i].0)
                    }
                }
                .padding(.vertical, 20)
            }
        }
        // Une rangée = une étape : haut et bas passent à la rangée voisine sans
        // en sauter ni filer sur le côté, et arrivent sur l'option cochée.
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .tvDefaultFocus($focused, selection)
    }
}

extension View {
    /// tvOS 17 : arriver dans la zone à la télécommande met le focus sur
    /// `value` ; tvOS 16 : sur l'élément le plus proche, comme avant.
    @ViewBuilder func tvDefaultFocus<V: Hashable>(_ binding: FocusState<V?>.Binding, _ value: V) -> some View {
        if #available(tvOS 17.0, *) {
            defaultFocus(binding, value, priority: .userInitiated)
        } else {
            self
        }
    }
}

// MARK: – Cartes et éléments communs
struct TVStreamGrid: View {
    let streams: [TwitchStream]
    let play: (TVPlayback) -> Void
    /// Listes de découverte : bouton central maintenu pour masquer la chaîne
    /// et, si `hideCategory`, sa catégorie.
    var hideable = false
    var hideCategory = true
    @EnvironmentObject private var session: TVSession
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 48), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 56) {
            ForEach(streams) { s in
                Button {
                    play(.live(login: s.userLogin, name: s.userName))
                } label: {
                    TVStreamCard(stream: s)
                }
                .tvCard()
                // Bouton Play de la télécommande : comme Sélection.
                .onPlayPauseCommand { play(.live(login: s.userLogin, name: s.userName)) }
                .contextMenu {
                    if hideable {
                        Button(role: .destructive) {
                            session.hidden.hide(channel: s.userLogin, name: s.userName)
                        } label: {
                            Label(session.t("hide_channel"), systemImage: "eye.slash")
                        }
                        if hideCategory, !s.gameId.isEmpty, !s.gameName.isEmpty {
                            Button(role: .destructive) {
                                session.hidden.hide(category: s.gameId, name: s.gameName, box: "")
                            } label: {
                                Label(session.t("hide_category").replacingOccurrences(of: "{c}", with: s.gameName),
                                      systemImage: "eye.slash")
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 64)
        .padding(.vertical, 32)
    }
}

struct TVStreamCard: View {
    let stream: TwitchStream
    @EnvironmentObject private var session: TVSession

    private var thumb: String {
        stream.thumbnailURL
            .replacingOccurrences(of: "{width}", with: "640")
            .replacingOccurrences(of: "{height}", with: "360")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                TVThumbnail(url: thumb, ratio: 16 / 9)

                HStack(spacing: 8) {
                    Text(session.t("tv_live"))
                        .font(.caption2.weight(.heavy))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.tLive)
                        .cornerRadius(4)
                    Text(formatViewers(stream.viewerCount))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(4)
                }
                .foregroundColor(.white)
                .padding(12)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(stream.userName).font(.headline).lineLimit(1)
                Text(stream.title).font(.caption).foregroundColor(.secondary).lineLimit(2)
                if !stream.gameName.isEmpty {
                    Text(stream.gameName).font(.caption2).foregroundColor(Color.tPurple).lineLimit(1)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TVVodCard: View {
    let video: VodData

    private var thumb: String {
        video.previewThumbnailURL
            .replacingOccurrences(of: "%{width}", with: "640")
            .replacingOccurrences(of: "%{height}", with: "360")
            .replacingOccurrences(of: "{width}", with: "640")
            .replacingOccurrences(of: "{height}", with: "360")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                TVThumbnail(url: thumb, ratio: 16 / 9)

                Text(formatDuration(video.lengthSeconds))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.black.opacity(0.7))
                    .foregroundColor(.white)
                    .cornerRadius(4)
                    .padding(12)
            }
            Text(video.title)
                .font(.caption)
                .lineLimit(2)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Image d'une carte dans une boîte au format fixe, qu'elle remplit et où
/// elle est rognée. Sans boîte, une miniature en « remplir » reprenait sa
/// taille d'origine (640 points) au chargement ou au focus, et débordait sur
/// la carte voisine.
struct TVThumbnail: View {
    let url: String
    let ratio: CGFloat

    var body: some View {
        Color.white.opacity(0.08)
            .aspectRatio(ratio, contentMode: .fit)
            .overlay(
                AsyncImage(url: URL(string: url)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            )
            .clipped()
    }
}

/// Focus d'une carte, signalé à l'écran qui veut savoir quand la
/// télécommande revient sur ses cartes (Suivies : rechargement).
private struct TVCardFocusReportKey: EnvironmentKey {
    static let defaultValue: ((Bool) -> Void)? = nil
}

extension EnvironmentValues {
    var tvCardFocusReport: ((Bool) -> Void)? {
        get { self[TVCardFocusReportKey.self] }
        set { self[TVCardFocusReportKey.self] = newValue }
    }
}

/// Carte à la télécommande (style « card » de tvOS) : celle qui a le focus
/// grandit et passe devant ses voisines, au lieu de glisser dessous.
private struct TVCardFocus: ViewModifier {
    @FocusState private var focused: Bool
    /// Focus signalé et pas encore rendu. Une carte retirée avec le focus
    /// (live fini au rechargement) ne signalait jamais sa perte : le compte
    /// de Suivies ne revenait plus à 0, et le rechargement au retour du focus
    /// cessait de marcher.
    @State private var reported = false
    @Environment(\.tvCardFocusReport) private var report

    func body(content: Content) -> some View {
        content
            .buttonStyle(.card)
            .focused($focused)
            .zIndex(focused ? 1 : 0)
            .onChange(of: focused) { on in
                guard on != reported else { return }
                reported = on
                report?(on)
            }
            .onDisappear {
                guard reported else { return }
                reported = false
                report?(false)
            }
    }
}

extension View {
    func tvCard() -> some View { modifier(TVCardFocus()) }
}

struct TVAvatar: View {
    let url: String?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: URL(string: url ?? "")) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            Circle().fill(Color.white.opacity(0.1))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct TVMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.title3)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(80)
    }
}
