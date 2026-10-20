import SwiftUI
import AVFoundation
import Combine

// ═══════════════════════════════════════════════════════════════════════════
//  Onglet Découvrir : un live (ou un clip) par écran, qu'on fait défiler
//  vers le haut, comme le fil de l'app Twitch. La page affichée joue un
//  aperçu muet en petite qualité ; un toucher ouvre le lecteur complet
//  (son, chat). Masquable dans Réglages → Personnaliser.
// ═══════════════════════════════════════════════════════════════════════════

// MARK: – Verrou des aperçus
/// Lecteur ou multi-live ouvert : aucun aperçu ne joue, quel que soit l'ordre
/// des mises à jour de l'écran — l'aperçu arrêté au toucher pouvait être
/// relancé juste après, avant que l'écran ne voie le lecteur (son en double).
/// Posé par MainTabView au lancement d'une lecture, retiré à sa fermeture ;
/// toujours sur le fil principal.
final class DiscoverGate: ObservableObject {
    static let shared = DiscoverGate()
    @Published var blocked = false
}

// MARK: – Données et aperçus
/// Un seul fil pour toute l'app : l'onglet est recréé à chaque changement
/// d'onglet (`switch` de MainTabView), et un fil à lui repartait du début,
/// en Lives, son recoupé. Le top n'est relu qu'après 10 min.
@MainActor
final class DiscoverFeed: ObservableObject {
    static let shared = DiscoverFeed()

    /// Lecteur ouvert : l'aperçu en cours s'arrête aussitôt.
    private var gateWatch: AnyCancellable?

    private init() {
        gateWatch = DiscoverGate.shared.$blocked.sink { [weak self] blocked in
            if blocked { self?.stop() }
        }
    }

    enum Preview: Equatable { case loading, ready, failed }
    enum Mode: Hashable { case live, clips }

    /// Mode affiché, et page affichée dans chacun.
    @Published var mode = Mode.live
    @Published var liveIndex = 0
    @Published var clipIndex = 0
    /// Écrans du fil affichés (deux le temps d'un changement de thème) : à 0,
    /// un chargement fini après la sortie de l'onglet ne relance aucun aperçu.
    var screens = 0

    @Published private(set) var lives: [TwitchStream] = []
    @Published private(set) var clips: [FeedClip] = []
    @Published private(set) var livesLoaded = false
    @Published private(set) var livesFailed = false
    @Published private(set) var clipsLoaded = false
    @Published private(set) var clipsFailed = false
    /// État de l'aperçu, par page (« live:<login> », « clip:<slug> »).
    @Published private(set) var preview: [String: Preview] = [:]
    /// Photo des chaînes, connue une fois leur live résolu.
    @Published private(set) var avatars: [String: String] = [:]
    /// Page dont l'aperçu joue (nil : aucune).
    @Published private(set) var playing: String?

    /// Un seul lecteur pour tout le fil, toujours muet.
    let player: AVPlayer = {
        let p = AVPlayer()
        p.isMuted = true
        p.preventsDisplaySleepDuringVideoPlayback = false
        return p
    }()

    private var lang: String?
    /// Dernier top chargé (relu après 10 min, au retour sur l'onglet).
    private var loadedAt = Date.distantPast
    private var next: String?
    private var loadingMore = false
    /// Adresses déjà trouvées (5 min) : revenir sur une page ne relance pas
    /// toutes les sources du direct.
    private var resolved: [String: (url: URL, at: Date)] = [:]
    private var resolveTask: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    /// Son des aperçus coupé (par défaut). Rallumé, il le reste d'une page à
    /// l'autre, et au retour sur l'onglet.
    @Published private(set) var muted = true
    /// Son rallumé : les aperçus tiennent la session audio (« discover »).
    private var holdsSession = false
    /// Catégorie « ambient » posée pour les aperçus muets.
    private var ambient = false

    // MARK: Lives du top
    /// Top dans la langue du top, sans les chaînes et catégories masquées.
    func loadLives(lang: String?, keep: (TwitchStream) -> Bool) async {
        self.lang = lang
        livesFailed = false
        guard let page = await getTopStreamsPageGQL(lang: lang, after: nil) else {
            livesFailed = lives.isEmpty
            livesLoaded = true
            return
        }
        lives = unique(page.streams.filter(keep))
        next = page.refused ? nil : page.next
        livesLoaded = true
        loadedAt = Date()
        // Les clips suivent les chaînes du moment : relus au besoin.
        clips = []
        clipsLoaded = false
    }

    /// Top chargé dans cette langue il y a moins de 10 min : gardé tel quel
    /// au retour sur l'onglet (page, mode, son).
    func isFresh(lang: String?) -> Bool {
        !lives.isEmpty && self.lang == lang && Date().timeIntervalSince(loadedAt) < 600
    }

    /// Chaînes et catégories masquées après le chargement (menu ⋯ d'une
    /// page, accueil…) : leurs lives et leurs clips sortent du fil, filtré
    /// jusque-là au chargement seulement. La page affichée garde sa place, ou
    /// la laisse à la suivante si c'est elle qui part.
    func removeHidden(keep: (TwitchStream) -> Bool, keepChannel: (String) -> Bool) {
        if lives.contains(where: { !keep($0) }) {
            let before = lives.prefix(liveIndex).filter(keep).count
            lives = lives.filter(keep)
            liveIndex = min(before, max(lives.count - 1, 0))
        }
        if clips.contains(where: { !keepChannel($0.login) }) {
            let before = clips.prefix(clipIndex).filter { keepChannel($0.login) }.count
            clips = clips.filter { keepChannel($0.login) }
            clipIndex = min(before, max(clips.count - 1, 0))
        }
    }

    /// Près de la fin : la page suivante du top.
    func loadMoreLives(after index: Int, keep: (TwitchStream) -> Bool) async {
        guard index >= lives.count - 5, let after = next, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let page = await getTopStreamsPageGQL(lang: lang, after: after) else { return }
        let known = Set(lives.map { $0.userLogin.lowercased() })
        lives += unique(page.streams.filter { keep($0) && !known.contains($0.userLogin.lowercased()) })
        next = page.refused ? nil : page.next
    }

    private func unique(_ list: [TwitchStream]) -> [TwitchStream] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.userLogin.lowercased()).inserted }
    }

    // MARK: Clips du moment
    /// Clips les plus vus des dernières 24 h des chaînes du top. `force` :
    /// relus même déjà chargés (Réessayer).
    func loadClips(force: Bool = false) async {
        guard force || !clipsLoaded else { return }
        let logins = lives.prefix(20).map { $0.userLogin }
        guard !logins.isEmpty else {
            // Top vide (réseau, suite refusée, tout masqué) : on le dit, avec
            // Réessayer, au lieu de tourner sans fin. Top encore en
            // chargement : les clips suivront (DiscoverView.loadTop).
            if livesLoaded {
                clipsFailed = livesFailed
                clipsLoaded = true
            }
            return
        }
        clipsFailed = false
        guard let list = await getTopClipsGQL(logins: Array(logins)) else {
            clipsFailed = true
            clipsLoaded = true
            return
        }
        clips = list
        clipsLoaded = true
    }

    // MARK: Aperçus
    /// Aperçu d'un live : ses sources habituelles, en 360p (160p en données
    /// mobiles).
    func show(live s: TwitchStream) {
        let login = s.userLogin.lowercased()
        start("live:" + login, loop: false, avatarFor: login) {
            let data = await getLive(channelName: login)
            guard let links = data.links, !links.isEmpty else { return (nil, data.avatar) }
            let pref = NetworkStatus.shared.isCellular ? "160" : "360"
            let key = preferredQualityKey(Array(links.keys), pref: pref, variants: data.variants)
            return (links[key].flatMap { URL(string: $0) }, data.avatar)
        }
    }

    /// Aperçu d'un clip, en boucle.
    func show(clip c: FeedClip) {
        start("clip:" + c.id, loop: true, avatarFor: nil) {
            guard let clip = await getClip(slug: c.id) else { return (nil, nil) }
            let key = preferredQualityKey(Array(clip.links.keys), pref: "360")
            return (clip.links[key].flatMap { URL(string: $0) }, nil)
        }
    }

    private func start(_ key: String, loop: Bool, avatarFor login: String?,
                       resolve: @escaping () async -> (URL?, String?)) {
        // Un lecteur est ouvert : rien ne repart dessous.
        guard !DiscoverGate.shared.blocked else { return }
        guard playing != key else {
            if player.timeControlStatus == .paused, player.currentItem != nil { player.play() }
            return
        }
        resolveTask?.cancel()
        playing = key
        applyAudio()
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let r = resolved[key], Date().timeIntervalSince(r.at) < 300 {
            attach(r.url, key: key, loop: loop)
            return
        }
        preview[key] = .loading
        resolveTask = Task { [weak self] in
            let (url, avatar) = await resolve()
            guard let self, !Task.isCancelled else { return }
            if let login, let avatar { self.avatars[login] = avatar }
            guard self.playing == key, !DiscoverGate.shared.blocked else { return }
            guard let url else {
                self.preview[key] = .failed
                return
            }
            self.resolved[key] = (url, Date())
            self.attach(url, key: key, loop: loop)
        }
    }

    private func attach(_ url: URL, key: String, loop: Bool) {
        guard !DiscoverGate.shared.blocked else { return }
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 2
        if let o = endObserver {
            NotificationCenter.default.removeObserver(o)
            endObserver = nil
        }
        if loop {
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.player.seek(to: .zero)
                    self?.player.play()
                }
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        preview[key] = .ready
    }

    /// Plus rien ne joue (onglet quitté, lecteur ouvert, app en arrière-plan).
    func stop() {
        resolveTask?.cancel()
        resolveTask = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        playing = nil
        // Session rendue avant qu'un lecteur ne s'ouvre (même file d'attente
        // que la sienne : l'ordre est garanti).
        if holdsSession {
            holdsSession = false
            PlaybackAudio.shared.release("discover")
        } else if ambient {
            PlaybackAudio.shared.previewAmbient(false)
        }
        ambient = false
    }

    /// Bouton du son de l'aperçu.
    func toggleSound() {
        muted.toggle()
        player.isMuted = muted
        // Rallumé : la session passe aux aperçus. Recoupé, elle leur reste
        // jusqu'à la sortie de l'onglet (la relâcher arrêterait l'aperçu).
        if !muted, playing != nil { applyAudio() }
    }

    /// Son coupé : catégorie « ambient », la musique d'une autre app
    /// continue. Rallumé : la session des lecteurs, comme pour une vidéo.
    private func applyAudio() {
        player.isMuted = muted
        if muted {
            guard !holdsSession, !ambient else { return }
            ambient = true
            PlaybackAudio.shared.previewAmbient(true)
        } else if !holdsSession {
            holdsSession = true
            ambient = false
            PlaybackAudio.shared.claim("discover")
        }
    }
}

// MARK: – Écran
struct DiscoverView: View {
    /// Onglet affiché, sans lecteur ni feuille ouverts : les aperçus peuvent jouer.
    let active: Bool
    /// Hauteur cachée en bas par la mini-barre et la barre du multi-live,
    /// qui flottent par-dessus : les pages ne défilent pas, le bas de la
    /// fiche (jeu, tags, bouton ⋯) passait dessous.
    let bottomInset: CGFloat
    let onPlayLive: (String) -> Void
    let onPlayClip: (String, String?) -> Void
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var feed = DiscoverFeed.shared
    @ObservedObject private var gate = DiscoverGate.shared

    private var canPlay: Bool { active && scenePhase == .active && !gate.blocked }
    private var lang: String { TopLanguage.resolved(store.topLang) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            GeometryReader { geo in
                if feed.mode == .live { livePages(geo.size) } else { clipPages(geo.size) }
            }
            picker.padding(.top, 10)
        }
        .clipped()
        .task(id: lang) {
            // Retour sur l'onglet : le fil reprend où on l'a laissé, moins ce
            // qui a été masqué entre-temps. Relu au premier passage, quand la
            // langue du top change, et après 10 min.
            guard feed.isFresh(lang: lang) else {
                await loadTop()
                return
            }
            feed.removeHidden(keep: store.showsStream, keepChannel: store.showsChannel)
            if feed.mode == .clips { await feed.loadClips() }
            refresh()
        }
        .onChange(of: feed.mode) { m in
            Task {
                if m == .clips { await feed.loadClips() }
                refresh()
            }
        }
        .onChange(of: feed.liveIndex) { i in
            refresh()
            Task { await feed.loadMoreLives(after: i, keep: store.showsStream) }
        }
        .onChange(of: feed.clipIndex) { _ in refresh() }
        .onChange(of: canPlay) { _ in refresh() }
        // Onglet touché à nouveau dans la barre : retour à la première page
        // du mode affiché.
        .onReceive(NotificationCenter.default.publisher(for: .tuTabReselected)) { note in
            guard (note.object as? MainTabView.TabName) == .discover else { return }
            withAnimation {
                if feed.mode == .live { feed.liveIndex = 0 } else { feed.clipIndex = 0 }
            }
        }
        // Chaîne ou catégorie masquée (menu ⋯ d'une page) : elle quitte le
        // fil tout de suite, la page suivante prend sa place.
        .onChange(of: store.hidden) { _ in
            feed.removeHidden(keep: store.showsStream, keepChannel: store.showsChannel)
            refresh()
            Task { await feed.loadMoreLives(after: feed.liveIndex, keep: store.showsStream) }
        }
        .onAppear {
            feed.screens += 1
            refresh()
        }
        .onDisappear {
            feed.screens = max(0, feed.screens - 1)
            feed.stop()
        }
    }

    /// Top relu depuis sa première page, puis les clips si c'est leur mode.
    private func loadTop() async {
        feed.stop()
        await feed.loadLives(lang: lang, keep: store.showsStream)
        feed.liveIndex = 0
        feed.clipIndex = 0
        if feed.mode == .clips { await feed.loadClips(force: true) }
        refresh()
    }

    /// L'aperçu de la page affichée, ou rien si le fil n'est pas à l'écran
    /// (onglet quitté pendant un chargement compris : le fil lui survit).
    private func refresh() {
        guard canPlay, feed.screens > 0 else { feed.stop(); return }
        switch feed.mode {
        case .live:
            if feed.lives.indices.contains(feed.liveIndex) { feed.show(live: feed.lives[feed.liveIndex]) } else { feed.stop() }
        case .clips:
            if feed.clips.indices.contains(feed.clipIndex) { feed.show(clip: feed.clips[feed.clipIndex]) } else { feed.stop() }
        }
    }

    // MARK: Pages
    @ViewBuilder
    private func livePages(_ size: CGSize) -> some View {
        if feed.lives.isEmpty {
            status(loaded: feed.livesLoaded, failed: feed.livesFailed) {
                Task { await loadTop() }
            }
        } else {
            VerticalPager(count: feed.lives.count, index: $feed.liveIndex, size: size) { i in
                DiscoverLivePage(stream: feed.lives[i], isCurrent: i == feed.liveIndex, bottomInset: bottomInset,
                                 feed: feed, onOpen: {
                    let login = feed.lives[i].userLogin
                    feed.stop()
                    onPlayLive(login)
                }, onChannel: { openChannel(feed.lives[i].userLogin) })
            }
        }
    }

    @ViewBuilder
    private func clipPages(_ size: CGSize) -> some View {
        if feed.clips.isEmpty {
            status(loaded: feed.clipsLoaded, failed: feed.clipsFailed) {
                Task {
                    // Top vide (réseau, tout masqué) : relu d'abord, les clips
                    // viennent de ses chaînes (loadTop les charge ensuite).
                    if feed.lives.isEmpty {
                        await loadTop()
                    } else {
                        await feed.loadClips(force: true)
                        refresh()
                    }
                }
            }
        } else {
            VerticalPager(count: feed.clips.count, index: $feed.clipIndex, size: size) { i in
                DiscoverClipPage(clip: feed.clips[i], isCurrent: i == feed.clipIndex, bottomInset: bottomInset,
                                 feed: feed, onOpen: {
                    let c = feed.clips[i]
                    feed.stop()
                    onPlayClip(c.id, c.title)
                }, onChannel: { openChannel(feed.clips[i].login) })
            }
        }
    }

    /// Page de la chaîne, dans la feuille de MainTabView (store.pendingChannel).
    private func openChannel(_ login: String) {
        feed.stop()
        store.pendingChannel = login.lowercased()
    }

    /// Chargement, échec (avec Réessayer) ou fil vide.
    private func status(loaded: Bool, failed: Bool, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 14) {
            if !loaded {
                ProgressView().tint(.white)
            } else {
                Text(store.t(failed ? "err_network" : "discover_empty"))
                    .font(.system(size: 15)).foregroundColor(.tMuted)
                    .multilineTextAlignment(.center)
                Button(store.t("retry"), action: retry)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.tPrimary)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var picker: some View {
        HStack(spacing: 4) {
            pickerButton(.live, store.t("discover_live"))
            pickerButton(.clips, store.t("discover_clips"))
        }
        .padding(4)
        .background(Color.black.opacity(0.45))
        .clipShape(Capsule())
    }

    private func pickerButton(_ m: DiscoverFeed.Mode, _ title: String) -> some View {
        Button {
            guard feed.mode != m else { return }
            feed.stop()
            feed.mode = m
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(feed.mode == m ? .black : .white)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(feed.mode == m ? Color.white : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: – Défilement vertical par page
/// Une page par écran, qu'on fait défiler vers le haut : un TabView en pages
/// tourné d'un quart de tour (iOS 16 n'a pas de défilement par page
/// vertical), ses pages tournées en sens inverse.
private struct VerticalPager<Page: View>: View {
    let count: Int
    @Binding var index: Int
    let size: CGSize
    @ViewBuilder let page: (Int) -> Page

    var body: some View {
        TabView(selection: $index) {
            ForEach(0..<count, id: \.self) { i in
                page(i)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .rotationEffect(.degrees(-90))
                    .frame(width: size.height, height: size.width)
                    .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(width: size.height, height: size.width)
        .rotationEffect(.degrees(90), anchor: .topLeading)
        .offset(x: size.width)
    }
}

// MARK: – Page d'un live
private struct DiscoverLivePage: View {
    let stream: TwitchStream
    let isCurrent: Bool
    /// Marge des barres flottantes (voir DiscoverView.bottomInset).
    let bottomInset: CGFloat
    @ObservedObject var feed: DiscoverFeed
    let onOpen: () -> Void
    /// Page de la chaîne (nom ou photo touchés).
    let onChannel: () -> Void
    @EnvironmentObject private var store: AppStore

    private var login: String { stream.userLogin.lowercased() }
    private var key: String { "live:" + login }
    private var thumb: String {
        stream.thumbnailURL
            .replacingOccurrences(of: "{width}", with: "640")
            .replacingOccurrences(of: "{height}", with: "360")
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            DiscoverBackdrop(url: thumb)
            VStack(spacing: 0) {
                Spacer(minLength: 60)
                DiscoverScreen(thumb: thumb, isCurrent: isCurrent, key: key, feed: feed)
                    .onTapGesture(perform: onOpen)
                Spacer(minLength: 0)
                Spacer(minLength: 0)
            }
            HStack(alignment: .bottom, spacing: 12) {
                info
                Spacer(minLength: 0)
                DiscoverSideBar(login: login, name: stream.userName, avatar: feed.avatars[login],
                                viewers: stream.viewerCount, gameId: stream.gameId, gameName: stream.gameName,
                                link: "https://www.twitch.tv/\(login)", onChannel: onChannel)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 18 + bottomInset)
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(store.t("live_badge"))
                    .font(.system(size: 11, weight: .heavy)).foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.tLive).cornerRadius(4)
                Text("● " + formatViewers(stream.viewerCount))
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.85))
            }
            HStack(spacing: 10) {
                Button(action: onChannel) {
                    Text(stream.userName)
                        .font(.system(size: 19, weight: .bold)).foregroundColor(.white).lineLimit(1)
                }
                .buttonStyle(.plain)
                DiscoverFollowButton(login: login, name: stream.userName, channelId: stream.id)
            }
            if !stream.title.isEmpty {
                Text(stream.title)
                    .font(.system(size: 14)).foregroundColor(.white.opacity(0.9)).lineLimit(2)
            }
            let tags = stream.tags.prefix(3)
            if !tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(tags), id: \.self) { t in
                        Text(t)
                            .font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.white.opacity(0.16)).clipShape(Capsule())
                            .lineLimit(1)
                    }
                }
            }
            if !stream.gameName.isEmpty {
                Label(stream.gameName, systemImage: "gamecontroller")
                    .font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.8)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: – Page d'un clip
private struct DiscoverClipPage: View {
    let clip: FeedClip
    let isCurrent: Bool
    /// Marge des barres flottantes (voir DiscoverView.bottomInset).
    let bottomInset: CGFloat
    @ObservedObject var feed: DiscoverFeed
    let onOpen: () -> Void
    /// Page de la chaîne (nom ou photo touchés).
    let onChannel: () -> Void
    @EnvironmentObject private var store: AppStore

    private var key: String { "clip:" + clip.id }
    /// « 0:27 » : un clip dure moins d'une minute, compté en minutes il
    /// affichait presque toujours « 0min » (comme ClipCardView).
    private var durationText: String {
        let s = max(0, clip.durationSeconds)
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            DiscoverBackdrop(url: clip.thumbnailURL)
            VStack(spacing: 0) {
                Spacer(minLength: 60)
                DiscoverScreen(thumb: clip.thumbnailURL, isCurrent: isCurrent, key: key, feed: feed)
                    .onTapGesture(perform: onOpen)
                Spacer(minLength: 0)
                Spacer(minLength: 0)
            }
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("▶ " + formatViewers(clip.viewCount) + " · " + durationText)
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.85))
                    HStack(spacing: 10) {
                        Button(action: onChannel) {
                            Text(clip.channelName)
                                .font(.system(size: 19, weight: .bold)).foregroundColor(.white).lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        DiscoverFollowButton(login: clip.login.lowercased(), name: clip.channelName,
                                             channelId: clip.channelId)
                    }
                    if !clip.title.isEmpty {
                        Text(clip.title)
                            .font(.system(size: 14)).foregroundColor(.white.opacity(0.9)).lineLimit(2)
                    }
                    if !clip.game.isEmpty {
                        Label(clip.game, systemImage: "gamecontroller")
                            .font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.8)).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                DiscoverSideBar(login: clip.login.lowercased(), name: clip.channelName, avatar: clip.avatar,
                                viewers: nil, gameId: "", gameName: "",
                                link: "https://clips.twitch.tv/\(clip.id)", onChannel: onChannel)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 18 + bottomInset)
        }
    }
}

// MARK: – Éléments communs
/// Fond de page : la miniature, floutée et assombrie. L'image « remplir »
/// est dans un calque : seule, elle prenait sa propre taille (bien plus
/// large que l'écran), la page s'élargissait d'autant, la vidéo devenait
/// géante et les infos partaient hors de l'écran.
private struct DiscoverBackdrop: View {
    let url: String

    var body: some View {
        Color.black
            .overlay(
                AsyncImage(url: URL(string: url)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.black
                }
                .blur(radius: 30)
            )
            .overlay(Color.black.opacity(0.55))
            .overlay(
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
            )
            .clipped()
    }
}

/// L'image en 16:9 : la miniature, et l'aperçu par-dessus sur la page affichée.
private struct DiscoverScreen: View {
    let thumb: String
    let isCurrent: Bool
    let key: String
    @ObservedObject var feed: DiscoverFeed
    @EnvironmentObject private var store: AppStore

    var body: some View {
        // Boîte 16:9 de la largeur de la page ; la miniature et la vidéo sont
        // des calques, qui ne changent pas sa taille.
        Color.white.opacity(0.06)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(
                AsyncImage(url: URL(string: thumb)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            )
            .overlay {
                if isCurrent, feed.playing == key {
                    DiscoverVideoLayer(player: feed.player)
                }
            }
            .overlay {
                if isCurrent, feed.preview[key] == .loading {
                    ProgressView().tint(.white)
                } else if feed.preview[key] == .failed {
                    Text(store.t("discover_no_preview"))
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.black.opacity(0.6)).clipShape(Capsule())
                }
            }
            // Son de l'aperçu (coupé au départ), d'un toucher.
            .overlay(alignment: .bottomTrailing) {
                Button {
                    feed.toggleSound()
                } label: {
                    Image(systemName: feed.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.black.opacity(0.55)).clipShape(Circle())
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.t(feed.muted ? "discover_unmute" : "discover_mute"))
            }
            .clipped()
        .contentShape(Rectangle())
        .accessibilityLabel(store.t("discover_tap"))
        .accessibilityAddTraits(.isButton)
    }
}

/// Colonne de droite : photo de la chaîne, spectateurs, partager, masquer.
private struct DiscoverSideBar: View {
    let login: String
    let name: String
    let avatar: String?
    let viewers: Int?
    let gameId: String
    let gameName: String
    let link: String
    /// Page de la chaîne (photo touchée).
    let onChannel: () -> Void
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Button(action: onChannel) {
                    AsyncImage(url: URL(string: avatar ?? "")) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        Circle().fill(Color.white.opacity(0.12))
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1))
                }
                .buttonStyle(.plain)
                if let viewers {
                    HStack(spacing: 3) {
                        Circle().fill(Color.tLive).frame(width: 7, height: 7)
                        Text(formatViewers(viewers))
                            .font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                    }
                }
            }
            if let url = URL(string: link) {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 20, weight: .semibold)).foregroundColor(.white)
                        .frame(width: 44, height: 44)
                }
            }
            // Rien pour une chaîne suivie ou épinglée, ni pour une catégorie
            // suivie (comme HideMenuButtons) : jamais masquées, AppStore
            // refusait sans un mot ce que le menu proposait.
            let channelHideable = !store.isFollowedOrPinned(login)
            let categoryHideable = !gameId.isEmpty && !gameName.isEmpty && !store.followsCategory(gameId)
            if channelHideable || categoryHideable {
                Menu {
                    if channelHideable {
                        Button(role: .destructive) {
                            store.hideChannel(login: login, name: name)
                        } label: {
                            Label(store.t("hide_channel"), systemImage: "eye.slash")
                        }
                    }
                    if categoryHideable {
                        Button(role: .destructive) {
                            store.hideCategory(id: gameId, name: gameName, box: "")
                        } label: {
                            Label(store.t("hide_category").replacingOccurrences(of: "{c}", with: gameName),
                                  systemImage: "eye.slash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 20, weight: .bold)).foregroundColor(.white)
                        .frame(width: 44, height: 44)
                }
            }
        }
    }
}

/// Suivre la chaîne : sur Twitch avec la session web, sinon sur l'appareil
/// (comme la page de chaîne). Ne plus suivre se confirme.
private struct DiscoverFollowButton: View {
    let login: String
    /// Nom affiché (titre de la confirmation), le pseudo à défaut.
    let name: String
    let channelId: String
    @EnvironmentObject private var store: AppStore
    @StateObject private var follow = FollowService()
    @State private var confirm = false

    var body: some View {
        Group {
            if let on = follow.isFollowing {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if on {
                        confirm = true
                        return
                    }
                    Task { @MainActor in
                        await follow.toggle(token: store.twitchWebToken)
                        if follow.isFollowing == true { store.unhideChannel(login) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: on ? "heart.fill" : "heart")
                        Text(store.t(on ? "following" : "follow"))
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(on ? .tDanger : .white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.white.opacity(0.16))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(follow.busy)
                .confirmationDialog(
                    store.t("unfollow_confirm").replacingOccurrences(of: "{c}", with: name.isEmpty ? login : name),
                    isPresented: $confirm, titleVisibility: .visible
                ) {
                    Button(store.t("unfollow"), role: .destructive) {
                        Task { @MainActor in await follow.unfollow(token: store.twitchWebToken) }
                    }
                    Button(store.t("cancel"), role: .cancel) {}
                }
            }
        }
        .task(id: login) {
            if let web = store.twitchWebToken, !channelId.isEmpty {
                await follow.load(login: login, channelId: channelId, token: web)
            } else {
                follow.loadLocal(login: login, store: store)
            }
        }
    }
}

/// Image de l'aperçu : transparente tant qu'aucune image n'est arrivée (la
/// miniature reste visible dessous), et sans réaction au toucher (la page
/// s'ouvre d'un toucher).
private final class DiscoverLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct DiscoverVideoLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> DiscoverLayerUIView {
        let v = DiscoverLayerUIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.player = player
        return v
    }

    func updateUIView(_ uiView: DiscoverLayerUIView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }
}
