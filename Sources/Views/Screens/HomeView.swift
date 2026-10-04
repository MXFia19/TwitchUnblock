import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Accueil : ce qui est en direct maintenant.
//  Deux vues — les lives (chaînes suivies + top) et les catégories.
// ═══════════════════════════════════════════════════════════════════════════

struct HomeView: View {
    let onPlayStream: (String) -> Void

    @EnvironmentObject private var store: AppStore

    @State private var followedStreams: [TwitchStream] = []
    /// Lives des chaînes suivies sans compte (sur cet appareil).
    @State private var localLive: [TwitchStream] = []
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
                // Sans compte : lives des chaînes suivies sur cet appareil et
                // top (requêtes publiques), avec une invitation à se connecter.
                liveSection
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
            if followedStreams.isEmpty && localLive.isEmpty && topStreams.isEmpty {
                Task { await loadAll() }
            }
        }
        // Chaîne suivie ou retirée sur cet appareil : liste à jour.
        .onChange(of: store.localFollows) { _ in Task { await loadLocalFollows() } }
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
            if token == nil { followedStreams = []; topStreams = [] }
            Task { await loadAll() }
        }
        // Langue du top changée dans les réglages : on recharge tout de suite.
        .onChange(of: store.topLang) { _ in
            topLang = .local
            topStreams = []
            Task { await loadTopStreams(.local) }
        }
    }

    // MARK: – Accueil (avec ou sans compte)
    /// Suivis du compte Twitch, puis ceux de cet appareil qui n'y sont pas déjà.
    private var allFollowedLive: [TwitchStream] {
        let known = Set(followedStreams.map { $0.userLogin.lowercased() })
        return followedStreams + localLive.filter { !known.contains($0.userLogin.lowercased()) }
    }

    /// Grille de cartes ou liste, selon le réglage.
    @ViewBuilder private func streamsBlock(_ streams: [TwitchStream]) -> some View {
        if store.homeListLayout {
            LazyVStack(spacing: TSpace.md) {
                ForEach(streams) { stream in
                    StreamRowView(stream: stream) { onPlayStream(stream.userLogin) }
                }
            }
            .padding(.horizontal, TSpace.lg)
        } else {
            LazyVGrid(columns: columns, spacing: TSpace.md) {
                ForEach(streams) { stream in
                    StreamCardView(stream: stream) { onPlayStream(stream.userLogin) }
                }
            }
            .padding(.horizontal, TSpace.lg)
        }
    }

    /// Sans compte : invitation compacte (le reste de l'accueil marche sans).
    @ViewBuilder private var loginCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 26))
                .foregroundColor(.tPrimary)
            VStack(alignment: .leading, spacing: 6) {
                Text(store.t("login_prompt"))
                    .font(.tCardTitle).foregroundColor(.tText)
                Text(store.t("login_optional_msg"))
                    .font(.tMeta).foregroundColor(.tMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button { Task { await handleLogin() } } label: {
                    Text(store.t("btn_login_twitch"))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.tPrimary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.tCard)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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

                // ── Pas de compte : invitation compacte ──────────────
                if store.twitchToken == nil {
                    loginCard
                        .padding(.horizontal, TSpace.lg)
                        .padding(.top, TSpace.md)
                }

                // ── Session web absente : points, coffres, prédictions ──
                if store.twitchToken != nil && store.twitchWebToken == nil && Date().timeIntervalSince1970 > webBannerHiddenUntil {
                    webSessionBanner
                        .padding(.horizontal, TSpace.lg)
                        .padding(.top, TSpace.md)
                }

                // ── Chaînes suivies ─────────────────────────────────
                TSectionHeader(store.t("followed_channels"), icon: "heart.fill") {
                    // Grille ou liste, au choix (aussi dans Réglages → Général).
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { store.homeListLayout.toggle() }
                    } label: {
                        Image(systemName: store.homeListLayout ? "square.grid.2x2" : "list.bullet")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.tMuted)
                            .frame(width: 32, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(store.t(store.homeListLayout ? "layout_grid" : "layout_list"))
                }
                .padding(.top, TSpace.md)

                let followed = allFollowedLive
                if loadingFollowed && followed.isEmpty {
                    TLoader()
                } else if let err = errorFollowed, followed.isEmpty {
                    TEmptyState(icon: "exclamationmark.triangle", title: err)
                } else if followed.isEmpty {
                    if store.twitchToken == nil && store.localFollows.isEmpty {
                        TEmptyState(icon: "heart",
                                    title: store.t("local_follow_empty"),
                                    message: store.t("local_follow_empty_msg"))
                    } else {
                        TEmptyState(icon: "moon.zzz",
                                    title: store.t("no_followed_live"),
                                    message: store.t("no_followed_live_msg"))
                    }
                } else {
                    streamsBlock(followed)
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
                    streamsBlock(topStreams)
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

    /// Lives des chaînes suivies sur cet appareil (sans compte, GQL public).
    @MainActor private func loadLocalFollows() async {
        localLive = await getLiveStreamsGQL(logins: store.localFollows)
    }

    @MainActor private func loadTopStreams(_ l: TopLang, isRefresh: Bool = false) async {
        let lang = l == .local ? TopLanguage.resolved(store.topLang) : nil
        if topStreams.isEmpty && !isRefresh { loadingTop = true }
        guard let token = store.twitchToken else {
            // Sans compte : même top, par la requête publique.
            let fetched = await getTopStreamsGQL(lang: lang)
            if !fetched.isEmpty { topStreams = fetched }
            loadingTop = false
            return
        }
        do {
            let fetched = try await getTopStreams(token: token, lang: lang)
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
        await loadLocalFollows()
        await loadTopStreams(topLang, isRefresh: isRefresh)
    }
}
