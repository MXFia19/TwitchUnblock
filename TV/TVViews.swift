import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Écrans de l'app Apple TV : onglets en haut, cartes à la télécommande
//  (style « card » de tvOS : la carte qui a le focus se soulève).
// ═══════════════════════════════════════════════════════════════════════════

/// Ce que le lecteur doit lire.
enum TVPlayback: Identifiable, Hashable {
    case live(login: String, name: String)
    case vod(id: String, title: String, channel: String)
    /// Clip d'une chaîne (onglet Clips de sa page) : ses MP4, comme l'iPhone.
    case clip(slug: String, title: String, channel: String)

    var id: String {
        switch self {
        case .live(let login, _):    return "live-\(login)"
        case .vod(let id, _, _):     return "vod-\(id)"
        case .clip(let slug, _, _):  return "clip-\(slug)"
        }
    }

    /// Chaîne regardée (login) : le chat garde sa place propre à chacune.
    var channel: String {
        switch self {
        case .live(let login, _):    return login.lowercased()
        case .vod(_, _, let login):  return login.lowercased()
        case .clip(_, _, let login): return login.lowercased()
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
    /// Pages de chaîne ouvertes dans Suivies et Recherche, gardées ici : Menu
    /// pressé avec le focus dans la barre des onglets referme la page de
    /// l'onglet au lieu de quitter l'app (closePageFromTabBar).
    @State private var followingPath = NavigationPath()
    @State private var searchPath = NavigationPath()

    var body: some View {
        // Choisir de nouveau « Suivies » ne passe pas par la sélection sur
        // tvOS (elle suit le focus) : l'onglet se recharge quand le focus
        // revient de la barre des onglets (TVFollowingTab.cardFocus).
        TabView(selection: $tab) {
            TVFollowingTab(play: play, path: $followingPath)
                .tabItem { Text(session.t("tv_following")) }
                .tag(Tab.following)
            TVTopTab(play: play)
                .tabItem { Text(session.t("tv_top")) }
                .tag(Tab.top)
            TVCategoriesTab(play: play)
                .tabItem { Text(session.t("tv_categories")) }
                .tag(Tab.categories)
            TVSearchTab(play: play, path: $searchPath)
                .tabItem { Text(session.t("tv_search")) }
                .tag(Tab.search)
            TVAccountTab()
                .tabItem { Text(session.t("tv_account")) }
                .tag(Tab.account)
        }
        .onExitCommand(perform: closePageFromTabBar)
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

    /// Menu avec le focus remonté dans la barre des onglets alors qu'une page
    /// de chaîne est ouverte dans l'onglet : elle se referme, au lieu de
    /// quitter l'app. Le focus dans la page, c'est elle qui répond
    /// (TVChannelView) ; sans page ouverte, nil : Menu garde son effet habituel.
    private var closePageFromTabBar: (() -> Void)? {
        switch tab {
        case .following where !followingPath.isEmpty:
            return { if !followingPath.isEmpty { followingPath.removeLast() } }
        case .search where !searchPath.isEmpty:
            return { if !searchPath.isEmpty { searchPath.removeLast() } }
        default:
            return nil
        }
    }

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
            // Sur la page elle-même (pas une page ouverte depuis) : Menu
            // referme et rend les onglets.
            TVChannelView(login: login, play: { playing = $0 }, onExit: { dismiss() })
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
    /// Page de chaîne ouverte d'ici (TVRootView la referme aussi).
    @Binding var path: NavigationPath
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
    /// Cartes de la liste qui ont le focus (0 : il est dans la barre des
    /// onglets, ou sur une page ouverte d'ici), et depuis quand aucune.
    @State private var focusedCards = 0
    @State private var unfocusedSince = Date.distantPast
    /// VODs entamées sur cette Apple TV (TVProgress) : la rangée « Continuer
    /// à regarder », avec ou sans compte, au-dessus des directs, en dessous,
    /// ou masquée (Compte, session.resumePlace).
    @State private var resume: [TVResumeItem] = []
    /// Ce que Twitch dit de chacune (titre, chaîne, image, durée), demandé
    /// une fois par VOD.
    @State private var resumeMetas: [String: VodMeta] = [:]
    /// Dernière demande à Twitch d'une VOD pas encore connue (loadResume).
    @State private var resumeAsked: [String: Date] = [:]
    private let offlineColumns = Array(repeating: GridItem(.flexible(), spacing: 40), count: 6)

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                if resumeShown, session.resumePlace == .top { resumeSection }
                if session.token == nil {
                    TVMessage(text: session.t("tv_need_login"))
                } else {
                    // Avec la rangée, un titre aux directs : ils semblaient en
                    // faire partie.
                    if resumeShown {
                        Text(session.t("tv_live_section")).font(.title3.bold())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 64)
                            .padding(.top, 32)
                    }
                    if streams.isEmpty {
                        TVMessage(text: loading ? session.t("loading")
                                  : (failed ? session.t("tv_error") : session.t("tv_no_live")))
                    } else {
                        TVStreamGrid(streams: streams, play: play)
                    }
                }
                if resumeShown, session.resumePlace == .bottom { resumeSection }
                if session.token != nil, !offline.isEmpty { offlineSection }
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
        // Rangée réaffichée dans Compte : ses vidéos, pas chargées tant
        // qu'elle était masquée.
        .onChange(of: session.resumePlace) { place in
            if place != .hidden { Task { await loadResume() } }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
                if visible, scenePhase == .active { await load() }
            }
        }
    }

    /// La rangée « Continuer à regarder » est affichée : des VODs entamées,
    /// et pas masquée dans Compte.
    private var resumeShown: Bool { session.resumePlace != .hidden && !resume.isEmpty }

    /// « Continuer à regarder » : les VODs entamées, la dernière regardée
    /// d'abord ; Sélection ou Play la reprend où elle en était (TVProgress).
    private var resumeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(session.t("tv_resume")).font(.title3.bold())
                .padding(.horizontal, 64)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 48) {
                    ForEach(resume) { r in
                        Button {
                            play(r.playback)
                        } label: {
                            TVResumeCard(item: r)
                        }
                        .tvCard()
                        .onPlayPauseCommand { play(r.playback) }
                        // Bouton central maintenu : la reprendre, ou la
                        // retirer de la rangée (sa position est oubliée).
                        .contextMenu {
                            Button {
                                // Une fois le menu refermé : présenté pendant
                                // sa fermeture, le lecteur risquerait de ne
                                // pas s'afficher.
                                let item = r.playback
                                Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 400_000_000)
                                    play(item)
                                }
                            } label: {
                                Label(session.t("tv_resume_play"), systemImage: "play.fill")
                            }
                            Button(role: .destructive) {
                                removeResume(r.id)
                            } label: {
                                Label(session.t("tv_resume_remove"), systemImage: "xmark.circle")
                            }
                        }
                    }
                }
                // Place pour la carte qui grandit avec le focus.
                .padding(.horizontal, 64)
                .padding(.vertical, 32)
            }
            // Atteinte en montant depuis n'importe quelle carte du dessous.
            .focusSection()
        }
        .padding(.top, 32)
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
        // VODs entamées : sans compte aussi, sans attendre les lives ; rien à
        // demander à Twitch tant que la rangée est masquée.
        if session.resumePlace != .hidden { Task { await loadResume() } }
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

    /// Positions relues (TVProgress), et ce que Twitch dit des VODs pas
    /// encore connues, toutes à la fois. Une VOD introuvable (supprimée), ou
    /// finie d'après sa durée, n'apparaît pas.
    private func loadResume() async {
        let recent = TVProgress.recent()
        // Pas celles déjà demandées il y a moins de 10 min : en cours (deux
        // chargements se suivent à l'ouverture de l'onglet), ou introuvables
        // (supprimées) — redemandées sinon à chaque chargement.
        let now = Date()
        let missing = recent.map { $0.id }.filter {
            resumeMetas[$0] == nil && now.timeIntervalSince(resumeAsked[$0] ?? .distantPast) > 600
        }
        if !missing.isEmpty {
            for id in missing { resumeAsked[id] = now }
            let fetched = await withTaskGroup(of: (String, VodMeta?).self,
                                              returning: [String: VodMeta].self) { group in
                for id in missing {
                    group.addTask {
                        let meta = await getVodMetaGQL(id)
                        return (id, meta)
                    }
                }
                var out: [String: VodMeta] = [:]
                for await result in group {
                    if let meta = result.1 { out[result.0] = meta }
                }
                return out
            }
            resumeMetas.merge(fetched) { _, new in new }
            // Rien de connu : réseau absent peut-être (Apple TV sortie de
            // veille avant le Wi-Fi), elles sont redemandées au prochain chargement.
            if resumeMetas.isEmpty { for id in missing { resumeAsked[id] = nil } }
        }
        // Positions relues après l'attente : une vidéo retirée de la rangée
        // pendant la demande ne revient pas.
        resume = TVProgress.recent().compactMap { entry -> TVResumeItem? in
            guard let meta = resumeMetas[entry.id] else { return nil }
            if meta.lengthSeconds > 0, Double(meta.lengthSeconds) - entry.seconds < 120 { return nil }
            return TVResumeItem(id: entry.id, seconds: entry.seconds, meta: meta)
        }
    }

    /// « Retirer de la liste » (appui long dans « Continuer à regarder ») : sa
    /// position est oubliée sur cette Apple TV, elle repartira du début.
    private func removeResume(_ id: String) {
        TVProgress.remove(id)
        resume.removeAll { $0.id == id }
    }
}

/// VOD entamée sur cette Apple TV (TVProgress), avec ce qu'en dit Twitch.
struct TVResumeItem: Identifiable {
    let id: String
    let seconds: Double
    let meta: VodMeta

    /// Avec sa chaîne (login) : le chat et « Voir la chaîne » en ont besoin.
    var playback: TVPlayback { .vod(id: id, title: meta.title, channel: meta.login) }
    /// Part déjà vue (0 si la durée est inconnue).
    var progress: Double {
        meta.lengthSeconds > 0 ? min(1, seconds / Double(meta.lengthSeconds)) : 0
    }
}

/// Carte d'une VOD entamée (rangée « Reprendre ») : image avec la part déjà
/// vue, titre et chaîne.
struct TVResumeCard: View {
    let item: TVResumeItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottom) {
                TVThumbnail(url: item.meta.thumb, ratio: 16 / 9)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Color.black.opacity(0.5)
                        Color.tPrimary.frame(width: geo.size.width * item.progress)
                    }
                }
                .frame(height: 6)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.meta.title).font(.caption).lineLimit(2)
                if !item.meta.streamer.isEmpty {
                    Text(item.meta.streamer).font(.caption2).foregroundColor(Color.tPurple).lineLimit(1)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 412)
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
    /// Page de chaîne ouverte d'ici (TVRootView la referme aussi).
    @Binding var path: NavigationPath
    @EnvironmentObject private var session: TVSession
    @State private var query = ""
    @State private var results: [AutocompleteSuggestion] = []

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

// MARK: – Chaîne : live éventuel, vidéos, clips et collections
struct TVChannelView: View {
    let login: String
    let play: (TVPlayback) -> Void
    /// Ouverte avec le bouton Play : le live, sinon la dernière vidéo, se
    /// lance une fois chargée (une seule fois : pas à chaque retour du lecteur).
    var autoplay = false
    /// Menu sur la page. Par défaut elle se referme et rend la liste d'où
    /// elle a été ouverte ; la page de TVChannelCover referme sa feuille.
    var onExit: (() -> Void)? = nil
    @EnvironmentObject private var session: TVSession
    @Environment(\.dismiss) private var dismiss
    /// Onglets de la page, comme sur l'iPhone. Toujours affichés, ils
    /// prennent le focus dès l'ouverture : sur une chaîne hors ligne sans
    /// vidéo, rien ne le prenait, il restait dans la barre des onglets, et
    /// Menu quittait l'app au lieu de revenir à la liste.
    enum ChannelTab: Hashable { case videos, clips, collections }
    @State private var tab = ChannelTab.videos
    @State private var videos: [VodData] = []
    @State private var avatar: String?
    @State private var live: TwitchStream?
    @State private var loaded = false
    @State private var autoplayed = false
    /// Clips les plus vus de la période choisie (100 au plus, comme la
    /// première page de l'iPhone). `clipsFor` : période des clips affichés ;
    /// `clipsAsked` : période demandée, réponse en route.
    @State private var clipPeriod = "LAST_WEEK"
    @State private var clips: [ClipData] = []
    @State private var clipsFor: String?
    @State private var clipsAsked: String?
    @State private var clipsFailed = false
    /// Collections (playlists) de la chaîne, avec leurs vidéos.
    @State private var collections: [PlaylistData] = []
    @State private var collectionsLoaded = false
    @State private var collectionsLoading = false
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 48), count: 4)
    /// Périodes des clips, mêmes textes que l'iPhone.
    private static let clipPeriods: [(String, String)] = [
        ("LAST_DAY", "period_day"), ("LAST_WEEK", "period_week"),
        ("LAST_MONTH", "period_month"), ("ALL_TIME", "period_all"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                Picker("", selection: $tab) {
                    Text(session.t("tv_videos")).tag(ChannelTab.videos)
                    Text(session.t("tv_clips")).tag(ChannelTab.clips)
                    Text(session.t("tv_collections")).tag(ChannelTab.collections)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
                switch tab {
                case .videos:      videosPart
                case .clips:       clipsPart
                case .collections: collectionsPart
                }
            }
            // Pas de marge sur les côtés ici : les rangées des collections
            // défilent sur toute la largeur (chaque partie a la sienne).
            .padding(.vertical, 32)
        }
        .onExitCommand {
            if let onExit { onExit() } else { dismiss() }
        }
        .onChange(of: tab) { t in loadTab(t) }
        .onChange(of: clipPeriod) { _ in
            if tab == .clips { Task { await loadClips() } }
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
                    play(vodItem(last))
                }
            }
        }
    }

    private var header: some View {
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
        .padding(.horizontal, 64)
        // Toute la largeur reçoit le focus : « Regarder le live », à
        // droite, n'était atteint en montant que depuis la vidéo
        // juste dessous (tvOS cherche ce qui est au-dessus).
        .focusSection()
    }

    /// Vidéos (lives passés), chargées avec la page.
    @ViewBuilder private var videosPart: some View {
        if videos.isEmpty {
            TVMessage(text: loaded ? session.t("tv_no_videos") : session.t("loading"))
        } else {
            LazyVGrid(columns: columns, spacing: 56) {
                ForEach(videos) { v in
                    Button {
                        play(vodItem(v))
                    } label: {
                        TVVodCard(video: v)
                    }
                    .tvCard()
                    .onPlayPauseCommand { play(vodItem(v)) }
                }
            }
            .padding(.horizontal, 64)
        }
    }

    /// Clips les plus vus sur 24 h, 7 jours, 30 jours ou depuis toujours ;
    /// la période reste atteignable (et le focus sur la page) sans clip.
    @ViewBuilder private var clipsPart: some View {
        Picker("", selection: $clipPeriod) {
            ForEach(Self.clipPeriods, id: \.0) { p in
                Text(session.t(p.1)).tag(p.0)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity)
        if clipsFor == clipPeriod {
            if clips.isEmpty {
                TVMessage(text: session.t("tv_no_clips"))
            } else {
                LazyVGrid(columns: columns, spacing: 56) {
                    ForEach(clips) { c in
                        Button {
                            play(clipItem(c))
                        } label: {
                            TVClipCard(clip: c)
                        }
                        .tvCard()
                        .onPlayPauseCommand { play(clipItem(c)) }
                    }
                }
                .padding(.horizontal, 64)
            }
        } else {
            TVMessage(text: clipsFailed ? session.t("tv_error") : session.t("loading"))
        }
    }

    /// Collections : titre, nombre de vidéos, et leurs vidéos sur une rangée.
    @ViewBuilder private var collectionsPart: some View {
        if collections.isEmpty {
            TVMessage(text: collectionsLoaded && !collectionsLoading
                      ? session.t("tv_no_collections") : session.t("loading"))
        } else {
            ForEach(collections) { list in
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(list.title).font(.title3.bold()).lineLimit(1)
                        Text(String(format: session.t("videos_count"), list.total))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 64)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 48) {
                            ForEach(list.videos) { v in
                                Button {
                                    play(vodItem(v))
                                } label: {
                                    TVVodCard(video: v).frame(width: 412)
                                }
                                .tvCard()
                                .onPlayPauseCommand { play(vodItem(v)) }
                            }
                        }
                        // Place pour la carte qui grandit avec le focus.
                        .padding(.horizontal, 64)
                        .padding(.vertical, 32)
                    }
                    // Haut et bas passent d'une collection à l'autre.
                    .focusSection()
                }
            }
        }
    }

    private func vodItem(_ v: VodData) -> TVPlayback {
        .vod(id: v.id, title: v.title, channel: login)
    }

    private func clipItem(_ c: ClipData) -> TVPlayback {
        .clip(slug: c.id, title: c.title, channel: login)
    }

    /// Contenu d'un onglet, demandé quand il s'affiche (les vidéos viennent
    /// avec la page). Pas annulé en changeant d'onglet : la réponse sert au
    /// retour, et une requête coupée s'écrirait dans le journal.
    private func loadTab(_ t: ChannelTab) {
        switch t {
        case .videos:      break
        case .clips:       Task { await loadClips() }
        case .collections: Task { await loadCollections() }
        }
    }

    /// Clips de la période choisie (getClipsPage, comme l'iPhone), une fois
    /// par période. Une réponse arrivée après un changement de période est
    /// écartée ; pas de réponse : « Impossible de charger », redemandés en
    /// revenant sur l'onglet.
    private func loadClips() async {
        let period = clipPeriod
        guard clipsFor != period, clipsAsked != period else { return }
        clipsAsked = period
        clipsFailed = false
        let page = await getClipsPage(login: login, period: period, after: nil)
        if clipsAsked == period { clipsAsked = nil }
        guard period == clipPeriod else { return }
        if let page {
            clips = page.clips
            clipsFor = period
        } else {
            clipsFailed = true
        }
    }

    /// Collections de la chaîne (getCollections, comme l'iPhone : 20 au plus,
    /// 50 vidéos chacune, vides écartées). Aucune (ou pas de réponse) :
    /// redemandées en revenant sur l'onglet.
    private func loadCollections() async {
        guard collections.isEmpty, !collectionsLoading else { return }
        collectionsLoading = true
        let list = await getCollections(login: login)
        collections = list
        collectionsLoading = false
        collectionsLoaded = true
    }
}

/// Carte d'un clip (page d'une chaîne) : image avec les vues et la durée,
/// titre, date et auteur du clip.
struct TVClipCard: View {
    let clip: ClipData
    @EnvironmentObject private var session: TVSession

    /// « 0:28 » : un clip dure une minute au plus (formatDuration écrirait « 0min »).
    private var duration: String {
        let s = max(0, clip.durationSeconds)
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// Date du clip dans la langue de l'app, puis qui l'a créé.
    private var meta: String {
        var parts: [String] = []
        if let date = parseTwitchDate(clip.createdAt) {
            let df = DateFormatter()
            df.locale = Locale(identifier: session.lang.rawValue)
            df.dateStyle = .medium
            df.timeStyle = .none
            parts.append(df.string(from: date))
        }
        if let c = clip.curator, !c.isEmpty { parts.append(c) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TVThumbnail(url: clip.thumbnailURL, ratio: 16 / 9)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 6) {
                        Image(systemName: "eye.fill")
                        Text(formatViewers(clip.viewCount))
                    }
                    .modifier(TVBadge())
                }
                .overlay(alignment: .bottomTrailing) {
                    Text(duration).modifier(TVBadge())
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(clip.title).font(.caption).lineLimit(2)
                if !meta.isEmpty {
                    Text(meta).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Pastille sur l'image d'une carte (vues, durée).
private struct TVBadge: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.black.opacity(0.7))
            .foregroundColor(.white)
            .cornerRadius(4)
            .padding(12)
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
                    // Rangée « Continuer à regarder » de Suivies : au-dessus
                    // des directs, en dessous, ou masquée.
                    TVChoiceRow(title: session.t("tv_resume_place"),
                                options: TVResumePlace.allCases.map { ($0.rawValue, session.t("tv_resume_\($0.rawValue)")) },
                                selection: Binding(get: { session.resumePlace.rawValue },
                                                   set: { session.resumePlace = TVResumePlace(rawValue: $0) ?? .top }))
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

                aboutSection

                logsSection
            }
            .padding(64)
        }
        // L'attente du code n'est plus annulée en quittant l'onglet (TVSession).
    }

    /// À propos : version et numéro de build de l'app (« Version 0.1.34
    /// (build 34) » pour un build de la CI), pour décrire un problème ou
    /// vérifier qu'une mise à jour est bien installée.
    private var aboutSection: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return VStack(alignment: .leading, spacing: 16) {
            Text(session.t("tv_about")).font(.title3.bold())
            Text(session.t("tv_version")
                    .replacingOccurrences(of: "{v}", with: version)
                    .replacingOccurrences(of: "{b}", with: build))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Atteignable à la télécommande : sans rien d'autre à focaliser
        // dessous (aucune erreur), la page ne défilerait pas jusqu'à elle.
        .focusable()
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
