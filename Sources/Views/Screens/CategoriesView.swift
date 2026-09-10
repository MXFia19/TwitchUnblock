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
            // ── Recherche ───────────────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13)).foregroundColor(.tMuted)
                TextField(store.t("cat_search_ph"), text: $search)
                    .font(.system(size: 14))
                    .foregroundColor(.tText)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onChange(of: search) { runSearch($0) }
                if !search.isEmpty {
                    // Vider le champ suffit : onChange relance le Top.
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14)).foregroundColor(.tMuted)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.tSurface)
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.tBorder, lineWidth: 1))
            .padding(.horizontal, 16)
            .padding(.top, 12)

            if loading {
                Spacer()
                ProgressView().tint(.tPrimary)
                Spacer()
            } else if let err = errorMsg {
                Spacer()
                Text(err).foregroundColor(.tDanger).fontWeight(.semibold)
                Spacer()
            } else if categories.isEmpty {
                Spacer()
                Text(store.t("no_result")).foregroundColor(.tMuted)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(categories) { cat in
                            CategoryCardView(category: cat) { selected = cat }
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 12)

                    // Pagination : uniquement sur le Top (la recherche n'en a pas).
                    if cursor != nil && search.isEmpty {
                        Button { Task { await loadMore() } } label: {
                            Group {
                                if loadingMore { ProgressView().tint(.tPrimary) }
                                else {
                                    Text(store.t("load_more"))
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(.tPrimary)
                                }
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Color.tPrimary.opacity(0.1))
                            .cornerRadius(10)
                        }
                        .disabled(loadingMore)
                        .padding(.horizontal, 16).padding(.top, 12)
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

// MARK: – Carte d'une catégorie
struct CategoryCardView: View {
    let category: TwitchCategory
    let onPress: () -> Void

    var body: some View {
        Button(action: onPress) {
            VStack(alignment: .leading, spacing: 0) {
                AsyncImage(url: URL(string: category.boxArtURL)) { img in
                    img.resizable().aspectRatio(3/4, contentMode: .fill)
                } placeholder: {
                    Color(hex: "111111").aspectRatio(3/4, contentMode: .fill)
                }
                .clipped()

                Text(category.name)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.tText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(height: 36, alignment: .top)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color.tSurface)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
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
            HStack(spacing: 10) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                        Text(store.t("categories")).font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor(.tPrimary)
                }
                Text(category.name)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(.tText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)

            // ── Tri ─────────────────────────────────────────────────
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(StreamSort.allCases) { s in
                        Button { sort = s } label: {
                            Text(s.label(store))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(sort == s ? .white : .tMuted)
                                .lineLimit(1)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(sort == s ? Color.tPrimary : Color.tSurface)
                                .cornerRadius(8)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 10)

            if loading {
                Spacer()
                ProgressView().tint(.tPrimary)
                Spacer()
            } else if let err = errorMsg {
                Spacer()
                Text(err).foregroundColor(.tDanger).fontWeight(.semibold)
                Spacer()
            } else if streams.isEmpty {
                Spacer()
                Text(store.t("no_live")).foregroundColor(.tMuted)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(sorted) { stream in
                            StreamCardView(stream: stream) { onPlayStream(stream.userLogin) }
                        }
                    }
                    .padding(.horizontal, 16)

                    if cursor != nil {
                        Button { Task { await loadMore() } } label: {
                            Group {
                                if loadingMore { ProgressView().tint(.tPrimary) }
                                else {
                                    Text(store.t("load_more"))
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(.tPrimary)
                                }
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Color.tPrimary.opacity(0.1))
                            .cornerRadius(10)
                        }
                        .disabled(loadingMore)
                        .padding(.horizontal, 16).padding(.top, 12)
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
