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
    /// Sans compte : curseur de la page suivante du top (pages de 30,
    /// « Charger plus »), remis à zéro à chaque rechargement de la 1ʳᵉ page.
    @State private var topNext: String? = nil
    @State private var topRefused     = false
    @State private var loadingMoreTop = false
    /// Avec le compte : taille du dernier top Helix (50, ou 100 quand des
    /// chaînes ou des catégories sont masquées, pour qu'il reste plein).
    @State private var topFetchCount  = 50
    /// Numéro du dernier chargement du top : une réponse plus ancienne
    /// (top à 50 arrivé après celui à 100) n'écrase pas la plus récente.
    @State private var topGen = 0
    /// Feuille des chaînes et catégories masquées (ligne « N masqués · Gérer »).
    @State private var showHidden     = false
    @State private var topLang: TopLang = .local
    @State private var loadingFollowed = false
    /// Vrai d'emblée : l'accueil est recréé à chaque retour sur l'onglet, et
    /// le top se charge aussitôt (loadAll) ; sinon « Aucune chaîne en live »
    /// s'affichait le temps de la première réponse.
    @State private var loadingTop      = true
    @State private var errorFollowed: String? = nil
    @State private var section: HomeSection = .live
    @State private var showWebLogin = false
    @Environment(\.scenePhase) private var scenePhase
    /// Dernier chargement des lives : relus au retour dans l'app et toutes
    /// les 3 min à l'écran (l'app laissée ouverte gardait la liste d'avant).
    @State private var lastLoad = Date.distantPast
    /// Bandeau « session web » masqué jusqu'à cette date (bouton ✕).
    @AppStorage("web_banner_hidden_until") private var webBannerHiddenUntil: Double = 0
    @ObservedObject private var announcements = AnnouncementService.shared
    @ObservedObject private var polls = PollService.shared

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
        // Avec ou sans compte : sans, lives et catégories passent par des
        // requêtes publiques, et l'accueil invite à se connecter.
        VStack(spacing: 0) {
            // Vue Catégories masquée (Réglages → Personnaliser) : les lives
            // seuls, sans sélecteur.
            if showsCard("categories") {
                TSegmented(items: HomeSection.allCases,
                           selection: $section) { $0.label(store) }
            }

            if section == .live || !showsCard("categories") {
                liveSection
            } else {
                CategoriesView(onPlayStream: onPlayStream)
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
        // App reprise après un moment : lives relus (ceux qui ont commencé ou
        // fini entre-temps), sans avoir à tirer la liste ni relancer l'app.
        .onChange(of: scenePhase) { phase in
            if phase == .active, Date().timeIntervalSince(lastLoad) > 60 {
                Task { await loadAll(isRefresh: true) }
            }
        }
        // À l'écran, app au premier plan : relus toutes les 3 min.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 180_000_000_000)
                guard !Task.isCancelled,
                      await MainActor.run(body: { UIApplication.shared.applicationState == .active }),
                      Date().timeIntervalSince(lastLoad) >= 170 else { continue }
                await loadAll(isRefresh: true)
            }
        }
        .sheet(isPresented: $showWebLogin) {
            TwitchWebLoginSheet(
                clearSession: store.webSessionExpired || store.webSessionMismatch != nil,
                expectedLogin: store.twitchLogin,
                onComplete: { webToken, webLogin in
                    showWebLogin = false
                    Task {
                        if await store.adoptWebToken(webToken, login: webLogin) {
                            logger.success("AUTH/WEB", "Session web connectée depuis l'accueil", nil)
                        }
                    }
                },
                onCancel: { showWebLogin = false }
            )
        }
        .onChange(of: store.twitchToken) { token in
            // Déconnexion (sur un 401 aussi) ou autre compte : l'erreur de
            // l'ancien jeton ne reste pas à la place de l'invitation.
            errorFollowed = nil
            if token == nil { followedStreams = []; topStreams = [] }
            Task { await loadAll() }
        }
        // Chaîne suivie ou retirée sur Twitch (page d'une chaîne, chat) : les
        // suivis sont relus, un instant après, le temps que Helix en tienne
        // compte. Sans cela, elle n'apparaissait qu'au prochain rafraîchissement.
        .onReceive(NotificationCenter.default.publisher(for: .twitchFollowsChanged)) { _ in
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await loadFollowedStreams()
                await loadLocalFollows()
            }
        }
        // Langue du top changée dans les réglages : on recharge tout de suite.
        .onChange(of: store.topLang) { _ in
            topLang = .local
            topStreams = []
            Task { await loadTopStreams(.local) }
        }
        // Chaîne ou catégorie masquée : le top se filtre tout seul ; il ne
        // reste qu'à le compléter s'il devient trop court.
        .onChange(of: store.hidden) { _ in Task { await refillTopIfNeeded() } }
        .sheet(isPresented: $showHidden) {
            HiddenContentSheet().environmentObject(store)
        }
    }

    // MARK: – Accueil (avec ou sans compte)
    /// Suivis du compte Twitch et de cet appareil, sans doublon, mêlés et
    /// triés par audience comme sur Twitch (pas relégués en bas) ; les
    /// streamers épinglés passent devant, dans l'ordre d'épinglage.
    private var allFollowedLive: [TwitchStream] {
        let known = Set(followedStreams.map { $0.userLogin.lowercased() })
        return (followedStreams + localLive.filter { !known.contains($0.userLogin.lowercased()) })
            .sorted { a, b in
                pinnedFirst(a.userLogin, b.userLogin) ?? (a.viewerCount > b.viewerCount)
            }
    }

    /// Ordre imposé par l'épinglage (nil : aucun des deux n'est épinglé).
    private func pinnedFirst(_ a: String, _ b: String) -> Bool? {
        switch (store.pinRank(a), store.pinRank(b)) {
        case let (x?, y?): return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return nil
        }
    }

    /// Hors ligne : les épinglés d'abord, puis par nom.
    private var sortedOffline: [ChannelBrief] {
        offlineChannels.sorted { a, b in
            pinnedFirst(a.login, b.login)
                ?? (a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending)
        }
    }

    /// Grille de cartes ou liste, selon le réglage. `pinnable` : chaînes
    /// suivies, qu'on peut épingler en tête (appui long). `hideable` : top,
    /// où l'appui long propose de masquer la chaîne ou sa catégorie.
    @ViewBuilder private func streamsBlock(_ streams: [TwitchStream], pinnable: Bool = false,
                                           hideable: Bool = false) -> some View {
        if store.homeListLayout {
            LazyVStack(spacing: TSpace.md) {
                ForEach(streams) { stream in
                    StreamRowView(stream: stream, pinnable: pinnable, hideable: hideable) { onPlayStream(stream.userLogin) }
                }
            }
            .padding(.horizontal, TSpace.lg)
        } else {
            LazyVGrid(columns: columns, spacing: TSpace.md) {
                ForEach(streams) { stream in
                    StreamCardView(stream: stream, pinnable: pinnable, hideable: hideable) { onPlayStream(stream.userLogin) }
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
                // Jeton refusé par Twitch (401) : on dit pourquoi on a été
                // déconnecté, même après un passage par un autre onglet.
                Text(store.t(store.oauthExpired ? "session_expired" : "login_prompt"))
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
                if showsCard("announcement"), let a = announcements.current {
                    AnnouncementBanner(announcement: a) { announcements.dismiss(a) }
                        .padding(.horizontal, TSpace.lg)
                        .padding(.top, TSpace.md)
                }
                // ── Sondage du développeur (si un est en cours) ─────
                if showsCard("poll"), let p = polls.poll {
                    DevPollCard(poll: p)
                        .padding(.horizontal, TSpace.lg)
                        .padding(.top, announcements.current == nil || !showsCard("announcement") ? TSpace.md : 0)
                }

                // ── Pas de compte : invitation compacte ──────────────
                if store.twitchToken == nil && showsCard("login") {
                    loginCard
                        .padding(.horizontal, TSpace.lg)
                        .padding(.top, TSpace.md)
                }

                // ── Session web absente : points, coffres, prédictions ──
                if showsCard("web") && store.twitchToken != nil && store.twitchWebToken == nil
                    && Date().timeIntervalSince1970 > webBannerHiddenUntil {
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
                        // Dans l'ordre choisi (Réglages → Personnaliser).
                        HStack(spacing: TSpace.sm) {
                            ForEach(store.customization.visibleHomeChips, id: \.self) { key in
                                homeChip(key)
                            }
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

                switch shownTab {
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

    // MARK: – Personnalisation (Réglages → Personnaliser)
    private func showsCard(_ key: String) -> Bool { store.customization.shows(home: key) }

    /// Onglets des lives : 0 = suivies en live, 1 = top, 2 = hors ligne.
    private static func chipTab(_ key: String) -> Int {
        switch key {
        case "top":     return 1
        case "offline": return 2
        default:        return 0
        }
    }

    /// Onglet des lives affiché : le dernier choisi s'il est encore là, sinon
    /// le premier de ceux qui restent.
    private var shownTab: Int {
        let tabs = store.customization.visibleHomeChips.map(Self.chipTab)
        return tabs.contains(liveTab) ? liveTab : (tabs.first ?? 0)
    }

    @ViewBuilder
    private func homeChip(_ key: String) -> some View {
        let tab = Self.chipTab(key)
        switch tab {
        case 1:  TChip(title: store.t("top_streams"), isOn: shownTab == 1) { liveTab = 1 }
        case 2:  TChip(title: store.t("offline_channels"), icon: "moon.fill", isOn: shownTab == 2) { liveTab = 2 }
        default: TChip(title: store.t("home_followed"), isOn: shownTab == 0) { liveTab = 0 }
        }
    }

    // MARK: – Onglet « Suivies » (en direct seulement)
    @ViewBuilder private var followedTab: some View {
        let followed = allFollowedLive
        if store.twitchToken == nil && store.localFollows.isEmpty && followed.isEmpty {
            // Rien à lire : l'invitation tout de suite, sans chargeur.
            TEmptyState(icon: "heart",
                        title: store.t("local_follow_empty"),
                        message: store.t("local_follow_empty_msg"))
        } else if (loadingFollowed || !followsLoaded) && followed.isEmpty && offlineChannels.isEmpty {
            // Suivis (du compte ou de l'appareil) pas encore lus : sans
            // compte, « aucune chaîne en direct » s'affichait le temps de la
            // lecture, puis la chaîne apparaissait.
            TLoader()
        } else if let err = errorFollowed, followed.isEmpty, offlineChannels.isEmpty {
            TEmptyState(icon: "exclamationmark.triangle", title: err)
        } else if !followed.isEmpty {
            streamsBlock(followed, pinnable: true)
        } else if followsFailed {
            // Lecture des suivis ratée, rien d'affiché : ce n'est pas
            // « personne en direct ».
            TEmptyState(icon: "exclamationmark.triangle", title: store.t("err_loading"))
        } else if !offlineChannels.isEmpty {
            // Personne en live : un pas vers l'onglet des chaînes hors ligne.
            TEmptyState(icon: "moon.zzz",
                        title: store.t("no_followed_live"),
                        message: store.t("no_followed_live_msg"),
                        actionTitle: store.customization.visibleHomeChips.contains("offline")
                            ? "\(store.t("see_offline")) · \(offlineChannels.count)" : nil) { liveTab = 2 }
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
                ForEach(sortedOffline) { offlineRow($0) }
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
                    HStack(spacing: 4) {
                        if store.isPinned(ch.login) { PinnedMark() }
                        Text(ch.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.tText)
                            .lineLimit(1)
                    }
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
        .contextMenu { PinStreamerMenuButton(login: ch.login) }
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

        // Chaînes et catégories masquées écartées, dans l'ordre de Twitch.
        // Avec le compte, 50 au plus (Helix en donne 100 quand il y a des
        // masqués) ; sans, tout ce qui a été chargé, page après page.
        let top = HiddenContent.fill(top: topStreams, keep: store.showsStream,
                                     limit: store.twitchToken == nil ? nil : 50)
        if loadingTop {
            TLoader()
        } else if topStreams.isEmpty {
            TEmptyState(icon: "antenna.radiowaves.left.and.right",
                        title: store.t("no_live"))
        } else {
            if top.streams.isEmpty {
                TEmptyState(icon: "antenna.radiowaves.left.and.right",
                            title: store.t("no_live"))
            } else {
                streamsBlock(top.streams, hideable: true)
            }
            // Visible même si tout est masqué : sinon on croirait à une panne.
            if top.hidden > 0 {
                HiddenFooter(count: top.hidden) { showHidden = true }
            }
            if topNext != nil {
                TLoadMoreButton(busy: loadingMoreTop) { Task { await loadMoreTop() } }
            } else if topRefused {
                TListEndNote(key: "more_unavailable")
            }
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
                // Jeton refusé (401) : levé, donc déconnexion plus bas.
                guard let user = try await fetchTwitchUser(token: token) else {
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
            // lancements, la relecture n'aurait sinon plus jamais lieu. Sans
            // l'attendre : une relecture ratée se retente à chaque passage,
            // et les lives suivis attendaient sinon son délai (15 s) quand le
            // Worker ne répond pas.
            Task { await store.refreshFromCloudIfStale(userId: currentUserId) }
            followedStreams = try await getFollowedStreams(token: token, userId: currentUserId)
        } catch is CancellationError {
            loadingFollowed = false
            return
        } catch {
            errorFollowed = store.t("err_loading")
            if (error as? URLError)?.code == .userAuthenticationRequired {
                // Jeton refusé : déconnexion ; l'invitation à se reconnecter
                // remplace l'erreur (onChange du jeton).
                store.oauthExpired = true
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
        topGen += 1
        let gen = topGen
        if topStreams.isEmpty && !isRefresh { loadingTop = true }
        // Plus de « Charger plus » pendant le rechargement : l'ancienne suite
        // n'est peut-être plus la bonne (autre langue), et la garde
        // `topNext == after` de loadMoreTop écarte une page déjà en route.
        topNext = nil
        topRefused = false
        guard let token = store.twitchToken else {
            // Sans compte : même top, par la requête publique, par pages de
            // 30 ; la suite passe par le Client-ID d'Android (loadMoreTop).
            // Chaque rechargement repart de la 1ʳᵉ page ; en cas d'échec, la
            // liste est gardée, sans suite.
            let page = await getTopStreamsPageGQL(lang: lang, after: nil)
            // Un chargement plus récent est parti : c'est lui qui conclut.
            guard gen == topGen else { return }
            if let page, !page.streams.isEmpty {
                topStreams = page.streams
                topNext = page.next
            }
            loadingTop = false
            await refillTopIfNeeded()
            return
        }
        // Avec le compte : Helix, 50 lives d'un coup (100 s'il y a des
        // masqués, filtrés à l'affichage), sans suite.
        let count = store.hidden.isEmpty ? 50 : 100
        var applied = false
        do {
            let fetched = try await getTopStreams(token: token, lang: lang, count: count)
            guard gen == topGen else { return }
            // Réseau capricieux : on ne vide jamais une liste déjà affichée.
            if !fetched.isEmpty {
                topStreams = fetched
                topFetchCount = count
                applied = true
            }
        } catch is CancellationError {
            if gen == topGen { loadingTop = false }
            return
        } catch {
            guard gen == topGen else { return }
            logger.warn("HELIX", "Top streams indisponible", error.localizedDescription)
            // Helix refuse ou ne répond pas (429, panne ; un jeton refusé
            // déconnecte par les suivis) : le top public plutôt qu'une liste
            // vide, sans suite (« Charger plus » est réservé au top sans compte).
            let page = await getTopStreamsPageGQL(lang: lang, after: nil)
            guard gen == topGen else { return }
            if let page, !page.streams.isEmpty { topStreams = page.streams }
        }
        loadingTop = false
        // Masquage fait pendant un tirage à 50 : on complète tout de suite
        // (une fois : le suivant est à 100 ; rien après un échec).
        if applied && count < 100 { await refillTopIfNeeded() }
    }

    /// Page suivante du top sans compte (30 lives), sans doublon : les lives
    /// bougent d'une page à l'autre. Si Twitch refuse la suite, un message.
    @MainActor private func loadMoreTop() async {
        guard let after = topNext, !loadingMoreTop, store.twitchToken == nil else { return }
        let l = topLang
        let lang = l == .local ? TopLanguage.resolved(store.topLang) : nil
        loadingMoreTop = true
        defer { loadingMoreTop = false }
        let result = await loadMorePages(
            after: .gql(after), current: topStreams, token: nil,
            gql: { cur in
                guard let p = await getTopStreamsPageGQL(lang: lang, after: cur) else { return nil }
                return (p.streams, p.next, p.refused)
            },
            helix: { _, _ in nil })
        // Top rechargé entre-temps (tirage, langue) : il est reparti de la 1ʳᵉ page.
        guard l == topLang, topNext == after else { return }
        topStreams += result.fresh
        if case .gql(let next)? = result.cursor { topNext = next } else { topNext = nil }
        topRefused = result.locked
    }

    /// Des lives du top sont masqués : de quoi le garder plein. Sans compte,
    /// la page suivante du top (Client-ID d'Android, exacte et dans l'ordre
    /// de Twitch) quand il en reste moins de 24 ; avec le compte, Helix à
    /// 100 au lieu de 50, une fois.
    @MainActor private func refillTopIfNeeded() async {
        guard !topStreams.isEmpty, !loadingTop, !store.hidden.isEmpty else { return }
        if store.twitchToken == nil {
            let visible = HiddenContent.fill(top: topStreams, keep: store.showsStream).streams.count
            guard visible < 24, topNext != nil, !loadingMoreTop else { return }
            await loadMoreTop()
        } else if topFetchCount < 100 {
            await loadTopStreams(topLang, isRefresh: true)
        }
    }

    /// Suivis du compte, puis ceux de l'appareil (qui demandent l'identifiant
    /// du compte) et les catégories suivies. Le top part en même temps : il
    /// ne dépend de rien, et l'onglet Top attendait sinon tous les suivis
    /// (jusqu'à 10 pages Helix et autant de requêtes GQL).
    @MainActor private func loadAll(isRefresh: Bool = false) async {
        lastLoad = Date()
        let lang = topLang
        async let top: Void = loadTopStreams(lang, isRefresh: isRefresh)
        await loadFollowedStreams()
        await loadLocalFollows()
        await loadAccountFollowedCategories()
        await top
    }

    /// Catégories suivies sur Twitch (session web), lues dès l'accueil : le
    /// top ne les masque pas et son menu ne propose pas de les masquer, même
    /// avant un passage par l'onglet Catégories. En cas d'échec, la liste
    /// déjà connue est gardée.
    @MainActor private func loadAccountFollowedCategories() async {
        guard let web = store.twitchWebToken,
              let list = await getFollowedCategoriesGQL(webToken: web),
              store.twitchWebToken == web else { return }
        store.accountFollowedCategoryIds = Set(list.map(\.id))
    }
}
