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

// MARK: – Grille des catégories
struct CategoriesView: View {
    let onPlayStream: (String) -> Void

    @EnvironmentObject private var store: AppStore

    @State private var categories: [TwitchCategory] = []
    @State private var cursor: String? = nil
    @State private var loading      = false
    @State private var loadingMore  = false
    @State private var errorMsg: String? = nil
    @State private var search       = ""
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var selected: TwitchCategory? = nil

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        Group {
            if let cat = selected {
                CategoryStreamsView(category: cat,
                                    onBack: { selected = nil },
                                    onPlayStream: onPlayStream)
            } else {
                browser
            }
        }
        .onAppear { if categories.isEmpty { Task { await loadTop() } } }
    }

    // MARK: – Liste / recherche
    @ViewBuilder private var browser: some View {
        VStack(spacing: 0) {
            TSearchField(text: $search, placeholder: store.t("cat_search_ph"))
                .padding(.horizontal, TSpace.lg)
                .padding(.top, TSpace.md)
                .onChange(of: search) { runSearch($0) }

            if loading {
                Spacer()
                TLoader()
                Spacer()
            } else if let err = errorMsg {
                Spacer()
                TEmptyState(icon: "exclamationmark.triangle", title: err)
                Spacer()
            } else if categories.isEmpty {
                Spacer()
                TEmptyState(icon: "magnifyingglass", title: store.t("no_result"))
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: TSpace.md) {
                        ForEach(categories) { cat in
                            CategoryCardView(category: cat) { selected = cat }
                        }
                    }
                    .padding(.horizontal, TSpace.lg)
                    .padding(.top, TSpace.md)

                    // Pagination : uniquement sur le Top (la recherche n'en a pas).
                    if cursor != nil && search.isEmpty {
                        TLoadMoreButton(busy: loadingMore) { Task { await loadMore() } }
                    }

                    Spacer(minLength: 40)
                }
                .refreshable { await loadTop() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tDark)
    }

    // MARK: – Chargements
    @MainActor private func loadTop() async {
        guard let token = store.twitchToken else { return }
        if categories.isEmpty { loading = true }
        errorMsg = nil
        do {
            let page = try await getTopCategories(token: token)
            categories = page.categories
            cursor     = page.cursor
        } catch is CancellationError {
            loading = false; return
        } catch {
            errorMsg = store.t("err_loading")
        }
        loading = false
    }

    @MainActor private func loadMore() async {
        guard let token = store.twitchToken, let c = cursor, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let page = try? await getTopCategories(token: token, cursor: c) else { return }
        // Twitch peut renvoyer des doublons entre deux pages : on dédoublonne.
        let known = Set(categories.map(\.id))
        categories += page.categories.filter { !known.contains($0.id) }
        cursor = page.cursor
    }

    /// Recherche différée de 350 ms : évite un appel par frappe.
    private func runSearch(_ text: String) {
        searchTask?.cancel()
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            searchTask = Task { await loadTop() }
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let token = store.twitchToken else { return }
            guard let found = try? await searchCategories(token: token, query: q),
                  !Task.isCancelled else { return }
            await MainActor.run {
                categories = found
                cursor     = nil
                errorMsg   = nil
            }
        }
    }
}

// MARK: – Lives d'une catégorie
struct CategoryStreamsView: View {
    let category: TwitchCategory
    let onBack: () -> Void
    let onPlayStream: (String) -> Void

    @EnvironmentObject private var store: AppStore

    @State private var streams: [TwitchStream] = []
    @State private var cursor: String? = nil
    @State private var loading     = false
    @State private var loadingMore = false
    @State private var errorMsg: String? = nil
    @State private var sort: StreamSort = .viewersDesc

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    private var sorted: [TwitchStream] { sort.apply(streams) }

    var body: some View {
        VStack(spacing: 0) {

            // ── En-tête : retour + nom de la catégorie ──────────────
            HStack(spacing: TSpace.sm) {
                Button(action: onBack) {
                    HStack(spacing: TSpace.xs) {
                        Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold))
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
            }
            .padding(.horizontal, TSpace.lg)
            .padding(.top, TSpace.md)
            .padding(.bottom, TSpace.sm)

            // ── Tri ─────────────────────────────────────────────────
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: TSpace.sm) {
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
                Spacer()
                TEmptyState(icon: "exclamationmark.triangle", title: err)
                Spacer()
            } else if streams.isEmpty {
                Spacer()
                TEmptyState(icon: "antenna.radiowaves.left.and.right",
                            title: store.t("no_live"))
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: TSpace.md) {
                        ForEach(sorted) { stream in
                            StreamCardView(stream: stream) { onPlayStream(stream.userLogin) }
                        }
                    }
                    .padding(.horizontal, TSpace.lg)

                    if cursor != nil {
                        TLoadMoreButton(busy: loadingMore) { Task { await loadMore() } }
                    }

                    Spacer(minLength: 40)
                }
                .refreshable { await load() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tDark)
        .onAppear { if streams.isEmpty { Task { await load() } } }
    }

    @MainActor private func load() async {
        guard let token = store.twitchToken else { return }
        if streams.isEmpty { loading = true }
        errorMsg = nil
        do {
            let page = try await getStreamsByCategory(token: token, gameId: category.id)
            streams = page.streams
            cursor  = page.cursor
        } catch is CancellationError {
            loading = false; return
        } catch {
            errorMsg = store.t("err_loading")
        }
        loading = false
    }

    @MainActor private func loadMore() async {
        guard let token = store.twitchToken, let c = cursor, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let page = try? await getStreamsByCategory(token: token, gameId: category.id, cursor: c)
        else { return }
        let known = Set(streams.map(\.id))
        streams += page.streams.filter { !known.contains($0.id) }
        cursor = page.cursor
    }
}
