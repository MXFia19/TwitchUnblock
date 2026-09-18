import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Accueil : ce qui est en direct maintenant.
//  Deux vues — les lives (chaînes suivies + top) et les catégories.
// ═══════════════════════════════════════════════════════════════════════════

struct HomeView: View {
    let onPlayStream: (String) -> Void

    @EnvironmentObject private var store: AppStore

    @State private var followedStreams: [TwitchStream] = []
    @State private var topStreams:      [TwitchStream] = []
    @State private var topLang: TopLang = .fr
    @State private var loadingFollowed = false
    @State private var loadingTop      = false
    @State private var errorFollowed: String? = nil
    @State private var section: HomeSection = .live

    enum TopLang: Hashable { case fr, all }

    enum HomeSection: String, CaseIterable, Hashable {
        case live, categories
        func label(_ store: AppStore) -> String {
            switch self {
            case .live:       return store.t("streams")
            case .categories: return store.t("categories")
            }
        }
    }

    private let columns = [GridItem(.flexible(), alignment: .top),
                           GridItem(.flexible(), alignment: .top)]

    var body: some View {
        Group {
            if store.twitchToken == nil {
                loggedOut
            } else {
                VStack(spacing: 0) {
                    TSegmented(items: HomeSection.allCases,
                               selection: $section) { $0.label(store) }

                    if section == .live {
                        liveSection
                    } else {
                        CategoriesView(onPlayStream: onPlayStream)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tDark)
        .onAppear {
            if store.twitchToken != nil && followedStreams.isEmpty {
                Task { await loadAll() }
            }
        }
        .onChange(of: store.twitchToken) { token in
            if token != nil { Task { await loadAll() } }
            else { followedStreams = []; topStreams = [] }
        }
    }

    // MARK: – Non connecté
    @ViewBuilder private var loggedOut: some View {
        VStack(spacing: TSpace.lg) {
            Spacer()
            TEmptyState(
                icon: "person.crop.circle.badge.plus",
                title: store.t("login_prompt"),
                message: store.t("login_points_hint"),
                actionTitle: store.t("btn_login_twitch"),
                action: { Task { await handleLogin() } }
            )
            Spacer()
        }
    }

    // MARK: – Lives
    @ViewBuilder private var liveSection: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TSpace.lg) {

                // ── Chaînes suivies ─────────────────────────────────
                TSectionHeader(store.t("followed_channels"), icon: "heart.fill")
                    .padding(.top, TSpace.md)

                if loadingFollowed {
                    TLoader()
                } else if let err = errorFollowed {
                    TEmptyState(icon: "exclamationmark.triangle", title: err)
                } else if followedStreams.isEmpty {
                    TEmptyState(icon: "moon.zzz",
                                title: store.t("no_followed_live"),
                                message: store.t("no_followed_live_msg"))
                } else {
                    LazyVGrid(columns: columns, spacing: TSpace.md) {
                        ForEach(followedStreams) { stream in
                            StreamCardView(stream: stream) { onPlayStream(stream.userLogin) }
                        }
                    }
                    .padding(.horizontal, TSpace.lg)
                }

                // ── Top ─────────────────────────────────────────────
                TSectionHeader(store.t("top_streams"), icon: "flame.fill") {
                    HStack(spacing: TSpace.xs) {
                        TChip(title: store.t("top_fr"), isOn: topLang == .fr) {
                            topLang = .fr
                            Task { await loadTopStreams(.fr) }
                        }
                        TChip(title: store.t("top_world"), isOn: topLang == .all) {
                            topLang = .all
                            Task { await loadTopStreams(.all) }
                        }
                    }
                }
                .padding(.top, TSpace.sm)

                if loadingTop {
                    TLoader()
                } else if topStreams.isEmpty {
                    TEmptyState(icon: "antenna.radiowaves.left.and.right",
                                title: store.t("no_live"))
                } else {
                    LazyVGrid(columns: columns, spacing: TSpace.md) {
                        ForEach(topStreams) { stream in
                            StreamCardView(stream: stream) { onPlayStream(stream.userLogin) }
                        }
                    }
                    .padding(.horizontal, TSpace.lg)
                }

                Spacer(minLength: 40)
            }
        }
        .refreshable { await loadAll(isRefresh: true) }
    }

    // MARK: – Chargements
    private func handleLogin() async {
        if let token = await TwitchAuthManager.shared.login() {
            store.twitchToken = token
        }
    }

    @MainActor private func loadFollowedStreams() async {
        guard let token = store.twitchToken else { return }
        if followedStreams.isEmpty { loadingFollowed = true }
        errorFollowed = nil

        do {
            let currentUserId: String
            if let existingId = store.twitchUserId, !existingId.isEmpty,
               store.twitchLogin != nil, store.twitchAvatar != nil {
                currentUserId = existingId
            } else {
                guard let user = await getTwitchUser(token: token) else {
                    errorFollowed = store.t("err_loading")
                    loadingFollowed = false
                    return
                }
                currentUserId      = user.id
                store.twitchUserId = user.id
                store.twitchLogin  = user.login
                store.twitchAvatar = user.profileImageURL   // ← avatar du header
                await store.pullFromCloud(userId: user.id)
                logger.authLogin(user: user.displayName)
            }
            followedStreams = try await getFollowedStreams(token: token, userId: currentUserId)
        } catch is CancellationError {
            loadingFollowed = false
            return
        } catch {
            errorFollowed = store.t("err_loading")
            let desc = error.localizedDescription.lowercased()
            if desc.contains("token") || desc.contains("401") || desc.contains("unauthorized") {
                store.logout()
            }
        }
        loadingFollowed = false
    }

    @MainActor private func loadTopStreams(_ l: TopLang, isRefresh: Bool = false) async {
        guard let token = store.twitchToken else { return }
        if topStreams.isEmpty && !isRefresh { loadingTop = true }
        do {
            let fetched = try await getTopStreams(token: token, lang: l == .fr ? "fr" : nil)
            // Réseau capricieux : on ne vide jamais une liste déjà affichée.
            if !fetched.isEmpty { topStreams = fetched }
        } catch is CancellationError {
            loadingTop = false
            return
        } catch {
            logger.warn("HELIX", "Top streams indisponible", error.localizedDescription)
        }
        loadingTop = false
    }

    private func loadAll(isRefresh: Bool = false) async {
        await loadFollowedStreams()
        await loadTopStreams(topLang, isRefresh: isRefresh)
    }
}
