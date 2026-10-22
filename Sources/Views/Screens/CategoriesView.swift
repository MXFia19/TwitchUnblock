import SwiftUI

/// Tris disponibles sur les lives d'une catégorie.
/// Helix ne renvoie que l'ordre « plus de spectateurs d'abord » : les autres
/// sont appliqués localement sur la page chargée.
enum StreamSort: String, CaseIterable, Identifiable {
    case viewersDesc, viewersAsc, nameAsc

    var id: String { rawValue }

    func label(_ store: AppStore) -> String {
        switch self {
        case .viewersDesc: return store.t("sort_viewers_desc")
        case .viewersAsc:  return store.t("sort_viewers_asc")
        case .nameAsc:     return store.t("sort_name")
        }
    }

    var icon: String {
        switch self {
        case .viewersDesc: return "arrow.down"
        case .viewersAsc:  return "arrow.up"
        case .nameAsc:     return "textformat.abc"
        }
    }

    func apply(_ streams: [TwitchStream]) -> [TwitchStream] {
        switch self {
        case .viewersDesc: return streams.sorted { $0.viewerCount > $1.viewerCount }
        case .viewersAsc:  return streams.sorted { $0.viewerCount < $1.viewerCount }
        case .nameAsc:
            return streams.sorted {
                $0.userName.localizedCaseInsensitiveCompare($1.userName) == .orderedAscending
            }
        }
    }
}

// MARK: – « Charger plus » sans compte
/// Curseur de la suite d'une liste : GQL sans jeton (Client-ID d'Android,
/// kGQLNextClientID) ou Helix avec le compte (`nil` : Helix depuis le début).
/// Les deux ne se mélangent pas : un curseur GQL envoyé à Helix, ou
/// l'inverse, serait refusé après une connexion en cours de route.
enum ListCursor: Equatable {
    case gql(String)
    case helix(String?)
}

/// Charge la suite d'une liste à partir de `cursor`. Jusqu'à 3 pages pour
/// trouver du neuf : les pages se recouvrent un peu d'un Client-ID à l'autre,
/// les lives bougent, et Helix repart du début après un refus de GQL.
/// - `gql` : une page après ce curseur ; nil = panne réseau.
/// - `helix` : une page avec le jeton, après ce curseur (nil = début) ; nil = panne.
/// Renvoie les éléments absents de `current`, le curseur suivant (le même
/// après une panne : le bouton reste pour réessayer), et `locked` : Twitch
/// refuse la suite et aucun compte ne peut prendre le relais.
@MainActor func loadMorePages<T: Identifiable>(
    after cursor: ListCursor, current: [T], token: String?,
    gql: (String) async -> (items: [T], next: String?, refused: Bool)?,
    helix: (String, String?) async -> (items: [T], next: String?)?
) async -> (fresh: [T], cursor: ListCursor?, locked: Bool) {
    var c: ListCursor? = cursor
    var seen = Set(current.map(\.id))
    var fresh: [T] = []
    for _ in 0..<3 {
        guard let step = c else { break }
        switch step {
        case .gql(let after):
            guard let page = await gql(after) else { return (fresh, c, false) }
            if page.refused {
                // Twitch refuse aussi ce Client-ID : Helix avec le compte,
                // depuis le début ; sans compte, la liste s'arrête là.
                guard token != nil else { return (fresh, nil, true) }
                c = .helix(nil)
                continue
            }
            fresh += page.items.filter { seen.insert($0.id).inserted }
            c = page.next.map { ListCursor.gql($0) }
        case .helix(let after):
            guard let token else { return (fresh, nil, false) }
            guard let page = await helix(token, after) else { return (fresh, c, false) }
            fresh += page.items.filter { seen.insert($0.id).inserted }
            c = page.next.map { ListCursor.helix($0) }
        }
        if !fresh.isEmpty { break }
    }
    return (fresh, c, false)
}

// MARK: – État vide ou d'erreur qu'on peut recharger
/// Message centré qu'on peut tirer pour recharger : hors d'un ScrollView, une
/// erreur ou une liste vide ne se rechargeait plus (seule l'apparition de
/// l'onglet relançait, et seulement si la liste était vide). Tâche détachée,
/// comme à l'accueil : le rechargement remplace cette vue (chargeur), ce qui
/// annulerait la tâche de `.refreshable` et sa requête.
private struct PullToReload<Content: View>: View {
    let reload: () async -> Void
    let content: Content

    init(reload: @escaping () async -> Void, @ViewBuilder content: () -> Content) {
        self.reload = reload
        self.content = content()
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                content.frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .refreshable { await Task { await reload() }.value }
        }
    }
}

// MARK: – Grille des catégories
struct CategoriesView: View {
    let onPlayStream: (String) -> Void

    @EnvironmentObject private var store: AppStore

    @State private var categories: [TwitchCategory] = []
    @State private var cursor: ListCursor? = nil
    /// Twitch refuse la suite sans compte : un message remplace le bouton.
    @State private var locked       = false
    @State private var loading      = false
    @State private var loadingMore  = false
    @State private var errorMsg: String? = nil
    @State private var search       = ""
    @State private var searchTask: Task<Void, Never>? = nil
    /// Recherche en route (indicateur dans le champ).
    @State private var searching    = false
    /// Numéro du dernier chargement de la grille (top, recherche, frappe) :
    /// une réponse plus ancienne ne remplace pas la grille, et seul le plus
    /// récent conclut (chargeur, indicateur, erreur).
    @State private var gridGen      = 0
    @State private var selected: TwitchCategory? = nil
    /// 0 = catégories suivies, 1 = toutes.
    @AppStorage("cat_tab") private var tab = 1
    /// Suivies sur Twitch (session web), complétées par celles de l'appareil.
    @State private var twitchFollowed: [TwitchCategory] = []
    @State private var followedViewers: [String: Int] = [:]
    @State private var loadingFollowed = false
    /// Feuille des chaînes et catégories masquées (ligne « N masqués · Gérer »).
    @State private var showHidden = false

    /// Suivies : Twitch puis appareil, sans doublon, dans l'ordre choisi
    /// (Réglages → Personnaliser : les plus regardées d'abord, ou A → Z).
    private var followedList: [TwitchCategory] {
        var seen = Set<String>()
        let list = (twitchFollowed + store.followedCategories)
            .filter { seen.insert($0.id).inserted }
            .map { c in var c = c; c.viewers = c.viewers ?? followedViewers[c.id]; return c }
        return store.customization.followedCategoriesSort.apply(list)
    }

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Suivies en compact (réglage) : 3 jaquettes par ligne, 4 sur iPad ;
    /// 2 aux tailles de texte d'accessibilité.
    private var followedColumns: [GridItem] {
        guard store.customization.compactFollowedCategories else { return columns }
        let count = TType.isAccessibility ? 2 : (sizeClass == .regular ? 4 : 3)
        return Array(repeating: GridItem(.flexible(), spacing: TSpace.sm), count: count)
    }

    var body: some View {
        // La grille reste dessous quand une catégorie est ouverte : le glissé
        // retour depuis le bord gauche la découvre, comme sur iOS.
        ZStack {
            // Effacée : un type de vue trop imbriqué fait déborder la pile au
            // décodage sur iOS 18 (comme les Réglages, voir sectionPage).
            AnyView(browser)
                .allowsHitTesting(selected == nil)
                .accessibilityHidden(selected != nil)
            if let cat = selected {
                CategoryStreamsView(category: cat,
                                    followedOnTwitch: twitchFollowed.contains { $0.id == cat.id }
                                        || store.accountFollowedCategoryIds.contains(cat.id),
                                    onBack: { selected = nil },
                                    onPlayStream: onPlayStream,
                                    onTwitchUnfollowed: { twitchFollowed.removeAll { $0.id == cat.id } })
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .onAppear {
            // Grille vide (première ouverture, retour d'une catégorie après
            // une recherche sans résultat) : ce qui était demandé.
            if categories.isEmpty { Task { await reload() } }
            Task { await loadFollowed() }
        }
        .onChange(of: store.followedCategories.map(\.id)) { _ in Task { await loadFollowed() } }
        // Session web partie ou changée : les catégories suivies sur Twitch
        // ne sont plus celles de ce compte (elles restaient affichées).
        .onChange(of: store.twitchWebToken) { _ in Task { await loadFollowed() } }
        .sheet(isPresented: $showHidden) {
            HiddenContentSheet().environmentObject(store)
        }
    }

    /// Catégories suivies : Twitch (si session web) + appareil, avec audience.
    @MainActor private func loadFollowed() async {
        if let web = store.twitchWebToken {
            if twitchFollowed.isEmpty { loadingFollowed = true }
            let list = await getFollowedCategoriesGQL(webToken: web)
            // Session déconnectée ou changée pendant la lecture : cette liste
            // n'est plus la sienne (la lecture suivante conclut).
            if store.twitchWebToken == web {
                if let list {
                    twitchFollowed = list
                    // Suivies sur Twitch : jamais masquées (règle d'AppStore).
                    store.accountFollowedCategoryIds = Set(list.map(\.id))
                }
                loadingFollowed = false
            }
        } else {
            // Plus de session web : rien n'est suivi sur Twitch ici.
            twitchFollowed = []
            loadingFollowed = false
        }
        let missing = store.followedCategories.map(\.id)
        guard !missing.isEmpty else { return }
        let counts = await categoryViewers(ids: missing)
        if !counts.isEmpty { followedViewers = counts }
    }

    // MARK: – Onglet « Suivies »
    @ViewBuilder private var followedGrid: some View {
        let list = followedList
        if loadingFollowed && list.isEmpty {
            Spacer(); TLoader(); Spacer()
        } else if list.isEmpty {
            PullToReload(reload: { await loadFollowed() }) {
                TEmptyState(icon: "heart", title: store.t("cat_followed_empty"),
                            message: store.t(store.twitchWebToken == nil ? "cat_followed_empty_msg_local" : "cat_followed_empty_msg"))
            }
        } else {
            let compact = store.customization.compactFollowedCategories
            ScrollView {
                LazyVGrid(columns: followedColumns, spacing: compact ? TSpace.sm : TSpace.md) {
                    ForEach(list) { cat in
                        CategoryCardView(category: cat, compact: compact) { selected = cat }
                    }
                }
                .padding(.horizontal, TSpace.lg)
                .padding(.top, TSpace.md)
                Spacer(minLength: 40)
            }
            .refreshable { await Task { await loadFollowed() }.value }
        }
    }

    // MARK: – Liste / recherche
    @ViewBuilder private var browser: some View {
        VStack(spacing: 0) {
            // Suivies | Toutes
            HStack(spacing: TSpace.sm) {
                TChip(title: store.t("cat_followed"), isOn: tab == 0) { tab = 0 }
                TChip(title: store.t("cat_all"), isOn: tab == 1) { tab = 1 }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, TSpace.lg)
            .padding(.top, TSpace.md)

            if tab == 0 {
                followedGrid
            } else {
                allBrowser
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tDark)
    }

    @ViewBuilder private var allBrowser: some View {
        VStack(spacing: 0) {
            TSearchField(text: $search, placeholder: store.t("cat_search_ph"), busy: searching)
                .padding(.horizontal, TSpace.lg)
                .padding(.top, TSpace.md)
                .onChange(of: search) { runSearch($0) }

            // Recherche en route sur une grille vide : pas « Aucun résultat »
            // avant la réponse.
            if loading || (searching && categories.isEmpty && errorMsg == nil) {
                Spacer()
                TLoader()
                Spacer()
            } else if let err = errorMsg {
                // « Réessayer », ou tirer : ce qui était demandé (la recherche
                // en cours, sinon le top).
                PullToReload(reload: { await reload() }) {
                    TEmptyState(icon: "exclamationmark.triangle", title: err,
                                actionTitle: store.t("retry")) { Task { await reload() } }
                }
            } else if categories.isEmpty {
                PullToReload(reload: { await reload() }) {
                    TEmptyState(icon: "magnifyingglass", title: store.t("no_result"))
                }
            } else {
                // Sans recherche, les catégories masquées sont écartées ; une
                // recherche les montre toutes, les masquées atténuées.
                let shown = search.isEmpty ? categories.filter { store.showsCategory($0) } : categories
                let hiddenCount = categories.count - shown.count
                ScrollView {
                    LazyVGrid(columns: columns, spacing: TSpace.md) {
                        ForEach(shown) { cat in
                            CategoryCardView(category: cat, hideable: true) { selected = cat }
                        }
                    }
                    .padding(.horizontal, TSpace.lg)
                    .padding(.top, TSpace.md)

                    if hiddenCount > 0 {
                        HiddenFooter(count: hiddenCount) { showHidden = true }
                    }

                    // Pagination : uniquement sur le Top (la recherche n'en a pas).
                    if search.isEmpty {
                        if cursor != nil {
                            TLoadMoreButton(busy: loadingMore) { Task { await loadMore() } }
                        } else if locked {
                            if store.twitchToken != nil {
                                // Connecté depuis le refus : Helix reprend du début.
                                TLoadMoreButton(busy: loadingMore) {
                                    cursor = .helix(nil); locked = false
                                    Task { await loadMore() }
                                }
                            } else {
                                TListEndNote(key: "more_needs_login")
                            }
                        }
                    }

                    Spacer(minLength: 40)
                }
                // Pendant une recherche, c'est elle qui se relance (le top
                // s'affichait sous « minecraft »). Tâche détachée : voir
                // PullToReload.
                .refreshable { await Task { await reload() }.value }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tDark)
    }

    // MARK: – Chargements
    /// Recharge ce qui est affiché : la recherche en cours, sinon le top.
    @MainActor private func reload() async {
        searchTask?.cancel()
        let q = search.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { await loadTop() } else { await performSearch(q) }
    }

    @MainActor private func loadTop() async {
        gridGen += 1
        let gen = gridGen
        searching = false
        if categories.isEmpty { loading = true }
        errorMsg = nil
        guard let token = store.twitchToken else {
            // Sans compte : GQL public, audience comprise, par pages de 100 ;
            // la suite passe par le Client-ID d'Android (loadMore).
            let page = await getTopCategoriesPageGQL(after: nil)
            // Une recherche est partie entre-temps : c'est elle qui conclut.
            guard gen == gridGen else { return }
            if let page {
                categories = page.categories
                cursor = page.next.map { ListCursor.gql($0) }
                locked = false
            } else if categories.isEmpty {
                errorMsg = store.t("err_loading")
            }
            loading = false
            return
        }
        do {
            let page = try await getTopCategories(token: token)
            guard gen == gridGen else { return }
            categories = page.categories
            cursor     = page.cursor.map { ListCursor.helix($0) }
            locked     = false
        } catch is CancellationError {
            if gen == gridGen { loading = false }
            return
        } catch {
            guard gen == gridGen else { return }
            errorMsg = store.t("err_loading")
        }
        loading = false
        await loadViewers()
    }

    /// Complète les cartes avec l'audience de chaque catégorie. Séparé du
    /// chargement : Helix ne la donne pas, et la grille ne doit pas attendre
    /// une seconde requête pour s'afficher.
    @MainActor private func loadViewers() async {
        let missing = categories.filter { $0.viewers == nil }.map(\.id)
        guard !missing.isEmpty else { return }
        let counts = await categoryViewers(ids: missing)
        guard !counts.isEmpty else { return }
        for i in categories.indices where categories[i].viewers == nil {
            categories[i].viewers = counts[categories[i].id]
        }
    }

    /// Suite du Top : GQL sans compte, Helix avec ; doublons écartés (Twitch
    /// en renvoie entre deux pages).
    @MainActor private func loadMore() async {
        guard let c = cursor, !loadingMore else { return }
        let gen = gridGen
        loadingMore = true
        defer { loadingMore = false }
        let result = await loadMorePages(
            after: c, current: categories, token: store.twitchToken,
            gql: { after in
                guard let p = await getTopCategoriesPageGQL(after: after) else { return nil }
                return (p.categories, p.next, p.refused)
            },
            helix: { token, after in
                guard let p = try? await getTopCategories(token: token, cursor: after) else { return nil }
                return (p.categories, p.cursor)
            })
        // Recherche ou rechargement entre-temps : la grille n'est plus celle
        // de ce curseur.
        guard gen == gridGen, search.isEmpty else { return }
        categories += result.fresh
        cursor = result.cursor
        locked = result.locked
        await loadViewers()
    }

    /// Recherche différée de 350 ms : évite un appel par frappe.
    private func runSearch(_ text: String) {
        searchTask?.cancel()
        // Ce qui est en route (top, recherche précédente) est dépassé.
        gridGen += 1
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            searching = false
            searchTask = Task { await loadTop() }
            return
        }
        searching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await performSearch(q)
        }
    }

    /// Recherche de catégories, sans délai (frappe après 350 ms, « Réessayer »,
    /// tirer pour rafraîchir). GQL d'abord, avec ou sans compte : le
    /// classement de Twitch (« valorant » donne VALORANT en tête) et des
    /// jaquettes nettes. Helix classait mal et renvoyait des vignettes de
    /// 52×72 : il ne sert plus que de secours, si GQL ne répond pas.
    @MainActor private func performSearch(_ q: String) async {
        gridGen += 1
        let gen = gridGen
        searching = true
        errorMsg = nil
        var result = await searchCategoriesGQL(query: q)
        if result == nil, gen == gridGen, let token = store.twitchToken {
            result = try? await searchCategories(token: token, query: q)
        }
        // Frappe ou rechargement plus récent : c'est lui qui conclut.
        guard gen == gridGen else { return }
        searching = false
        loading = false
        guard let list = result else {
            // Échec : on le dit, au lieu de laisser le top (ou l'ancienne
            // recherche) sous ce qu'on vient de taper.
            errorMsg = store.t("err_loading")
            return
        }
        categories = rankCategories(list, for: q)
        cursor     = nil
        // La recherche passe par Helix elle aussi : mêmes cartes, donc
        // même complément d'audience.
        await loadViewers()
    }
}

// MARK: – Lives d'une catégorie
struct CategoryStreamsView: View {
    let category: TwitchCategory
    /// Suivie sur le compte Twitch (session web) : le cœur est plein, et le
    /// toucher la retire de Twitch (après confirmation) au lieu d'en faire un
    /// doublon sur l'appareil qu'on ne pouvait plus enlever des suivies.
    var followedOnTwitch = false
    let onBack: () -> Void
    let onPlayStream: (String) -> Void
    /// Retirée de Twitch ici : la liste des suivies l'enlève tout de suite.
    var onTwitchUnfollowed: () -> Void = {}

    @EnvironmentObject private var store: AppStore

    @State private var streams: [TwitchStream] = []
    @State private var cursor: ListCursor? = nil
    /// Hausse à chaque remplacement de la liste (premier chargement, tirer
    /// pour rafraîchir, langue) : une page « suite » partie avant ne s'ajoute
    /// plus à la nouvelle liste — doublons dans la grille, et curseur d'avant.
    @State private var listGen = 0
    /// Twitch refuse la suite sans compte : un message remplace le bouton.
    @State private var locked      = false
    @State private var loading     = false
    @State private var loadingMore = false
    @State private var errorMsg: String? = nil
    @State private var sort: StreamSort = .viewersDesc
    @State private var showHidden = false
    /// Suivi Twitch retiré depuis cette page.
    @State private var leftOnTwitch = false
    @State private var confirmTwitchUnfollow = false
    @State private var unfollowBusy = false
    /// Twitch a refusé de la retirer (ou la session web manque).
    @State private var unfollowFailed = false

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    /// Chaînes masquées écartées ; la catégorie, elle, reste consultable
    /// même masquée (on l'a ouverte exprès).
    private var sorted: [TwitchStream] { sort.apply(streams.filter { store.showsChannel($0.userLogin) }) }

    var body: some View {
        VStack(spacing: 0) {

            // ── En-tête : retour + nom de la catégorie ──────────────
            HStack(spacing: TSpace.sm) {
                Button(action: onBack) {
                    HStack(spacing: TSpace.xs) {
                        Image(systemName: "chevron.left").font(.tSystem(size: 13, weight: .bold))
                        Text(store.t("categories")).font(.tLabel)
                    }
                    .foregroundColor(.tPrimary)
                }
                .buttonStyle(.plain)

                Text(category.name)
                    .font(.tSection)
                    .foregroundColor(.tText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                hideButton
                followButton
            }
            .padding(.horizontal, TSpace.lg)
            .padding(.top, TSpace.md)
            .padding(.bottom, TSpace.sm)

            hiddenStrip

            if unfollowFailed {
                Text(store.t("follow_failed"))
                    .font(.tMeta).foregroundColor(.tDanger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, TSpace.lg)
                    .padding(.bottom, TSpace.sm)
            }

            // ── Langue et tri ───────────────────────────────────────
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: TSpace.sm) {
                    languageMenu
                    ForEach(StreamSort.allCases) { s in
                        TChip(title: s.label(store), icon: s.icon, isOn: sort == s) { sort = s }
                    }
                }
                .padding(.horizontal, TSpace.lg)
            }
            .padding(.bottom, TSpace.md)

            if loading {
                Spacer()
                TLoader()
                Spacer()
            } else if let err = errorMsg {
                PullToReload(reload: { await load() }) {
                    TEmptyState(icon: "exclamationmark.triangle", title: err,
                                actionTitle: store.t("retry")) { Task { await load() } }
                }
            } else if streams.isEmpty {
                PullToReload(reload: { await load() }) {
                    TEmptyState(icon: "antenna.radiowaves.left.and.right",
                                title: store.t("no_live"))
                }
            } else {
                let shown = sorted
                ScrollView {
                    if shown.isEmpty {
                        TEmptyState(icon: "antenna.radiowaves.left.and.right",
                                    title: store.t("no_live"))
                    }
                    LazyVGrid(columns: columns, spacing: TSpace.md) {
                        ForEach(shown) { stream in
                            StreamCardView(stream: stream, hideable: true, hideCategory: false) {
                                onPlayStream(stream.userLogin)
                            }
                        }
                    }
                    .padding(.horizontal, TSpace.lg)

                    if streams.count > shown.count {
                        HiddenFooter(count: streams.count - shown.count) { showHidden = true }
                    }

                    if cursor != nil {
                        TLoadMoreButton(busy: loadingMore) { Task { await loadMore() } }
                    } else if locked {
                        if store.twitchToken != nil {
                            // Connecté depuis le refus : Helix reprend du début.
                            TLoadMoreButton(busy: loadingMore) {
                                cursor = .helix(nil); locked = false
                                Task { await loadMore() }
                            }
                        } else {
                            TListEndNote(key: "more_needs_login")
                        }
                    }

                    Spacer(minLength: 40)
                }
                // Tâche détachée : voir PullToReload.
                .refreshable { await Task { await load() }.value }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tDark)
        // Glissé depuis le bord gauche : retour, comme le bouton (la page
        // suit le doigt et découvre la grille, ou les résultats).
        .edgeSwipeBack { withAnimation(.easeOut(duration: 0.22)) { onBack() } }
        .onAppear { if streams.isEmpty { Task { await load() } } }
        .sheet(isPresented: $showHidden) {
            HiddenContentSheet().environmentObject(store)
        }
        .onChange(of: store.categoryLang) { _ in
            streams = []
            cursor = nil
            locked = false
            Task { await load() }
        }
    }

    /// Catégorie masquée et pas suivie (une catégorie suivie n'est jamais
    /// masquée).
    private var isHiddenHere: Bool {
        !store.followsCategory(category.id) && store.hidden.hides(category: category.id)
    }

    /// Suivre la catégorie (gardé sur cet appareil). Suivie sur Twitch : le
    /// cœur est plein, et le toucher la retire de Twitch, après confirmation.
    @ViewBuilder private var followButton: some View {
        let onTwitch = followedOnTwitch && !leftOnTwitch
        let on = onTwitch || store.isCategoryFollowed(category.id)
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if onTwitch {
                confirmTwitchUnfollow = true
                return
            }
            withAnimation(.easeInOut(duration: 0.15)) { store.toggleCategoryFollow(category) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: on ? "heart.fill" : "heart")
                Text(store.t(on ? "following" : "follow")).font(.tSystem(size: 13, weight: .bold))
            }
            .foregroundColor(on ? .tDanger : .tPrimary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background((on ? Color.tDanger : Color.tPrimary).opacity(0.14))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(unfollowBusy)
        .opacity(unfollowBusy ? 0.5 : 1)
        .confirmationDialog(
            store.t("unfollow_confirm").replacingOccurrences(of: "{c}", with: category.name),
            isPresented: $confirmTwitchUnfollow, titleVisibility: .visible
        ) {
            Button(store.t("unfollow"), role: .destructive) {
                Task { await unfollowOnTwitch() }
            }
            Button(store.t("cancel"), role: .cancel) {}
        }
    }

    /// Retire la catégorie des suivis du compte Twitch ; suivie aussi sur
    /// l'appareil, elle en est retirée aussi : le cœur se vide pour de bon.
    @MainActor private func unfollowOnTwitch() async {
        guard !unfollowBusy else { return }
        guard let web = store.twitchWebToken else { unfollowFailed = true; return }
        unfollowBusy = true
        defer { unfollowBusy = false }
        unfollowFailed = false
        guard await unfollowCategoryOnTwitch(gameId: category.id, token: web) else {
            unfollowFailed = true
            return
        }
        leftOnTwitch = true
        store.accountFollowedCategoryIds.remove(category.id)
        if store.isCategoryFollowed(category.id) { store.toggleCategoryFollow(category) }
        onTwitchUnfollowed()
    }

    /// Masquer la catégorie (œil barré) ; rien si elle est suivie, ni si elle
    /// est déjà masquée (la pastille « Masquée · Réafficher » est en dessous).
    @ViewBuilder private var hideButton: some View {
        if !store.followsCategory(category.id) && !store.hidden.hides(category: category.id) {
            TIconButton(icon: "eye.slash", size: 30) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.easeInOut(duration: 0.15)) {
                    store.hideCategory(id: category.id, name: category.name, box: category.boxArtURL)
                }
            }
            .accessibilityLabel(store.t("hide_this_category"))
        }
    }

    /// Catégorie masquée : « Masquée · Réafficher », sur sa propre ligne sous
    /// l'en-tête (dans l'en-tête, avec le nom et Suivre, elle serait coupée).
    @ViewBuilder private var hiddenStrip: some View {
        if isHiddenHere {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { store.unhideCategory(category.id) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "eye")
                        Text("\(store.t("hidden_badge")) · \(store.t("unhide"))")
                            .font(.tSystem(size: 13, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundColor(.tMuted)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Color.tSurface)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, TSpace.lg)
            .padding(.bottom, TSpace.sm)
        }
    }

    /// Langue des lives (la même pour toutes les catégories) : toutes, celle
    /// de l'appareil, ou une autre. Refait seulement quand le choix, la
    /// langue de l'interface ou le thème change (KeyedView) : pendant une
    /// lecture, la liste ouverte remontait en haut à chaque rendu de l'écran.
    private var languageMenu: some View {
        KeyedView(key: "\(store.categoryLang ?? "")|\(store.lang.rawValue)|\(store.themeID)") { languageMenuContent }
            .equatable()
    }

    private var languageMenuContent: some View {
        let current = store.categoryLang
        let device = TopLanguage.device
        let others = TopLanguage.codes
            .filter { $0 != device }
            .map { ($0, TopLanguage.name($0, in: store.lang)) }
            .sorted { $0.1.localizedCompare($1.1) == .orderedAscending }
        return Menu {
            Button { store.categoryLang = nil } label: {
                if current == nil { Label(store.t("cat_lang_all"), systemImage: "checkmark") }
                else { Text(store.t("cat_lang_all")) }
            }
            Button { store.categoryLang = device } label: {
                if current == device { Label(TopLanguage.name(device, in: store.lang), systemImage: "checkmark") }
                else { Text(TopLanguage.name(device, in: store.lang)) }
            }
            Divider()
            ForEach(others, id: \.0) { code, name in
                Button { store.categoryLang = code } label: {
                    if current == code { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
        } label: {
            HStack(spacing: TSpace.xs) {
                Image(systemName: "globe").font(.tSystem(size: 11, weight: .semibold))
                Text(current.map { TopLanguage.name($0, in: store.lang) } ?? store.t("cat_lang_all"))
                    .font(.tLabel).lineLimit(1)
                Image(systemName: "chevron.down").font(.tSystem(size: 8, weight: .bold))
            }
            .foregroundColor(current == nil ? .tMuted : .white)
            .padding(.horizontal, TSpace.md)
            .padding(.vertical, 4)
            .frame(minHeight: 32)
            .background(current == nil ? Color.tSurface : Color.tPrimary)
            .cornerRadius(TRadius.chip)
        }
    }

    @MainActor private func load() async {
        // Langue du départ : une réponse arrivée après un changement de
        // langue (Français puis aussitôt English) n'est plus la bonne, c'est
        // la demande de la nouvelle langue qui conclut.
        let lang = store.categoryLang
        if streams.isEmpty { loading = true }
        errorMsg = nil
        guard let token = store.twitchToken else {
            // Sans compte : les lives les plus regardés (GQL public) par pages
            // de 100 ; la suite passe par le Client-ID d'Android (loadMore).
            let page = await getStreamsByCategoryPageGQL(gameId: category.id, lang: lang, after: nil)
            guard lang == store.categoryLang else { return }
            if let page {
                listGen += 1
                streams = page.streams
                cursor = page.next.map { ListCursor.gql($0) }
                locked = false
            } else if streams.isEmpty {
                errorMsg = store.t("err_loading")
            }
            loading = false
            return
        }
        do {
            let page = try await getStreamsByCategory(token: token, gameId: category.id, lang: lang)
            guard lang == store.categoryLang else { return }
            listGen += 1
            streams = page.streams
            cursor  = page.cursor.map { ListCursor.helix($0) }
            locked  = false
        } catch is CancellationError {
            if lang == store.categoryLang { loading = false }
            return
        } catch {
            guard lang == store.categoryLang else { return }
            errorMsg = store.t("err_loading")
        }
        loading = false
    }

    /// Suite des lives : GQL sans compte, Helix avec ; doublons écartés (les
    /// lives bougent d'une page à l'autre).
    @MainActor private func loadMore() async {
        guard let c = cursor, !loadingMore else { return }
        let lang = store.categoryLang
        let gameId = category.id
        let gen = listGen
        loadingMore = true
        defer { loadingMore = false }
        let result = await loadMorePages(
            after: c, current: streams, token: store.twitchToken,
            gql: { after in
                guard let p = await getStreamsByCategoryPageGQL(gameId: gameId, lang: lang, after: after) else { return nil }
                return (p.streams, p.next, p.refused)
            },
            helix: { token, after in
                guard let p = try? await getStreamsByCategory(token: token, gameId: gameId, cursor: after, lang: lang)
                else { return nil }
                return (p.streams, p.cursor)
            })
        // Langue changée, ou liste rechargée entre-temps (tirer pour
        // rafraîchir) : cette page suivait l'ancienne liste.
        guard gen == listGen, lang == store.categoryLang else { return }
        streams += result.fresh
        cursor = result.cursor
        locked = result.locked
    }
}
