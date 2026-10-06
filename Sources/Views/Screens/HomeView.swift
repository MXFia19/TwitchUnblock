import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Accueil : ce qui est en direct maintenant.
//  Deux vues — les lives (suivies en direct, top, suivies hors ligne) et les
//  catégories.
// ═══════════════════════════════════════════════════════════════════════════

struct HomeView: View {
    let onPlayStream: (String) -> Void

    @EnvironmentObject private var store: AppStore

    @State private var followedStreams: [TwitchStream] = []
    /// Lives des chaînes suivies sans compte (sur cet appareil).
    @State private var localLive: [TwitchStream] = []
    /// Chaînes suivies hors ligne (compte + appareil), pour ouvrir leur page.
    @State private var offlineChannels: [ChannelBrief] = []
    /// Toutes les chaînes suivies par le compte Twitch.
    @State private var twitchFollowLogins: [String] = []
    /// Liste des suivis (en live et hors ligne) lue au moins une fois, et
    /// échec de cette lecture quand rien n'est encore affiché.
    @State private var followsLoaded = false
    @State private var followsFailed = false
    /// Sous-onglet des lives : 0 = suivies en live, 1 = top, 2 = suivies hors ligne.
    @AppStorage("home_live_tab") private var liveTab = 0
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
    /// Suivis du compte Twitch et de cet appareil, sans doublon, mêlés et
    /// triés par audience comme sur Twitch (pas relégués en bas).
    private var allFollowedLive: [TwitchStream] {
        let known = Set(followedStreams.map { $0.userLogin.lowercased() })
        return (followedStreams + localLive.filter { !known.contains($0.userLogin.lowercased()) })
            .sorted { $0.viewerCount > $1.viewerCount }
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

                // ── Suivies | Top | Hors ligne : des onglets plutôt qu'à la
                // suite. Les chaînes hors ligne ont le leur : « Suivies » ne
                // montre plus que ce qui est en direct. ──
                HStack(spacing: TSpace.sm) {
                    // Défile si les trois ne tiennent pas (langue, grand texte).
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: TSpace.sm) {
                            TChip(title: store.t("home_followed"), isOn: liveTab == 0) { liveTab = 0 }
                            TChip(title: store.t("top_streams"), isOn: liveTab == 1) { liveTab = 1 }
                            TChip(title: store.t("offline_channels"), icon: "moon.fill", isOn: liveTab == 2) { liveTab = 2 }
                        }
                    }
                    .tourAnchor(.homeTabs)
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
                .padding(.horizontal, TSpace.lg)
                .padding(.top, TSpace.md)

                switch liveTab {
                case 1:  topTab
                case 2:  offlineTab
                default: followedTab
                }

                Spacer(minLength: 40)
            }
        }
        // Tâche détachée : tirer pour rafraîchir annule sa propre tâche dès que
        // la vue se redessine, et la requête annulée vidait les suivis locaux.
        .refreshable { await Task { await loadAll(isRefresh: true) }.value }
    }

    // MARK: – Onglet « Suivies » (en direct seulement)
    @ViewBuilder private var followedTab: some View {
        let followed = allFollowedLive
        if loadingFollowed && followed.isEmpty && offlineChannels.isEmpty {
            TLoader()
        } else if let err = errorFollowed, followed.isEmpty, offlineChannels.isEmpty {
            TEmptyState(icon: "exclamationmark.triangle", title: err)
        } else if !followed.isEmpty {
            streamsBlock(followed)
        } else if store.twitchToken == nil && store.localFollows.isEmpty {
            TEmptyState(icon: "heart",
                        title: store.t("local_follow_empty"),
                        message: store.t("local_follow_empty_msg"))
        } else if !offlineChannels.isEmpty {
            // Personne en live : un pas vers l'onglet des chaînes hors ligne.
            TEmptyState(icon: "moon.zzz",
                        title: store.t("no_followed_live"),
                        message: store.t("no_followed_live_msg"),
                        actionTitle: "\(store.t("see_offline")) · \(offlineChannels.count)") { liveTab = 2 }
        } else {
            TEmptyState(icon: "moon.zzz",
                        title: store.t("no_followed_live"),
                        message: store.t("no_followed_live_msg"))
        }
    }

    // MARK: – Onglet « Hors ligne »
    /// Chaînes suivies hors ligne : accès direct à leur page (VODs, clips,
    /// diffusions supprimées) sans chercher.
    @ViewBuilder private var offlineTab: some View {
        if !offlineChannels.isEmpty {
            TSectionHeader("\(store.t("offline_channels")) · \(offlineChannels.count)", icon: "moon.fill")
            LazyVStack(spacing: 2) {
                ForEach(offlineChannels) { offlineRow($0) }
            }
            .padding(.horizontal, TSpace.lg)
        } else if !followsLoaded {
            TLoader()
        } else if followsFailed {
            TEmptyState(icon: "exclamationmark.triangle", title: store.t("err_loading"))
        } else if !allFollowedLive.isEmpty {
            TEmptyState(icon: "dot.radiowaves.left.and.right", title: store.t("offline_all_live"))
        } else {
            TEmptyState(icon: "heart",
                        title: store.t("local_follow_empty"),
                        message: store.t("local_follow_empty_msg"))
        }
    }

    @ViewBuilder private func offlineRow(_ ch: ChannelBrief) -> some View {
        Button { store.openChannelPage(ch.login) } label: {
            HStack(spacing: TSpace.md) {
                AsyncImage(url: URL(string: ch.avatar)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(Color.tSurface)
                }
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                .opacity(0.75)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ch.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.tText)
                        .lineLimit(1)
                    if let end = ch.lastEnd {
                        let label = offlineLabel(since: end, store: store)
                        if !label.isEmpty {
                            Text(label)
                                .font(.system(size: 12))
                                .foregroundColor(.tMuted)
                                .lineLimit(1)
                        }
                    }
                }
                if store.isLocallyFollowed(ch.login) && !twitchFollowLogins.contains(ch.login) {
                    Image(systemName: "iphone")
                        .font(.system(size: 11))
                        .foregroundColor(.tMuted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.tMuted)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: – Onglet « Top »
    @ViewBuilder private var topTab: some View {
        HStack(spacing: TSpace.xs) {
            TChip(title: TopLanguage.name(TopLanguage.resolved(store.topLang), in: store.lang), isOn: topLang == .local) {
                topLang = .local
                Task { await loadTopStreams(.local) }
            }
            TChip(title: store.t("top_world"), isOn: topLang == .all) {
                topLang = .all
                Task { await loadTopStreams(.all) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TSpace.lg)

        if loadingTop {
            TLoader()
        } else if topStreams.isEmpty {
            TEmptyState(icon: "antenna.radiowaves.left.and.right",
                        title: store.t("no_live"))
        } else {
            streamsBlock(topStreams)
        }
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
    /// Suivis de l'appareil en live, et toutes les chaînes suivies hors ligne
    /// (compte Twitch + appareil), en une requête GQL publique.
    @MainActor private func loadLocalFollows() async {
        defer { followsLoaded = true }
        if let token = store.twitchToken, let uid = store.twitchUserId, !uid.isEmpty,
           let logins = await getFollowedLogins(token: token, userId: uid) {
            twitchFollowLogins = logins.map { $0.lowercased() }
        } else if store.twitchToken == nil {
            twitchFollowLogins = []
        }
        store.accountFollowLogins = twitchFollowLogins   // pour l'export
        var seen = Set<String>()
        let all = (twitchFollowLogins + store.localFollows).filter { seen.insert($0).inserted }
        // Échec réseau : on garde les listes affichées au lieu de les vider.
        guard let infos = await getChannelsGQL(logins: all) else {
            followsFailed = offlineChannels.isEmpty
            return
        }
        followsFailed = false
        localLive = infos.compactMap { $0.stream }
        offlineChannels = infos.filter { $0.stream == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
