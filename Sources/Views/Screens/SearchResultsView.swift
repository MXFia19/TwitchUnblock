import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Résultats d'une recherche par texte, en onglets comme la page de
//  résultats de Twitch : Chaînes, Catégories, Lives (titre, tags) et VODs.
//  Les recherches partent ensemble ; chaque onglet se remplit dès sa
//  réponse. Un lien ou un identifiant collé (VOD, clip, chaîne) ne passe
//  pas par ici : SearchView l'ouvre directement.
// ═══════════════════════════════════════════════════════════════════════════

/// Onglets des résultats.
enum SearchTab: Int, CaseIterable {
    case channels, categories, lives, vods
}

/// Résultats de la dernière recherche par texte. Gardés pendant qu'on ouvre
/// une chaîne ou une catégorie trouvée : le retour les retrouve sans les
/// redemander.
@MainActor
final class SearchResults: ObservableObject {
    /// Texte cherché ; vide : pas de résultats à afficher.
    @Published private(set) var query = ""
    /// nil : pas encore de réponse ; vide : rien trouvé (ou échec, `failed`).
    @Published private(set) var channels: [AutocompleteSuggestion]? = nil
    @Published private(set) var categories: [TwitchCategory]? = nil
    @Published private(set) var streams: [TwitchStream]? = nil
    @Published private(set) var vods: [SearchVod]? = nil
    /// Onglets dont la recherche n'a pas abouti (Twitch n'a pas répondu).
    @Published private(set) var failed: Set<SearchTab> = []
    /// Numéro de la recherche : les réponses d'une recherche remplacée sont
    /// écartées.
    private var gen = 0

    /// Plus de résultats affichés ; les réponses en route sont écartées.
    func clear() {
        gen += 1
        query = ""
        channels = nil; categories = nil; streams = nil; vods = nil
        failed = []
    }

    /// Lance les recherches de `text` ; `token` (compte) : secours Helix des
    /// catégories, comme dans l'onglet Catégories.
    func search(_ text: String, token: String?) {
        clear()
        let g = gen
        query = text
        logger.info("RECHERCHE", "Recherche « \(text) »")
        Task { await self.loadChannelsAndLives(text, g) }
        Task { await self.loadCategories(text, token: token, g) }
        Task { await self.loadVods(text, g) }
    }

    /// Chaînes, et lives. Si Twitch refuse la recherche des lives ou n'en
    /// trouve aucun, les chaînes trouvées qui sont en live les remplacent.
    private func loadChannelsAndLives(_ text: String, _ g: Int) async {
        async let foundChannels = searchChannelsGQL(text)
        async let foundStreams = searchStreamsGQL(query: text)
        let list = await foundChannels
        guard g == gen else { return }
        channels = list ?? []
        if list == nil { failed.insert(.channels) }

        var lives = await foundStreams
        if lives?.isEmpty ?? true, let list {
            let logins = list.filter(\.isLive).map(\.login)
            if !logins.isEmpty, let fromChannels = await getLiveStreamsGQL(logins: logins) {
                lives = fromChannels
            } else if lives == nil, logins.isEmpty {
                // Aucune chaîne trouvée en live : rien à montrer, pas une panne.
                lives = []
            }
        }
        guard g == gen else { return }
        // Une chaîne une seule fois (identifiant des cartes).
        var seen = Set<String>()
        streams = (lives ?? []).filter { seen.insert($0.id).inserted }
        if lives == nil { failed.insert(.lives) }
    }

    /// Catégories : GQL d'abord (classement de Twitch, audience), Helix avec
    /// le compte en secours.
    private func loadCategories(_ text: String, token: String?, _ g: Int) async {
        var list = await searchCategoriesGQL(query: text)
        if list == nil, let token { list = try? await searchCategories(token: token, query: text) }
        guard g == gen else { return }
        guard let found = list else {
            categories = []
            failed.insert(.categories)
            return
        }
        var seen = Set<String>()
        let ranked = rankCategories(found, for: text).filter { seen.insert($0.id).inserted }
        categories = ranked
        // Helix ne donne pas l'audience : complétée par GQL.
        let missing = ranked.filter { $0.viewers == nil }.map(\.id)
        guard !missing.isEmpty else { return }
        let viewers = await categoryViewers(ids: missing)
        guard g == gen else { return }
        categories = ranked.map { c -> TwitchCategory in
            var c = c
            c.viewers = c.viewers ?? viewers[c.id]
            return c
        }
    }

    private func loadVods(_ text: String, _ g: Int) async {
        let list = await searchVideosGQL(query: text)
        guard g == gen else { return }
        var seen = Set<String>()
        vods = (list ?? []).filter { seen.insert($0.id).inserted }
        if list == nil { failed.insert(.vods) }
    }
}

// MARK: – Onglets des résultats
/// Les onglets et leur contenu, dans la liste défilante de SearchView. Lives
/// et VODs passent par les mêmes cartes et la même lecture que le reste de
/// l'écran ; ceux des chaînes et catégories masquées sont écartés (sauf
/// suivies), comme dans les listes de découverte. Chaînes et catégories, on
/// les a cherchées : montrées, avec leur marque « masquée ».
struct SearchResultsSection: View {
    @ObservedObject var results: SearchResults
    @Binding var tab: SearchTab
    let onOpenChannel: (String) -> Void
    let onOpenCategory: (TwitchCategory) -> Void
    let onPlayLive: (String) -> Void
    let onPlayVod: (String, String?, String?, String?) -> Void
    let onRetry: () -> Void
    /// Ligne « N masqués ici · Gérer ».
    let onShowHidden: () -> Void

    @EnvironmentObject private var store: AppStore

    private let columns = [GridItem(.flexible(), alignment: .top),
                           GridItem(.flexible(), alignment: .top)]

    private var shownStreams: [TwitchStream] {
        (results.streams ?? []).filter { store.showsStream($0) }
    }
    private var shownVods: [SearchVod] {
        (results.vods ?? []).filter { showsVod($0) }
    }

    /// Même règle que `showsStream` : ni la chaîne ni la catégorie masquées,
    /// sauf si on suit l'une ou l'autre.
    private func showsVod(_ v: SearchVod) -> Bool {
        store.isFollowedOrPinned(v.login)
            || (!store.hidden.hides(channel: v.login)
                && (store.followsCategory(v.gameId) || !store.hidden.hides(category: v.gameId)))
    }

    /// « Chaînes 12 » : le nombre de résultats, une fois arrivés.
    private func label(_ t: SearchTab) -> String {
        var title = store.t("channels")
        var count = results.channels?.count
        switch t {
        case .channels:
            break
        case .categories:
            title = store.t("categories")
            count = results.categories?.count
        case .lives:
            title = store.t("search_tab_lives")
            count = results.streams == nil ? nil : shownStreams.count
        case .vods:
            title = store.t("vods")
            count = results.vods == nil ? nil : shownVods.count
        }
        guard let count, count > 0 else { return title }
        return "\(title) \(count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TSpace.md) {
            TSegmented(items: SearchTab.allCases, selection: $tab) { label($0) }

            switch tab {
            case .channels:   channelsList
            case .categories: categoriesGrid
            case .lives:      livesGrid
            case .vods:       vodsGrid
            }
        }
    }

    // MARK: Chaînes
    @ViewBuilder private var channelsList: some View {
        if let list = results.channels {
            if list.isEmpty {
                emptyOrFailed(.channels, icon: "person.fill")
            } else {
                VStack(spacing: 0) {
                    ForEach(list) { c in
                        channelRow(c)
                        if c.id != list.last?.id {
                            Divider().background(Color.tBorder).padding(.leading, 64)
                        }
                    }
                }
                .background(Color.tCard)
                .cornerRadius(TRadius.card)
                .padding(.horizontal, TSpace.lg)
            }
        } else {
            TLoader()
        }
    }

    private func channelRow(_ c: AutocompleteSuggestion) -> some View {
        Button { onOpenChannel(c.login) } label: {
            HStack(spacing: TSpace.md) {
                AsyncImage(url: URL(string: c.avatar ?? "")) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(Color.tSurface)
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
                // Anneau rouge : la chaîne est en live.
                .overlay(Circle().stroke(c.isLive ? Color.tLive : .clear, lineWidth: 2).padding(-2))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(c.name).font(.tCardTitle).foregroundColor(.tText).lineLimit(1)
                        // Masquée des listes : la recherche la montre quand même.
                        if store.hidden.hides(channel: c.login) {
                            Image(systemName: "eye.slash")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.tMuted)
                                .accessibilityLabel(store.t("hidden_badge"))
                        }
                    }
                    if let viewers = c.viewers {
                        HStack(spacing: 5) {
                            TLiveBadge(compact: true)
                            Text(formatViewers(viewers) + (c.game.map { " · \($0)" } ?? ""))
                                .font(.tMeta).foregroundColor(.tMuted).lineLimit(1)
                        }
                    } else if let f = c.followers {
                        Text("\(formatViewers(f)) \(store.tn("followers", f, abbreviated: f >= 1000))")
                            .font(.tMeta).foregroundColor(.tMuted).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.tMuted)
            }
            .padding(.horizontal, TSpace.md)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Catégories
    @ViewBuilder private var categoriesGrid: some View {
        if let list = results.categories {
            if list.isEmpty {
                emptyOrFailed(.categories, icon: "gamecontroller")
            } else {
                LazyVGrid(columns: columns, spacing: TSpace.md) {
                    ForEach(list) { cat in
                        // Masquée : atténuée avec sa pastille (on l'a cherchée).
                        CategoryCardView(category: cat, hideable: true) { onOpenCategory(cat) }
                    }
                }
                .padding(.horizontal, TSpace.lg)
            }
        } else {
            TLoader()
        }
    }

    // MARK: Lives
    @ViewBuilder private var livesGrid: some View {
        if let all = results.streams {
            let shown = shownStreams
            if all.isEmpty {
                emptyOrFailed(.lives, icon: "antenna.radiowaves.left.and.right")
            } else {
                if !shown.isEmpty {
                    LazyVGrid(columns: columns, spacing: TSpace.md) {
                        ForEach(shown) { stream in
                            StreamCardView(stream: stream, hideable: true) { onPlayLive(stream.userLogin) }
                        }
                    }
                    .padding(.horizontal, TSpace.lg)
                }
                if all.count > shown.count {
                    HiddenFooter(count: all.count - shown.count, action: onShowHidden)
                }
            }
        } else {
            TLoader()
        }
    }

    // MARK: VODs
    @ViewBuilder private var vodsGrid: some View {
        if let all = results.vods {
            let shown = shownVods
            if all.isEmpty {
                emptyOrFailed(.vods, icon: "film")
            } else {
                if !shown.isEmpty {
                    LazyVGrid(columns: columns, spacing: TSpace.md) {
                        ForEach(shown) { v in
                            let saved = store.getVodProgress(v.vod.id)
                            let progress = v.vod.lengthSeconds > 0 ? saved / Double(v.vod.lengthSeconds) : 0
                            VodCardView(vod: v.vod, progress: progress, channel: v.name) {
                                onPlayVod(v.vod.id, v.vod.title, v.vod.previewThumbnailURL,
                                          v.login.isEmpty ? nil : v.login)
                            }
                            .contextMenu {
                                MultiVodMenuButton(vodId: v.vod.id, title: v.vod.title,
                                                   thumb: v.vod.previewThumbnailURL,
                                                   name: v.name, login: v.login)
                            }
                        }
                    }
                    .padding(.horizontal, TSpace.lg)
                }
                if all.count > shown.count {
                    HiddenFooter(count: all.count - shown.count, action: onShowHidden)
                }
            }
        } else {
            TLoader()
        }
    }

    /// Onglet vide : Twitch n'a pas répondu (Réessayer), ou rien trouvé.
    @ViewBuilder private func emptyOrFailed(_ t: SearchTab, icon: String) -> some View {
        if results.failed.contains(t) {
            TEmptyState(icon: "exclamationmark.triangle", title: store.t("err_loading"),
                        actionTitle: store.t("retry"), action: onRetry)
        } else {
            TEmptyState(icon: icon, title: store.t("no_result"))
        }
    }
}
