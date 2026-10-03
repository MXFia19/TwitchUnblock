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
    @State private var topLang: TopLang = .local
    @State private var loadingFollowed = false
    @State private var loadingTop      = false
    @State private var errorFollowed: String? = nil
    @State private var section: HomeSection = .live
    @State private var showWebLogin = false
    /// Bandeau « session web » masqué jusqu'à cette date (bouton ✕).
    @AppStorage("web_banner_hidden_until") private var webBannerHiddenUntil: Double = 0
    @ObservedObject private var announcements = AnnouncementService.shared

    enum TopLang: Hashable { case local, all }

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
        .sheet(isPresented: $showWebLogin) {
            TwitchWebLoginSheet(
                clearSession: store.webSessionExpired,
                onComplete: { webToken, webLogin in
                    showWebLogin = false
                    if store.twitchLogin == nil, let l = webLogin { store.twitchLogin = l }
                    store.twitchWebToken = webToken
                    store.webSessionExpired = false
                    logger.success("AUTH/WEB", "Session web connectée depuis l'accueil", nil)
                },
                onCancel: { showWebLogin = false }
            )
        }
        .onChange(of: store.twitchToken) { token in
            if token != nil { Task { await loadAll() } }
            else { followedStreams = []; topStreams = [] }
        }
        // Langue du top changée dans les réglages : on recharge tout de suite.
        .onChange(of: store.topLang) { _ in
            topLang = .local
            topStreams = []
            Task { await loadTopStreams(.local) }
        }
    }

    // MARK: – Non connecté
    @ViewBuilder private var loggedOut: some View {
        VStack(spacing: TSpace.lg) {
            if let a = announcements.current {
                AnnouncementBanner(announcement: a) { announcements.dismiss(a) }
                    .padding(.horizontal, TSpace.lg)
                    .padding(.top, TSpace.md)
            }
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

    // MARK: – Bandeau session web
    @ViewBuilder private var webSessionBanner: some View {
        let expired = store.webSessionExpired
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color.tPrimary, Color.tPurple],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 38, height: 38)
                Image(systemName: expired ? "exclamationmark.triangle.fill" : "sparkles")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(store.t(expired ? "web_expired" : "web_banner_title"))
                    .font(.tCardTitle).foregroundColor(.tText)
                Text(store.t("web_banner_msg"))
                    .font(.tMeta).foregroundColor(.tMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button { showWebLogin = true } label: {
                    Text(store.t(expired ? "web_reconnect" : "web_banner_btn"))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.tPrimary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
            // ✕ : masqué une semaine, puis il revient (la session reste utile).
            Button {
                withAnimation { webBannerHiddenUntil = Date().timeIntervalSince1970 + 7 * 86400 }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.tMuted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color.tCard)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Color.tPrimary.opacity(0.3), lineWidth: 1))
    }

    // MARK: – Lives
    @ViewBuilder private var liveSection: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TSpace.lg) {

                // ── Annonce du développeur (si une est en cours) ────
                if let a = announcements.current {
                    AnnouncementBanner(announcement: a) { announcements.dismiss(a) }
                        .padding(.horizontal, TSpace.lg)
                        .padding(.top, TSpace.md)
                }

                // ── Session web absente : points, coffres, prédictions ──
                if store.twitchWebToken == nil && Date().timeIntervalSince1970 > webBannerHiddenUntil {
                    webSessionBanner
                        .padding(.horizontal, TSpace.lg)
                        .padding(.top, TSpace.md)
                }

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
                        TChip(title: TopLanguage.name(TopLanguage.resolved(store.topLang), in: store.lang), isOn: topLang == .local) {
                            topLang = .local
                            Task { await loadTopStreams(.local) }
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
            store.adoptToken(token)
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
                logger.authLogin(user: user.displayName)
            }
            // Dans les deux cas, et plus seulement au premier chargement du
            // profil : l'identifiant étant désormais gardé entre deux
            // lancements, la relecture n'aurait sinon plus jamais lieu.
            await store.refreshFromCloudIfStale(userId: currentUserId)
            followedStreams = try await getFollowedStreams(token: token, userId: currentUserId)
        } catch is CancellationError {
            loadingFollowed = false
            return
        } catch {
            errorFollowed = store.t("err_loading")
            if (error as? URLError)?.code == .userAuthenticationRequired {
                store.logout()
            }
        }
        loadingFollowed = false
    }

    @MainActor private func loadTopStreams(_ l: TopLang, isRefresh: Bool = false) async {
        guard let token = store.twitchToken else { return }
        if topStreams.isEmpty && !isRefresh { loadingTop = true }
        do {
            let fetched = try await getTopStreams(token: token, lang: l == .local ? TopLanguage.resolved(store.topLang) : nil)
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
