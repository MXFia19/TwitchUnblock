import AVFoundation
import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Multi-live : jusqu'à quatre vidéos côte à côte, directs et VODs mêlés.
//
//  MultiLive garde la sélection (sur l'appareil) ; MultiLiveSession tient un
//  lecteur par vidéo le temps de la mosaïque — hors des vues, pour qu'une
//  rotation (côte à côte ↔ les uns sous les autres) ne relance rien. Le son
//  ne vient que d'une vidéo à la fois.
// ═══════════════════════════════════════════════════════════════════════════

struct MultiLiveEntry: Codable, Equatable, Identifiable {
    /// Direct : la chaîne. VOD : sa chaîne si on la connaît, sinon vide
    /// (complétée au démarrage de la tuile).
    var login: String
    /// Nom affiché de la chaîne (vide pour une VOD ajoutée par lien ou ID,
    /// tant que sa tuile n'a pas démarré).
    var name: String
    /// VOD : son identifiant, son titre et sa vignette. Optionnels : une liste
    /// enregistrée par une version d'avant se relit telle quelle.
    var vodId: String? = nil
    var title: String? = nil
    var thumb: String? = nil

    var isVod: Bool { vodId != nil }
    /// Une VOD n'est jamais confondue avec le direct de sa chaîne.
    var id: String { vodId.map { "vod:\($0)" } ?? login }
    /// Nom à afficher seul (barre du bas de l'app, tuile).
    var displayName: String {
        if let vodId, name.isEmpty { return vodId }
        return name
    }
    /// « VOD · nom » pour une VOD, le nom pour un direct.
    var label: String { isVod ? "VOD · \(displayName)" : displayName }
}

@MainActor
final class MultiLive: ObservableObject {
    static let shared = MultiLive()
    static let max = 4

    @Published private(set) var entries: [MultiLiveEntry] = []
    private let key = "multi_live"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([MultiLiveEntry].self, from: data) {
            entries = Array(list.prefix(Self.max))
        }
    }

    /// Plein : quatre vidéos en tout, directs et VODs confondus.
    var isFull: Bool { entries.count >= Self.max }
    /// Ce direct est-il choisi ? (Une VOD de la même chaîne ne compte pas.)
    func contains(_ login: String) -> Bool { entries.contains { !$0.isVod && $0.login == login.lowercased() } }
    func containsVod(_ id: String) -> Bool { entries.contains { $0.vodId == id } }

    /// Ajoute un direct (false si la liste est pleine) ; déjà là, rien ne change.
    @discardableResult
    func add(_ login: String, name: String) -> Bool {
        let l = login.trimmingCharacters(in: .whitespaces).lowercased()
        guard !l.isEmpty else { return false }
        if contains(l) { return true }
        guard !isFull else { return false }
        entries.append(MultiLiveEntry(login: l, name: name.isEmpty ? l : name))
        save()
        return true
    }

    /// Ajoute un direct, ou le retire s'il y est déjà. false si la liste est pleine.
    @discardableResult
    func toggle(_ login: String, name: String) -> Bool {
        if contains(login) { remove(login); return true }
        return add(login, name: name)
    }

    /// Retire un direct (jamais une VOD de la même chaîne).
    func remove(_ login: String) {
        entries.removeAll { !$0.isVod && $0.login == login.lowercased() }
        save()
    }

    /// Ajoute une VOD (false si la liste est pleine ou l'identifiant invalide).
    /// `login` : la chaîne si on la connaît ; sinon la tuile la complète.
    @discardableResult
    func addVod(id: String, name: String, title: String? = nil, thumb: String? = nil,
                login: String = "") -> Bool {
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return false }
        if containsVod(id) { return true }
        guard !isFull else { return false }
        entries.append(MultiLiveEntry(login: login.lowercased(), name: name, vodId: id,
                                      title: title, thumb: thumb))
        save()
        return true
    }

    /// Ajoute une VOD, ou la retire si elle y est déjà. false si la liste est pleine.
    @discardableResult
    func toggleVod(id: String, name: String, title: String? = nil, thumb: String? = nil,
                   login: String = "") -> Bool {
        if containsVod(id) { remove(id: "vod:\(id)"); return true }
        return addVod(id: id, name: name, title: title, thumb: thumb, login: login)
    }

    /// Retire une entrée par son identifiant (`MultiLiveEntry.id`).
    func remove(id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    /// Échange deux vidéos de place (la première est la grande, à trois) ;
    /// les lectures continuent, seule la disposition change.
    func swap(_ a: String, _ b: String) {
        guard let i = entries.firstIndex(where: { $0.id == a }),
              let j = entries.firstIndex(where: { $0.id == b }), i != j else { return }
        entries.swapAt(i, j)
        save()
    }

    /// Ce que la tuile a appris de la VOD à son démarrage (chaîne, titre…) ;
    /// une valeur vide ne remplace rien.
    func updateVod(id: String, login: String, name: String, title: String, thumb: String) {
        guard let i = entries.firstIndex(where: { $0.vodId == id }) else { return }
        var e = entries[i]
        if !login.isEmpty { e.login = login.lowercased() }
        if !name.isEmpty { e.name = name }
        if !title.isEmpty { e.title = title }
        if !thumb.isEmpty { e.thumb = thumb }
        guard e != entries[i] else { return }
        entries[i] = e
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Une qualité qui tient à plusieurs : 1080p seul, 720p à deux, 480p
    /// au-delà — ou la qualité préférée si elle est plus basse (plafond).
    /// La plus haute à cette hauteur ou en dessous, sinon la plus basse.
    nonisolated static func pick(_ links: QualityLinks, count: Int,
                                 variants: [String: VariantInfo] = [:]) -> URL? {
        let rule = count <= 1 ? 1080 : count == 2 ? 720 : 480
        let ud = UserDefaults.standard
        let pref = ud.string(forKey: "cfg_quality_pref") ?? "source"
        var want = Int(pref).map { min($0, rule) } ?? rule
        // En données mobiles, la qualité choisie pour elles, comme le lecteur
        // (launchQualityKey) : une tuile seule partait en 1080p60 sur le
        // forfait. « Auto » : 720p au plus (une liste adaptative ne connaît
        // pas le palier de la mosaïque) ; « Audio seul » : la vidéo la plus
        // basse, une tuile ayant besoin d'image.
        if NetworkStatus.shared.isCellular {
            switch ud.string(forKey: "cfg_quality_cellular") ?? "auto" {
            case "same":  break
            case "auto":  want = min(want, 720)
            case "audio": want = 160
            case let cell: want = min(Int(cell) ?? want, rule)
            }
        }
        let video = links.keys.filter { !isAudioQuality($0) }
        let key: String? = video.isEmpty ? links.keys.first
            : preferredQualityKey(video, pref: String(want), variants: variants)
        return key.flatMap { links[$0] }.flatMap { URL(string: $0) }
    }

    /// Reprise d'une VOD : la progression enregistrée, sauf sous 10 s ou à
    /// moins de 30 s de la fin (même règle que le site) — alors le début.
    nonisolated static func startPoint(saved: Double, length: Double) -> Double {
        guard saved >= 10 else { return 0 }
        if length > 0, saved > length - 30 { return 0 }
        return saved
    }
}

// MARK: – Une vidéo de la mosaïque
@MainActor
final class MultiTileModel: ObservableObject {
    enum Phase { case loading, playing, offline, failed, ended }

    /// Direct : la chaîne. VOD : sa chaîne, apprise au démarrage si besoin.
    @Published private(set) var login: String
    /// VOD lue par la tuile ; nil pour un direct.
    let vodId: String?
    var isVod: Bool { vodId != nil }
    let player = AVPlayer()
    /// Pause pub à l'écran (bandeau de la tuile), son coupé le temps qu'elle
    /// dure — seule la tuile qui a le son en a un à couper.
    let adBreaks = AdBreakWatcher()
    @Published private(set) var phase: Phase = .loading { didSet { onPlayState() } }
    /// En lecture mais à l'arrêt faute de données (roue légère sur la tuile).
    @Published private(set) var buffering = false
    /// Identifiant Twitch de la chaîne (emotes et badges de son chat).
    @Published private(set) var channelId: String?
    /// VOD : position et durée, arrondies à la seconde (barre de la tuile,
    /// chat rejoué). La durée d'une VOD en cours est la fin de la fenêtre.
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    /// VOD mise en pause à la main : rien ne la relance seul.
    @Published private(set) var userPaused = false { didSet { onPlayState() } }
    /// Lecteur à l'arrêt, d'après AVPlayer : redessine la tuile (voir
    /// `heldBySystem`).
    @Published private var playerPaused = false { didSet { onPlayState() } }
    /// Lecture qui part ou s'arrête (phase, pauses) : la mosaïque revoit si
    /// l'écran doit rester allumé (MultiLiveSession.keepsScreenOn).
    var onPlayState: @MainActor () -> Void = {}

    /// L'écran reste allumé pour elle : en lecture, ou en route. Pas en pause
    /// (voulue ou d'iOS), hors ligne, en échec ou finie.
    var keepsScreenOn: Bool {
        switch phase {
        case .loading:                  return !userPaused
        case .playing:                  return !userPaused && !playerPaused
        case .offline, .failed, .ended: return false
        }
    }

    /// Arrêtée sans qu'on l'ait voulu — appel, Siri, son d'une autre app
    /// qu'on ne coupe pas sans un geste, fin du flux : la tuile montre
    /// « Lecture », seule commande d'un direct. L'état réel du lecteur est
    /// relu : une relance (play) l'efface sans attendre l'observateur.
    var heldBySystem: Bool {
        phase == .playing && !userPaused && playerPaused && player.timeControlStatus == .paused
    }

    private var task: Task<Void, Never>?
    /// Chargement sans image depuis 20 s : relance (voir observe).
    private var loadWatch: Task<Void, Never>?
    private var failObserver: NSObjectProtocol?
    private var observers: [NSKeyValueObservation] = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var count = 2
    /// Relances après une coupure, remises à zéro dès que l'image revient.
    private var restarts = 0
    /// Élément dont la coupure est déjà traitée (voir `interrupted`).
    private weak var failedItem: AVPlayerItem?
    /// Session web à donner à getLive (abonné sans pub, voir AppStore).
    private let accountToken: (String) -> String?
    /// Progression des VODs (AppStore) : reprise, enregistrement, et premier
    /// démarrage réussi (historique).
    private let resume: (String) -> Double
    private let save: (String, Double) -> Void
    private let onStarted: @MainActor (String, VodMeta?) -> Void
    /// Position de départ, appliquée quand l'élément est prêt.
    private var pendingSeek: Double?
    /// Recherche en cours : la position affichée est déjà la cible.
    private var seekGeneration = 0
    private var seeking = false
    /// Position de départ appliquée une fois : avant, enregistrer écraserait
    /// la progression par 0.
    private var canSave = false
    private var lastSave = Date.distantPast
    /// Historique et statistiques : une fois par tuile, jamais à chaque relance.
    private var started = false
    private var counted = false

    init(entry: MultiLiveEntry,
         accountToken: @escaping (String) -> String? = { _ in nil },
         resume: @escaping (String) -> Double = { _ in 0 },
         save: @escaping (String, Double) -> Void = { _, _ in },
         onStarted: @escaping @MainActor (String, VodMeta?) -> Void = { _, _ in }) {
        self.login = entry.login
        self.vodId = entry.vodId
        self.accountToken = accountToken
        self.resume = resume
        self.save = save
        self.onStarted = onStarted
        player.isMuted = true
        adBreaks.attach(player)
    }

    func start(count: Int) {
        self.count = count
        task?.cancel()
        stopMedia()
        phase = .loading
        if let vodId { startVod(vodId, count: count); return }
        let login = self.login
        let web = accountToken(login)
        task = Task { [weak self] in
            let data = await getLive(channelName: login, webToken: web,
                                     integrity: web.map { dropsIntegrity(for: $0) })
            guard let self, !Task.isCancelled else { return }
            if let id = data.userId { self.channelId = id }
            guard let links = data.links, !links.isEmpty,
                  let url = MultiLive.pick(links, count: count, variants: data.variants) else {
                // Hors ligne ou chaîne inexistante ; une panne (réseau,
                // aucune source) n'est pas « hors ligne ».
                let gone = data.error == "offline" || data.error == "not_found"
                self.phase = gone ? .offline : .failed
                return
            }
            // Même fabrique que les autres lecteurs : audio spatial, pauses pub.
            let item = VodUnmuteLoader.playerItem(url: url)
            self.observe(item)
            self.player.replaceCurrentItem(with: item)
            self.player.play()
        }
    }

    /// VOD : la playlist telle que Twitch la donne, sans l'enveloppe des
    /// passages coupés — elle couperait le son des VODs en MP4 et figerait
    /// une VOD en cours d'enregistrement (son cache).
    private func startVod(_ id: String, count: Int) {
        task = Task { [weak self] in
            async let metaTask = getVodMetaGQL(id)
            let data = await getM3U8(vodId: id)
            let meta = await metaTask
            guard let self, !Task.isCancelled else { return }
            // Santé des lectures (/stats) : une fois par tuile, sans la VOD.
            if !self.counted {
                self.counted = true
                UsageService.shared.count(data.links.isEmpty ? "vod_fail" : "vod")
            }
            if let meta, !meta.login.isEmpty { self.login = meta.login }
            guard !data.links.isEmpty,
                  let url = MultiLive.pick(data.links, count: count, variants: data.variants) else {
                self.phase = .failed
                return
            }
            if !self.started {
                self.started = true
                self.onStarted(id, meta)
            }
            // Relance (coupure, retour) : là où on en était ; sinon la reprise.
            let from = self.canSave ? self.position
                : MultiLive.startPoint(saved: self.resume(id), length: Double(meta?.lengthSeconds ?? 0))
            // Cherché même vers 0 : une VOD en cours démarrerait au bord.
            self.pendingSeek = from
            self.position = from.rounded()
            let item = VodUnmuteLoader.playerItem(url: url)
            item.preferredForwardBufferDuration = 15
            self.observe(item)
            self.observeTime(item)
            self.player.replaceCurrentItem(with: item)
            // Coupée pendant une pause voulue : elle reste en pause, à l'image.
            if self.userPaused { self.phase = .playing } else { self.player.play() }
        }
    }

    /// « Réessayer » (ou direct relancé au retour) : la lecture repart.
    func retry() {
        restarts = 0
        userPaused = false
        start(count: count)
    }

    func stop() {
        saveProgress()
        task?.cancel()
        task = nil
        stopMedia()
        adBreaks.detach()
    }

    private func stopMedia() {
        observers = []
        if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        if let o = failObserver { NotificationCenter.default.removeObserver(o); failObserver = nil }
        loadWatch?.cancel(); loadWatch = nil
        buffering = false
        pendingSeek = nil
        seeking = false
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func observe(_ item: AVPlayerItem) {
        observers = [
            item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                switch item.status {
                case .readyToPlay: Task { @MainActor in self?.applyPendingSeek(on: item) }
                case .failed:      Task { @MainActor in self?.interrupted(item) }
                default:           break
                }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                let nowPlaying = player.timeControlStatus == .playing
                Task { @MainActor in self?.statusChanged(playing: nowPlaying) }
            },
        ]
        // Lecture arrêtée en route (réseau, segment refusé) : relance.
        if let o = failObserver { NotificationCenter.default.removeObserver(o) }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            let failed = note.object as? AVPlayerItem
            Task { @MainActor in self?.interrupted(failed) }
        }
        // Chargement sans fin (proxy qui accepte sans rien livrer) : au bout de
        // 20 s sans image, la tuile relance, puis propose « Réessayer ».
        loadWatch?.cancel()
        loadWatch = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, !Task.isCancelled, self.phase == .loading, !self.userPaused,
                  self.player.currentItem === item else { return }
            logger.warn("MULTI", "Tuile sans image depuis 20 s : relance", self.login)
            self.interrupted(item)
        }
    }

    /// Lecture partie, ou lecteur arrêté (voir `heldBySystem`).
    private func statusChanged(playing nowPlaying: Bool) {
        if nowPlaying { playing() }
        let paused = player.timeControlStatus == .paused
        if paused != playerPaused { playerPaused = paused }
        let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if waiting != buffering { buffering = waiting }
    }

    /// Nombre de tuiles changé : nouvelle qualité si le palier change (1080p
    /// seul, 720p à deux, 480p au-delà). Un direct gardait sa qualité de
    /// départ : 1080p à côté de trois 480p, ou 480p étiré une fois seul.
    func adjust(count newCount: Int) {
        let tier = { (n: Int) in n <= 1 ? 1080 : n == 2 ? 720 : 480 }
        let changed = tier(newCount) != tier(count)
        count = newCount
        guard changed, phase == .playing || phase == .loading else { return }
        start(count: newCount)
    }

    /// VOD : position et durée chaque seconde, fin de la vidéo (pour cet
    /// élément seulement : les quatre tuiles reçoivent la notification).
    private func observeTime(_ item: AVPlayerItem) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reachedEnd() }
        }
    }

    private func playing() {
        if phase != .ended { phase = .playing }
        restarts = 0
    }

    private func applyPendingSeek(on item: AVPlayerItem) {
        guard let target = pendingSeek, player.currentItem === item else { return }
        pendingSeek = nil
        jump(to: bounded(target, in: item))
        canSave = true
        lastSave = Date()
        // Mise en pause pendant le départ : la lecture ne démarrera pas, la
        // roue de chargement ne doit pas rester.
        if userPaused, phase == .loading { phase = .playing }
    }

    /// Dans la fenêtre cherchable (une VOD en cours n'a pas de durée finie).
    private func bounded(_ t: Double, in item: AVPlayerItem) -> Double {
        guard let range = item.seekableTimeRanges.last?.timeRangeValue,
              range.duration.seconds > 0 else { return max(0, t) }
        return max(range.start.seconds, min((range.start + range.duration).seconds, t))
    }

    private func jump(to t: Double) {
        seekGeneration += 1
        let gen = seekGeneration
        seeking = true
        position = t.rounded()
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.seekGeneration == gen else { return }
                self.seeking = false
            }
        }
    }

    private func tick() {
        guard let item = player.currentItem, pendingSeek == nil, !seeking else { return }
        let d = item.duration.seconds
        var end = d.isFinite && d > 0 ? d : 0
        if end == 0, let range = item.seekableTimeRanges.last?.timeRangeValue {
            let e = (range.start + range.duration).seconds
            if e.isFinite { end = e }
        }
        let t = player.currentTime().seconds
        guard t.isFinite else { return }
        let p = max(0, t).rounded(), e = end.rounded()
        if p != position { position = p }
        if e != duration { duration = e }
        if canSave, Date().timeIntervalSince(lastSave) >= 30 { saveProgress() }
    }

    /// Position à enregistrer : celle du lecteur, ou la dernière connue tant
    /// que le départ ou une recherche ne sont pas appliqués.
    private var currentSeconds: Double {
        let t = player.currentTime().seconds
        guard player.currentItem != nil, pendingSeek == nil, !seeking, t.isFinite else { return position }
        return max(0, t)
    }

    /// Enregistre la position de la VOD (pause, saut, arrêt, arrière-plan,
    /// toutes les 30 s pendant la lecture).
    func saveProgress() {
        guard let vodId, canSave else { return }
        save(vodId, currentSeconds)
        lastSave = Date()
    }

    private func reachedEnd() {
        guard isVod else { return }
        if duration > 0 { position = duration }
        phase = .ended
        saveProgress()
    }

    // MARK: Commandes (VOD)
    func togglePlay() {
        guard isVod, player.currentItem != nil else { return }
        if phase == .ended { replay(); return }
        if userPaused || player.timeControlStatus == .paused {
            userPaused = false
            player.play()
        } else {
            userPaused = true
            player.pause()
            // Départ déjà appliqué : l'image est là, plus de roue.
            if phase == .loading, pendingSeek == nil,
               player.currentItem?.status == .readyToPlay { phase = .playing }
            saveProgress()
        }
    }

    /// « Ouvrir en grand » : la position à donner au lecteur, nil tant que le
    /// départ n'est pas appliqué (la progression enregistrée reste alors). Une
    /// VOD finie repart du début. La mosaïque se ferme : la tuile n'enregistre
    /// plus rien, son arrêt écraserait ce choix.
    func handOff() -> Double? {
        guard isVod, canSave else { return nil }
        let at = phase == .ended ? 0 : currentSeconds
        canSave = false
        return at
    }

    func seek(by delta: Double) {
        seek(to: position + delta)
    }

    func seek(to t: Double) {
        guard isVod, let item = player.currentItem, pendingSeek == nil else { return }
        var target = max(0, t)
        if duration > 0 { target = min(target, duration) }
        jump(to: bounded(target, in: item))
        if phase == .ended {
            // Revenu en arrière depuis la fin : la lecture reprend.
            phase = .playing
            userPaused = false
            player.play()
        }
        saveProgress()
    }

    /// « Revoir » : depuis le début.
    func replay() {
        guard isVod, player.currentItem != nil, pendingSeek == nil else { return }
        phase = .playing
        userPaused = false
        jump(to: 0)
        player.play()
        saveProgress()
    }

    /// Retour au premier plan, fin d'une interruption ou « Lecture » : iOS a
    /// mis le lecteur en pause. Une VOD reprend (sauf pause voulue ou fin), un
    /// direct est relancé au bord.
    func resumeIfStopped() {
        guard phase == .playing, player.timeControlStatus == .paused else { return }
        if isVod {
            if !userPaused { player.play() }
        } else {
            retry()
        }
    }

    /// Coupure : on redemande les liens, trois fois au plus (une VOD repart
    /// de sa position). Une seule fois par élément : un échec en route
    /// arrive à la fois par le statut et par la notification, et comptait
    /// deux relances (une ou deux au lieu de trois).
    private func interrupted(_ item: AVPlayerItem?) {
        if let item {
            guard failedItem !== item else { return }
            failedItem = item
        }
        restarts += 1
        guard restarts <= 3 else { phase = .failed; return }
        phase = .loading
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.start(count: self.count)
        }
    }
}

// MARK: – Les lecteurs de la mosaïque
@MainActor
final class MultiLiveSession: ObservableObject {
    /// Un lecteur par entrée, indexé par `MultiLiveEntry.id`.
    @Published private(set) var tiles: [String: MultiTileModel] = [:]
    /// Entrée (`MultiLiveEntry.id`) qui a le son.
    @Published var audible: String? { didSet { applyAudio() } }
    /// Au moins une tuile en lecture (ou en route) : l'écran reste allumé
    /// (MultiLiveView). Toutes en pause, hors ligne, en échec ou finies, il
    /// peut s'éteindre, comme pour le lecteur.
    @Published private(set) var keepsScreenOn = false
    /// Session web à donner à getLive pour une chaîne (AppStore).
    var accountToken: (String) -> String? = { _ in nil }
    /// Progression des VODs et premier démarrage (fournis par la vue, depuis
    /// l'AppStore).
    private var resume: (String) -> Double = { _ in 0 }
    private var save: (String, Double) -> Void = { _, _ in }
    private var onStarted: @MainActor (String, VodMeta?) -> Void = { _, _ in }
    /// Appel, Siri, autre app qui prend le son : iOS met les tuiles en pause ;
    /// elles repartent à la fin (PlaybackInterruptions) — les VODs à
    /// l'endroit, les directs relus au bord.
    private var interruptions: PlaybackInterruptions?
    /// Relance prévue au retour du réseau (une seule à la fois).
    private var networkRetry: Task<Void, Never>?

    func configure(resume: @escaping (String) -> Double,
                   save: @escaping (String, Double) -> Void,
                   onStarted: @escaping @MainActor (String, VodMeta?) -> Void) {
        self.resume = resume
        self.save = save
        self.onStarted = onStarted
    }

    /// Un lecteur par vidéo choisie : ajoutés, retirés (position enregistrée).
    func sync(_ entries: [MultiLiveEntry]) {
        let wanted = Set(entries.map(\.id))
        for (id, model) in tiles where !wanted.contains(id) {
            model.stop()
            tiles[id] = nil
        }
        for entry in entries {
            // Déjà là : qualité réajustée si le nombre de tuiles change de palier.
            if let model = tiles[entry.id] { model.adjust(count: entries.count); continue }
            let model = MultiTileModel(entry: entry, accountToken: accountToken,
                                       resume: resume, save: save, onStarted: onStarted)
            model.onPlayState = { [weak self] in self?.refreshScreen() }
            tiles[entry.id] = model
            model.start(count: entries.count)
        }
        if audible.map({ !wanted.contains($0) }) ?? true { audible = entries.first?.id }
        applyAudio()
        refreshScreen()
        if interruptions == nil, !tiles.isEmpty {
            interruptions = PlaybackInterruptions(name: "multi-live") { [weak self] _ in
                Task { @MainActor in self?.tiles.values.forEach { $0.resumeIfStopped() } }
                return "tuiles relancées (VODs à l'endroit, directs au bord)"
            }
        }
        interruptions?.watch(tiles.values.map { $0.player })
    }

    /// Fermeture : chaque VOD enregistre sa position avant de s'arrêter.
    func stopAll() {
        interruptions = nil
        networkRetry?.cancel()
        networkRetry = nil
        tiles.values.forEach { $0.stop() }
        tiles = [:]
        refreshScreen()
    }

    private func refreshScreen() {
        let on = tiles.values.contains { $0.keepsScreenOn }
        if on != keepsScreenOn { keepsScreenOn = on }
    }

    /// « Lecture » sur une tuile arrêtée par iOS : un geste, qui peut couper
    /// le son d'une autre app. Toutes les tuiles arrêtées ainsi repartent,
    /// comme au retour dans l'app (VODs à l'endroit sauf pause voulue,
    /// directs relus au bord), et plus rien n'attend la fin de l'interruption.
    func resumeStopped() {
        interruptions?.settle()
        tiles.values.forEach { $0.resumeIfStopped() }
    }

    /// Réseau revenu après une coupure : 2 s plus tard (le temps que la
    /// connexion s'établisse), les tuiles en échec repartent, une fois, comme
    /// avec « Réessayer ». Rien si aucune n'était en échec.
    func networkRestored() {
        guard networkRetry == nil, tiles.values.contains(where: { $0.phase == .failed }) else { return }
        networkRetry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.networkRetry = nil
            let failed = self.tiles.values.filter { $0.phase == .failed }
            guard !failed.isEmpty else { return }
            logger.info("MULTI", "Réseau revenu : relance des tuiles en échec", "\(failed.count)")
            failed.forEach { $0.retry() }
        }
    }

    /// Avant l'arrière-plan, les positions (la sauvegarde part en
    /// `.background`) ; au retour, ce qu'iOS a mis en pause repart — sauf
    /// après une interruption par le son d'une autre app : la reprise attend
    /// alors qu'il s'arrête (PlaybackInterruptions), pour ne pas le couper ;
    /// d'ici là, chaque tuile arrêtée montre « Lecture ».
    func sceneChanged(_ phase: ScenePhase) {
        switch phase {
        case .inactive, .background:
            tiles.values.forEach { $0.saveProgress() }
        case .active:
            guard interruptions?.isPending != true else { return }
            tiles.values.forEach { $0.resumeIfStopped() }
        @unknown default:
            break
        }
    }

    private func applyAudio() {
        for (id, model) in tiles {
            model.player.isMuted = id != audible
            // En pause pub, la tuile qui a le son est recoupée au tour suivant.
            model.adBreaks.audioTakenOver()
        }
    }
}
