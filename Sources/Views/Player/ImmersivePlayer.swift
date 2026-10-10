import SwiftUI
import AVKit
import AVFoundation
import MediaPlayer

// ═══════════════════════════════════════════════════════════════════════════
//  Lecteur immersif : les informations et les commandes se superposent à
//  l'image, et s'effacent au bout de quelques secondes.
//
//  AVPlayerViewController pose ses propres contrôles exactement au même
//  endroit : impossible d'y superposer les nôtres proprement. On repasse donc
//  sur un AVPlayerLayer nu, et on refait play/pause, la barre de progression
//  et le PiP à la main.
//
//  Reprend le modèle du lecteur maison écrit puis annulé en juin (6acb66b),
//  corrigé : rattrapage du direct, latence remontée, fin de vie propre.
// ═══════════════════════════════════════════════════════════════════════════

// MARK: – Informations affichées en surimpression
struct PlayerOverlayInfo {
    var channel: String  = ""
    var avatar: String?  = nil
    var title: String    = ""
    var game: String     = ""
    var viewers: Int     = 0
    var uptime: String   = ""
    var latency: Double? = nil
}

// MARK: – Écran verrouillé
/// Ce que l'écran verrouillé et le centre de contrôle affichent pendant la
/// lecture : quoi, de qui, et une image.
struct NowPlayingMeta: Equatable {
    var title: String       = ""
    var artist: String      = ""
    var artworkURL: String? = nil
    // En plus, pour la Live Activity (PlayerActivity) : un direct y montre sa
    // catégorie, ses spectateurs et sa durée.
    var game: String        = ""
    var viewers: Int        = 0
    var startedAt: Date?    = nil
    /// « EN DIRECT », dans la langue choisie dans l'app.
    var liveLabel: String   = "LIVE"
}

// MARK: – Surface vidéo (AVPlayerLayer)
final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    /// `resizeAspectFill` recadre pour occuper toute la surface : plus de bandes
    /// noires, au prix du haut et du bas de l'image. Du 16:9 dans un écran de
    /// téléphone en paysage (≈2.16) ne peut pas faire les deux.
    var fill: Bool = false
    var onLayer: ((AVPlayerLayer) -> Void)? = nil

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let v = PlayerLayerUIView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        v.backgroundColor = .black
        onLayer?(v.playerLayer)
        return v
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
        let wanted: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
        if uiView.playerLayer.videoGravity != wanted {
            uiView.playerLayer.videoGravity = wanted
        }
    }
}

// MARK: – Modèle (lecture, fenêtre seekable, PiP)
final class ImmersivePlayerModel: NSObject, ObservableObject {
    let player = AVPlayer()

    @Published var isPlaying = true
    @Published var position:  Double = 0   // temps courant (s)
    @Published var startTime: Double = 0   // début de la fenêtre rembobinable
    @Published var endTime:   Double = 0   // bord du direct, ou fin de la VOD
    /// Heure réelle de l'image affichée (EXT-X-PROGRAM-DATE-TIME). C'est le
    /// seul repère commun entre le direct et son enregistrement : la base de
    /// temps HLS d'un live ne commence pas au début de la diffusion.
    @Published var currentDate: Date? = nil
    @Published var pipActive  = false
    @Published var pipPossible = false

    /// Pas une constante : une bascule douce direct → enregistrement remplace
    /// la source sans reconstruire le modèle. Figée, elle laissait le lecteur
    /// se croire en direct sur une VOD (rattrapage, latence, bord du direct).
    private(set) var isLive: Bool
    /// Rattrape le bord du direct quand la lecture a dérivé (mode faible latence).
    var lowLatency = false

    private let onProgress: (Double) -> Void
    private let onLatency:  (Double?) -> Void
    /// Distance au bord du direct (s), base de la synchro du chat.
    private let onBehind:   (Double?) -> Void
    private var timeObs: Any?
    private var statusObs: NSKeyValueObservation?
    /// Position demandée avant que l'élément ne soit prêt. Chercher tout de
    /// suite après `replaceCurrentItem` ne tient pas : la playlist HLS n'est
    /// pas encore chargée, la recherche part à la poubelle et la lecture
    /// démarre au début.
    private var pendingSeek: Double?
    private var pip: AVPictureInPictureController?
    private var lastCatchUp = Date.distantPast
    private var latency = LiveLatencyController()
    private var sync = LiveSyncEstimator()

    // Écran verrouillé / centre de contrôle
    private var nowPlaying = NowPlayingMeta()
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var lastNowPlayingUpdate = Date.distantPast
    private var timeControlObs: NSKeyValueObservation?
    private var externalObs: NSKeyValueObservation?
    /// Durée de VOD déjà envoyée à la Live Activity.
    private var activityDuration: Double = 0

    init(url: URL, isLive: Bool, savedTime: Double,
         onProgress: @escaping (Double) -> Void,
         onLatency:  @escaping (Double?) -> Void,
         onBehind:   @escaping (Double?) -> Void = { _ in }) {
        self.isLive     = isLive
        self.onProgress = onProgress
        self.onLatency  = onLatency
        self.onBehind   = onBehind
        super.init()
        // Le son continue écran verrouillé et dans une autre app : sans ça,
        // iOS mettait la vidéo en pause au verrouillage, et les commandes de
        // l'écran verrouillé ne pouvaient rien relancer.
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        load(url: url, seek: savedTime)
        timeObs = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] t in self?.tick(t) }
        // Pause venue d'ailleurs (appel, casque débranché, fin de la VOD) : le
        // bouton et l'écran verrouillé doivent la refléter, sinon il fallait
        // appuyer deux fois sur lecture.
        timeControlObs = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            DispatchQueue.main.async {
                guard let self, p.timeControlStatus == .paused, self.isPlaying,
                      self.player.currentItem != nil else { return }
                self.isPlaying = false
                self.refreshNowPlaying(force: true)
                self.updateActivity()
            }
        }
        // AirPlay ne lit pas les playlists réécrites : retour à celle du CDN.
        externalObs = player.observe(\.isExternalPlaybackActive, options: [.new]) { p, _ in
            DispatchQueue.main.async { VodUnmuteLoader.fallBackForAirPlay(p) }
        }
        setupRemoteCommands()
    }

    func load(url: URL, seek: Double = 0, isLive: Bool? = nil) {
        if let isLive { self.isLive = isLive }
        // Repart d'une fenêtre vierge : garder les bornes de la source
        // précédente affichait une barre fantaisiste le temps du chargement.
        startTime = 0; endTime = 0; currentDate = nil
        sync.reset()

        // Adresse `tuunmute://` : passages coupés rétablis (VodUnmuteLoader).
        let item = VodUnmuteLoader.playerItem(url: url)
        pendingSeek = seek > 5 ? seek : nil
        statusObs = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            DispatchQueue.main.async { self?.applyPendingSeek(on: item) }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        lastCatchUp = Date()   // laisse le flux démarrer avant tout rattrapage
        refreshNowPlaying(force: true)
        updateActivity()
    }

    private func applyPendingSeek(on item: AVPlayerItem) {
        guard let target = pendingSeek, player.currentItem === item else { return }
        pendingSeek = nil
        var t = target
        if let range = item.seekableTimeRanges.last?.timeRangeValue,
           range.duration.seconds > 0 {
            t = max(range.start.seconds,
                    min((range.start + range.duration).seconds, t))
        }
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        position = t
    }

    private func tick(_ t: CMTime) {
        guard let item = player.currentItem else { return }

        // La durée d'abord : sur un enregistrement, la fenêtre cherchable ne
        // couvre au départ que les premières secondes chargées, et la barre
        // affichait « 0:00 / 0:24 » sur une VOD de plusieurs heures. Un direct
        // n'a pas de durée finie, il retombe donc sur la fenêtre.
        let dur = item.duration.seconds
        if dur.isFinite, dur > 0 {
            startTime = 0
            endTime   = dur
        } else if let range = item.seekableTimeRanges.last?.timeRangeValue,
                  range.duration.seconds > 0 {
            startTime = range.start.seconds
            endTime   = (range.start + range.duration).seconds
        }
        if t.seconds.isFinite {
            position = t.seconds
            onProgress(position)
        }
        refreshNowPlaying()
        // Durée d'une VOD connue après coup : la barre de la Live Activity en a
        // besoin. Celle d'un enregistrement en cours grandit sans cesse : on ne
        // la renvoie que par paliers d'une minute.
        if !isLive, endTime > 0, activityDuration == 0 || abs(endTime - activityDuration) > 60 {
            updateActivity()
        }

        // Latence : écart entre l'heure réelle et l'horodatage du segment lu.
        currentDate = item.currentDate()
        let total = isLive ? currentDate.map { Date().timeIntervalSince($0) } : nil
        onLatency(total)
        // Retard sur le direct tel que le voient les autres spectateurs : c'est
        // lui qui sépare le chat de l'image (voir LiveSyncEstimator).
        onBehind(isLive && endTime > position
                 ? sync.offset(latency: total, behind: endTime - position) : nil)

        catchUpIfNeeded(item)
    }

    /// Recolle au direct après une vraie dérive (pause longue, coupure réseau).
    /// Seuils volontairement larges : viser le bord en permanence fait caler.
    private func catchUpIfNeeded(_ item: AVPlayerItem) {
        // Laisse le flux démarrer (quelques secondes) avant d'ajuster.
        guard Date().timeIntervalSince(lastCatchUp) > 4 else { return }
        latency.adjust(player: player, item: item, behind: endTime - position,
                       enabled: lowLatency && isLive && isPlaying && endTime > 0)
    }

    var atLiveEdge: Bool { isLive && (endTime - position) < 12 }

    func togglePlay() { setPlaying(!isPlaying) }

    func setPlaying(_ on: Bool) {
        if on { player.play() } else { player.pause() }
        isPlaying = on
        refreshNowPlaying(force: true)
        updateActivity()
    }

    func seek(to s: Double, exact: Bool = true) {
        guard endTime > startTime else { return }
        let clamped = max(startTime, min(endTime, s))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: exact ? .zero : .positiveInfinity,
                    toleranceAfter:  exact ? .zero : .positiveInfinity)
        position = clamped
        refreshNowPlaying(force: true)
        updateActivity()
    }

    func seekBy(_ delta: Double) { seek(to: position + delta) }

    func goLive() {
        // Même recul que la tenue du direct : plus près sur une playlist
        // relue toutes les 2 s (mode faible latence).
        let back = player.currentItem.map { LiveLatencyController.target(for: $0) } ?? 6
        seek(to: endTime - back, exact: false)
        if !isPlaying { togglePlay() }
    }

    // MARK: PiP
    func attachPiP(layer: AVPlayerLayer) {
        guard pip == nil, AVPictureInPictureController.isPictureInPictureSupported(),
              let p = AVPictureInPictureController(playerLayer: layer) else { return }
        p.delegate = self
        p.canStartPictureInPictureAutomaticallyFromInline = true
        pip = p
        pipPossible = true
    }

    func togglePiP() {
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() }
        else { pip.startPictureInPicture() }
    }

    func teardown() {
        if let o = timeObs { player.removeTimeObserver(o); timeObs = nil }
        statusObs = nil
        timeControlObs = nil
        pendingSeek = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        pip = nil
        clearNowPlaying()
    }

    deinit {
        if let o = timeObs { player.removeTimeObserver(o) }
        for (command, target) in remoteTargets { command.removeTarget(target) }
    }

    // MARK: Écran verrouillé / centre de contrôle
    /// Lecture, pause et sauts de ±10 s depuis l'écran verrouillé, le centre de
    /// contrôle ou des écouteurs ; position réglable sur une VOD.
    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand,
                 _ handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.isEnabled = true
            remoteTargets.append((command, command.addTarget(handler: handler)))
        }
        add(center.playCommand)  { [weak self] _ in self?.setPlaying(true);  return .success }
        add(center.pauseCommand) { [weak self] _ in self?.setPlaying(false); return .success }
        add(center.togglePlayPauseCommand) { [weak self] _ in self?.togglePlay(); return .success }
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.preferredIntervals  = [10]
        add(center.skipBackwardCommand) { [weak self] _ in self?.seekBy(-10); return .success }
        add(center.skipForwardCommand)  { [weak self] _ in self?.seekBy(10);  return .success }
        add(center.changePlaybackPositionCommand) { [weak self] event in
            guard let self, !self.isLive,
                  let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: e.positionTime)
            return .success
        }
    }

    /// Titre, chaîne et image : l'image est téléchargée une fois par adresse.
    func setNowPlaying(_ meta: NowPlayingMeta) {
        guard meta != nowPlaying else { return }
        let newArtwork = meta.artworkURL != nowPlaying.artworkURL
        nowPlaying = meta
        if newArtwork { loadArtwork(meta.artworkURL) }
        refreshNowPlaying(force: true)
        updateActivity()
    }

    /// Live Activity : mêmes infos, plus l'état de la lecture. PlayerActivity
    /// n'envoie que ce qui change à l'écran.
    private func updateActivity() {
        activityDuration = isLive ? 0 : endTime
        PlayerActivity.update(nowPlaying, isLive: isLive, isPlaying: isPlaying,
                              position: position, duration: activityDuration)
    }

    private func loadArtwork(_ address: String?) {
        artworkTask?.cancel()
        artwork = nil
        guard let address, let url = URL(string: address) else { return }
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data), !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.refreshNowPlaying(force: true)
            }
        }
    }

    /// iOS fait avancer seul le temps affiché à partir de la vitesse : on ne
    /// réécrit qu'aux changements d'état, et toutes les 5 s contre la dérive.
    private func refreshNowPlaying(force: Bool = false) {
        guard !nowPlaying.title.isEmpty || !nowPlaying.artist.isEmpty, player.currentItem != nil else { return }
        guard force || Date().timeIntervalSince(lastNowPlayingUpdate) > 5 else { return }
        lastNowPlayingUpdate = Date()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlaying.title,
            MPMediaItemPropertyArtist: nowPlaying.artist,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        // Un direct n'a pas de durée : l'écran verrouillé affiche « EN DIRECT »
        // sans barre de progression.
        if !isLive, endTime > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = endTime
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = !isLive
    }

    private func clearNowPlaying() {
        for (command, target) in remoteTargets { command.removeTarget(target) }
        remoteTargets.removeAll()
        artworkTask?.cancel()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        PlayerActivity.end()
    }
}

extension ImmersivePlayerModel: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        pipActive = true
        PlayerFullscreen.isActive = true   // garde l'IRC et les points actifs
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        pipActive = false
        PlayerFullscreen.isActive = false
    }
}

// MARK: – Lecteur immersif
struct ImmersivePlayer: View {
    let url: URL
    let isLive: Bool
    /// Autorise le rembobinage dans la fenêtre DVR du direct.
    let dvrEnabled: Bool
    let savedTime: Double
    let info: PlayerOverlayInfo
    /// Toucher le pseudo : page de la chaîne (nil = pas de chaîne connue).
    var onChannel: (() -> Void)? = nil

    /// Compte à rebours du minuteur de veille, nil s'il n'est pas armé.
    var sleepLabel: String? = nil
    /// Place du chat en paysage : colonne, superposé, ou replié.
    var chatMode: LandscapeChat = .column
    /// Orientation, fournie par le parent : lue sur UIApplication elle ne serait
    /// pas observable, et la vue ne se redessinerait pas à la rotation.
    var isLandscape: Bool = false
    /// Marge droite des barres de commande : en chat superposé, le calque
    /// occupe cette largeur, et les boutons doivent rester à sa gauche.
    var controlsInset: CGFloat = 0
    /// Recadrer pour remplir l'écran au lieu de laisser des bandes noires.
    /// Coupe le haut et le bas de l'image : c'est le compromis, d'où le réglage.
    var fillScreen: Bool = false
    /// On regarde le DVR d'un direct : proposer d'y retourner.
    var canReturnToLive: Bool = false
    var onBackToLive: () -> Void = {}
    /// Début de la diffusion. Fourni avec `archiveAvailable`, il étale la barre
    /// sur tout le direct au lieu de la seule fenêtre rembobinable.
    var streamStartedAt: Date? = nil
    var archiveAvailable: Bool = false
    /// Chapitres de la VOD (changements de jeu) : repères et liste pour sauter.
    var chapters: [VodChapter] = []
    /// Passages dont Twitch a coupé le son (musique protégée), en orange sur la
    /// barre ; et nombre de segments dont l'app a pu remettre le son.
    var mutedRanges: [MutedRange] = []
    var unmutedCount: Int = 0
    /// Rembobinage au-delà de la fenêtre DVR : le direct ne sait pas y aller,
    /// on bascule sur l'enregistrement à ce nombre de secondes du début.
    var onSeekToArchive: (Double) -> Void = { _ in }
    /// Titre, chaîne et image affichés sur l'écran verrouillé.
    var nowPlaying = NowPlayingMeta()

    var onProgress: (Double) -> Void = { _ in }
    var onLatency:  (Double?) -> Void = { _ in }
    var onBehind:   (Double?) -> Void = { _ in }
    /// Glissé vers le bas en cours (décalage en points, 0 = relâché sans
    /// réduire) : le parent fait suivre le lecteur au doigt.
    var onPull:     (CGFloat) -> Void = { _ in }
    /// Doigt levé : distance glissée et distance projetée (élan). Le parent
    /// décide de réduire ou de remettre le lecteur en place.
    var onPullEnd:  (CGFloat, CGFloat) -> Void = { _, _ in }
    var onReduce:   () -> Void = {}
    var onClose:    () -> Void = {}
    var onMenu:     () -> Void = {}
    var onRefresh:  () -> Void = {}
    var onToggleChat: () -> Void = {}
    var onSleep:    () -> Void = {}

    @EnvironmentObject private var store: AppStore
    @StateObject private var model: ImmersivePlayerModel
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>? = nil
    @State private var dragging  = false
    @State private var dragValue: Double = 0
    /// Bornes gelées le temps d'un glissement. En direct, `endTime` et la durée
    /// écoulée avancent deux fois par seconde : la plage du `Slider` changeait
    /// sous le doigt, le curseur sautait et le geste était perdu — il fallait
    /// re-balayer. Le repère est donc figé à la prise, et le saut calculé
    /// dessus à la relâche.
    @State private var dragSpan: BroadcastSpan? = nil
    @State private var dragBounds: ClosedRange<Double>? = nil
    @State private var seekFlash: String? = nil
    /// Secondes cumulées des doubles-tapes rapprochés, pour afficher « +30 s »
    /// au troisième plutôt que trois fois « +10 s » sans savoir où l'on est.
    @State private var seekTotal: Double = 0
    @State private var seekResetTask: Task<Void, Never>? = nil
    /// Liste des chapitres ouverte (feuille : ne se referme pas toute seule).
    @State private var showChapters = false
    /// Largeur de la bulle du temps visé, mesurée : elle la garde dans la barre
    /// près des bords.
    @State private var bubbleWidth: CGFloat = 0
    /// Zoom à deux doigts sur l'image (1 = taille normale) et décalage de
    /// l'image agrandie. Les valeurs « base » sont celles d'avant le geste en
    /// cours, qui s'y ajoute.
    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panBase: CGSize = .zero
    @State private var surfaceSize: CGSize = .zero
    /// Glissé vers le bas pour réduire le lecteur : décidé au début du geste
    /// (nil tant qu'on ne sait pas si le doigt descend ou va de côté).
    @State private var pulling: Bool? = nil
    /// Vrai pendant le geste. Revient seul à faux quand le geste s'arrête,
    /// y compris interrompu (Centre de contrôle, appel) — cas où onEnded
    /// n'est jamais appelé et où le lecteur restait décalé.
    @GestureState private var panActive = false
    /// Zoom à deux doigts en cours : il prime sur le glissé vers le bas.
    @State private var pinching = false

    init(url: URL, isLive: Bool, dvrEnabled: Bool, savedTime: Double,
         info: PlayerOverlayInfo,
         onChannel: (() -> Void)? = nil,
         sleepLabel: String? = nil,
         chatMode: LandscapeChat = .column,
         isLandscape: Bool = false,
         controlsInset: CGFloat = 0,
         fillScreen: Bool = false,
         canReturnToLive: Bool = false,
         streamStartedAt: Date? = nil,
         archiveAvailable: Bool = false,
         chapters: [VodChapter] = [],
         mutedRanges: [MutedRange] = [],
         unmutedCount: Int = 0,
         nowPlaying: NowPlayingMeta = NowPlayingMeta(),
         onProgress: @escaping (Double) -> Void = { _ in },
         onLatency:  @escaping (Double?) -> Void = { _ in },
         onBehind:   @escaping (Double?) -> Void = { _ in },
         onPull:     @escaping (CGFloat) -> Void = { _ in },
         onPullEnd:  @escaping (CGFloat, CGFloat) -> Void = { _, _ in },
         onReduce:   @escaping () -> Void = {},
         onClose:    @escaping () -> Void = {},
         onMenu:     @escaping () -> Void = {},
         onRefresh:  @escaping () -> Void = {},
         onToggleChat: @escaping () -> Void = {},
         onSleep:    @escaping () -> Void = {},
         onBackToLive: @escaping () -> Void = {},
         onSeekToArchive: @escaping (Double) -> Void = { _ in }) {
        self.url = url; self.isLive = isLive; self.dvrEnabled = dvrEnabled
        self.savedTime = savedTime; self.info = info; self.onChannel = onChannel
        self.onProgress = onProgress; self.onLatency = onLatency
        self.onBehind = onBehind; self.onPull = onPull; self.onPullEnd = onPullEnd
        self.sleepLabel = sleepLabel; self.chatMode = chatMode
        self.isLandscape = isLandscape; self.controlsInset = controlsInset
        self.fillScreen = fillScreen; self.canReturnToLive = canReturnToLive
        self.streamStartedAt = streamStartedAt; self.archiveAvailable = archiveAvailable
        self.chapters = chapters; self.nowPlaying = nowPlaying
        self.mutedRanges = mutedRanges; self.unmutedCount = unmutedCount
        self.onReduce = onReduce; self.onClose = onClose
        self.onMenu = onMenu; self.onRefresh = onRefresh
        self.onToggleChat = onToggleChat; self.onSleep = onSleep
        self.onBackToLive = onBackToLive; self.onSeekToArchive = onSeekToArchive
        _model = StateObject(wrappedValue: ImmersivePlayerModel(
            url: url, isLive: isLive, savedTime: savedTime,
            onProgress: onProgress, onLatency: onLatency, onBehind: onBehind))
    }

    /// Un direct sans DVR n'est pas rembobinable : la barre reste décorative.
    private var canScrub: Bool { !isLive || dvrEnabled }

    /// Le recadrage est réservé au paysage. En portrait la boîte fait déjà
    /// 16:9, comme l'image : il n'y a rien à remplir, et agrandir ne faisait
    /// que couper les côtés.
    private var croppingFill: Bool { fillScreen && isLandscape }

    /// Repères de la barre « toute la diffusion », en secondes depuis le début.
    /// Tout est exprimé par rapport à l'horloge réelle : la base de temps HLS
    /// d'un direct ne commence pas au début de la diffusion, et celle de
    /// l'enregistrement, si, — l'heure est le seul repère commun aux deux.
    private struct BroadcastSpan {
        let total: Double        // durée écoulée depuis le début
        let current: Double      // position lue, en secondes depuis le début
        let playhead: Double     // la même, dans la base de temps du flux
        let windowStart: Double  // bornes de ce que le flux sait rembobiner
        let windowEnd: Double
    }

    private var broadcastSpan: BroadcastSpan? {
        guard isLive, archiveAvailable, canScrub,
              let start = streamStartedAt,
              let now   = model.currentDate,
              model.endTime > model.startTime else { return nil }

        let total   = Date().timeIntervalSince(start)
        let current = now.timeIntervalSince(start)
        guard total > 60, current >= 0, current <= total + 60 else { return nil }

        return BroadcastSpan(
            total: total,
            current: min(current, total),
            playhead: model.position,
            windowStart: max(0, current - (model.position - model.startTime)),
            windowEnd:   min(total, current + (model.endTime - model.position))
        )
    }

    /// Rembobinage sur la barre complète : dans la fenêtre du flux on cherche
    /// normalement, au-delà on passe la main à l'enregistrement.
    private func seekBroadcast(to target: Double, span: BroadcastSpan) {
        if target >= span.windowStart && target <= span.windowEnd {
            // `span.playhead`, pas `model.position` : le repère est celui de la
            // prise du curseur. La lecture a continué pendant le glissement, et
            // s'appuyer sur la position courante décalait l'arrivée d'autant.
            model.seek(to: span.playhead + (target - span.current))
        } else {
            logger.info("LECTEUR", "Rembobinage hors fenêtre DVR",
                        String(format: "→ %.0f s depuis le début", target))
            onSeekToArchive(target)
        }
    }

    var body: some View {
        ZStack {
            // Surface vidéo, agrandie et déplacée par le zoom à deux doigts.
            // Rognée à sa propre boîte : agrandie, l'image débordait sinon sur
            // le chat en portrait. Cette boîte ignore déjà la zone sûre en
            // paysage (plus bas) : « remplir l'écran » n'y perd rien.
            GeometryReader { geo in
                PlayerLayerView(player: model.player, fill: croppingFill) { layer in
                    model.attachPiP(layer: layer)
                }
                .scaleEffect(zoom)
                .offset(pan)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .onAppear { surfaceSize = geo.size }
                .onChange(of: geo.size) { size in
                    surfaceSize = size
                    pan = clampedPan(pan)
                    panBase = pan
                }
            }
            // En paysage la surface va toujours jusqu'aux bords physiques,
            // encoche comprise : sans ça une bande noire restait collée à
            // l'encoche et l'image n'était pas centrée sur l'écran réel. Le
            // cadrage, lui, ne change pas — l'image entière tient la hauteur et
            // laisse des bandes égales sur les côtés.
            //
            // En portrait, jamais : la boîte est déjà en 16:9, déborder ne
            // faisait que la rendre plus haute que large et rogner les côtés.
            .ignoresSafeArea(isLandscape ? SafeAreaRegions.all : [])

            // Zones de double-tap ±10 s (VOD et direct rembobinable).
            if canScrub {
                HStack(spacing: 0) {
                    seekZone(seconds: -10, label: "−10 s")
                    seekZone(seconds:  10, label: "+10 s")
                }
            }

            if let flash = seekFlash {
                Text(flash)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Capsule())
                    .transition(.opacity)
            }

            if showControls { controls }

            // Passage dont Twitch a coupé le son : on le dit (sinon on croit à
            // une panne) et on propose de le sauter.
            if let muted = currentMuted {
                mutedNotice(muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, showControls ? 58 : TSpace.sm)
                    .padding(.trailing, controlsInset)
                    .transition(.opacity)
            }
        }
        // La boîte est fixée par le parent (16:9 en portrait, toute la colonne en
        // paysage) : ici on remplit ce qu'on nous donne, sans jamais dériver la
        // taille des contrôles. AVPlayerLayer étant en `resizeAspect`, l'image
        // garde ses proportions quelle que soit la boîte.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        // Pas de `clipped()` : il rognerait précisément le débordement que
        // « remplir l'écran » vient de demander. AVPlayerLayer borne déjà son
        // image à ses propres limites, y compris en `resizeAspectFill`.
        .contentShape(Rectangle())
        .onTapGesture { toggleControls() }
        // Zoom à deux doigts, comme sur l'app Twitch ; une fois agrandie,
        // l'image se déplace au doigt. À taille normale, glisser vers le bas
        // réduit le lecteur, comme la flèche en haut à gauche.
        .simultaneousGesture(zoomGesture)
        .gesture(panGesture)
        // Geste interrompu en plein glissé : le lecteur reprend sa place.
        .onChange(of: panActive) { active in
            if !active, pulling == true {
                pulling = nil
                onPull(0)
            }
        }
        // Changement de source (direct ↔ enregistrement) : la position voulue
        // et la nature du flux doivent suivre. Sans elles, basculer sur
        // l'enregistrement rouvrait la VOD à 0:00 — il fallait re-balayer la
        // barre — et le modèle continuait de se croire en direct.
        .onChange(of: url) { model.load(url: $0, seek: savedTime, isLive: isLive) }
        // La boîte change du tout au tout : on repart de l'image entière.
        .onChange(of: isLandscape) { _ in resetZoom() }
        .onAppear {
            model.lowLatency = store.lowLatency && isLive
            model.setNowPlaying(nowPlaying)
            scheduleAutoHide()
        }
        .onChange(of: nowPlaying) { model.setNowPlaying($0) }
        // Son rétabli sur des passages coupés : on le signale une fois.
        .onChange(of: unmutedCount) { n in
            if n > 0 { flash(store.t("vod_unmuted"), duration: 2_500_000_000) }
        }
        .animation(.easeInOut(duration: 0.2), value: currentMuted)
        .onChange(of: store.lowLatency) { model.lowLatency = $0 && isLive }
        .onDisappear {
            hideTask?.cancel()
            // En PiP la lecture continue hors de l'écran : ne pas tout couper.
            if !model.pipActive { model.teardown() }
        }
        // Attachée à la racine : la feuille reste ouverte même quand les
        // commandes se masquent (un Menu dans la barre se refermait avec elle).
        .sheet(isPresented: $showChapters, onDismiss: { scheduleAutoHide() }) {
            chaptersSheet
        }
    }

    // ── Liste des chapitres ───────────────────────────────────────────
    @ViewBuilder private var chaptersSheet: some View {
        let current = currentChapter
        NavigationStack {
            List(chapters) { c in
                Button {
                    model.seek(to: c.start)
                    showChapters = false
                } label: {
                    HStack(spacing: 10) {
                        Text(timeLabel(c.start))
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundColor(.tMuted)
                            .frame(minWidth: 56, alignment: .leading)
                        Text(c.title)
                            .font(.system(size: 15, weight: c == current ? .bold : .regular))
                            .foregroundColor(c == current ? .tPrimary : .tText)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        if c == current {
                            Image(systemName: "checkmark").foregroundColor(.tPrimary)
                        }
                    }
                }
                .listRowBackground(Color.tCard)
            }
            .scrollContentBackground(.hidden)
            .background(Color.tDark)
            .navigationTitle(store.t("chapters"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(store.t("close")) { showChapters = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    // MARK: – Commandes en surimpression
    @ViewBuilder private var controls: some View {
        ZStack {
            // Voile : rend le texte lisible sur une image claire.
            LinearGradient(colors: [.black.opacity(0.65), .black.opacity(0.15),
                                    .black.opacity(0.65)],
                           startPoint: .top, endPoint: .bottom)
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }
                // En paysage, l'image descend jusqu'aux bords physiques : le
                // voile suit. Sinon il s'arrêtait à la zone sûre et laissait
                // une bande de vidéo en pleine lumière au-dessus et en dessous.
                .ignoresSafeArea(isLandscape ? SafeAreaRegions.all : [], edges: .vertical)

            // Play / pause au centre — centré sur la partie visible de l'image,
            // pas sur l'écran entier : le chat superposé en masque la droite.
            Button {
                model.togglePlay(); scheduleAutoHide()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 58, height: 58)
                    .tGlass(in: Circle(), fallback: Color.black.opacity(0.45), clear: true)
            }
            .buttonStyle(.plain)
            .offset(x: -controlsInset / 2)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(TSpace.sm)
            // Un peu d'air sous la barre du bas en paysage : les commandes y
            // descendent jusqu'au bord physique, et le trait de la barre
            // d'accueil passerait sinon au ras des boutons.
            .padding(.bottom, isLandscape ? TSpace.xs : 0)
            // Les barres se replient de la largeur du chat superposé : leurs
            // boutons restent entièrement visibles et cliquables, et suivent
            // la largeur du chat quand on la fait varier.
            // Pas d'animation ici : pendant un glissement la marge doit coller
            // au doigt. Le changement de disposition, lui, est déjà animé par
            // le `withAnimation` du bouton qui le déclenche.
            .padding(.trailing, controlsInset)
            // En paysage, la barre du bas descend jusqu'au bord physique : sans
            // ça elle flottait à une trentaine de points du bord quand le haut
            // n'en avait que huit — la barre d'accueil réserve cet espace.
            //
            // Le haut, lui, garde sa zone sûre. Sur iPad la barre d'état reste
            // affichée en paysage (et iPadOS 26 y loge les boutons de fenêtre) :
            // c'est le système qui reçoit les touchers à cet endroit. Glissés
            // dessous, retour, AirPlay et fermer ne répondaient plus. Sur
            // iPhone, rien ne change : la zone sûre du haut y est nulle en
            // paysage. Sur les côtés non plus : l'encoche rognerait le retour.
            .ignoresSafeArea(isLandscape ? SafeAreaRegions.all : [], edges: .bottom)
        }
        .transition(.opacity)
    }

    // ── Barre haute : qui regarde-t-on ────────────────────────────────
    @ViewBuilder private var topBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: TSpace.sm) {
                overlayButton(icon: "chevron.left", action: onReduce)

                AsyncImage(url: URL(string: info.avatar ?? "")) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(Color.white.opacity(0.15))
                }
                .frame(width: 26, height: 26)
                .clipShape(Circle())

                // Nom en clair, titre estompé : le nom prime.
                (
                    Text(info.channel).font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                    + Text("  \(info.title)").font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.65))
                )
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onChannel?() }

                // AirPlay : envoyer la vidéo vers une Apple TV ou une TV compatible.
                AirPlayButton()
                    .frame(width: 32, height: 32)
                    .tGlass(in: Circle(), fallback: Color.black.opacity(0.4), clear: true)
                overlayButton(icon: "ellipsis", action: onMenu)
                overlayButton(icon: "xmark", action: onClose)
            }

            if !info.game.isEmpty {
                HStack(spacing: TSpace.xs) {
                    Image(systemName: "gamecontroller.fill").font(.system(size: 9))
                    Text(info.game).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                .foregroundColor(.white.opacity(0.75))
                .padding(.leading, 68)
            }
        }
    }

    // ── Barre basse : état du flux et commandes ───────────────────────
    @ViewBuilder private var bottomBar: some View {
        VStack(spacing: TSpace.xs) {

            // Barre de progression : VOD, ou direct avec DVR.
            if let live = broadcastSpan {
                // Direct dont l'enregistrement existe : la barre couvre toute
                // la diffusion, pas seulement la fenêtre rembobinable du flux.
                // Pendant le glissement on lit le repère gelé, pas celui qui
                // avance avec la diffusion.
                let span = dragging ? (dragSpan ?? live) : live
                Slider(
                    value: Binding(
                        get: { dragging ? dragValue : span.current },
                        set: { dragValue = $0 }
                    ),
                    in: 0...max(span.total, 1),
                    onEditingChanged: { editing in
                        if editing {
                            dragSpan  = live
                            dragValue = live.current
                            dragging  = true
                            hideTask?.cancel()
                        } else {
                            let frozen = dragSpan ?? live
                            dragging = false
                            dragSpan = nil
                            seekBroadcast(to: dragValue, span: frozen)
                            scheduleAutoHide()
                        }
                    }
                )
                .tint(.tPrimary)
                // Le tronçon réellement accessible dans le flux est teinté :
                // au-delà, c'est l'enregistrement qui prendra le relais, avec
                // le temps de chargement que ça suppose.
                .background(alignment: .leading) {
                    GeometryReader { geo in
                        let w = geo.size.width
                        let a = CGFloat(span.windowStart / max(span.total, 1)) * w
                        let b = CGFloat(span.windowEnd   / max(span.total, 1)) * w
                        Capsule()
                            .fill(Color.white.opacity(0.18))
                            .frame(width: max(0, b - a), height: 3)
                            .offset(x: a)
                    }
                    .allowsHitTesting(false)
                }
                // Instant visé, compté depuis le début du live (comme la durée).
                .overlay {
                    if dragging {
                        scrubBubble(fraction: dragValue / max(span.total, 1),
                                    label: timeLabel(dragValue))
                    }
                }

            } else if canScrub, model.endTime > model.startTime {
                // Même gel des bornes : sur un direct sans enregistrement, la
                // fenêtre rembobinable glisse en permanence vers l'avant.
                let window: ClosedRange<Double> =
                    model.startTime...max(model.endTime, model.startTime + 1)
                let bounds = dragging ? (dragBounds ?? window) : window
                Slider(
                    value: Binding(
                        get: { dragging ? dragValue : model.position },
                        set: { dragValue = $0 }
                    ),
                    in: bounds,
                    onEditingChanged: { editing in
                        if editing {
                            dragBounds = window
                            dragValue  = model.position
                            dragging   = true
                            hideTask?.cancel()
                        } else {
                            dragging   = false
                            dragBounds = nil
                            model.seek(to: dragValue)
                            scheduleAutoHide()
                        }
                    }
                )
                .tint(.tPrimary)
                // Passages au son coupé, en orange sur la piste.
                .overlay {
                    if !isLive, !mutedRanges.isEmpty, model.endTime > 0 {
                        GeometryReader { geo in
                            let inset: CGFloat = 12
                            let w = max(1, geo.size.width - inset * 2)
                            ForEach(mutedRanges) { r in
                                let a = CGFloat(min(1, r.start / model.endTime)) * w
                                let b = CGFloat(min(1, r.end / model.endTime)) * w
                                Capsule()
                                    .fill(Color.tWarning.opacity(0.9))
                                    .frame(width: max(2, b - a), height: 4)
                                    .position(x: inset + (a + b) / 2, y: geo.size.height / 2)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                }
                // Repères de chapitres sur la barre.
                .overlay {
                    if !isLive, chapters.count > 1, model.endTime > 0 {
                        GeometryReader { geo in
                            let inset: CGFloat = 12   // le curseur ne va pas jusqu'au bord
                            let w = max(1, geo.size.width - inset * 2)
                            ForEach(chapters.dropFirst()) { c in
                                Rectangle()
                                    .fill(Color.white.opacity(0.85))
                                    .frame(width: 2, height: 7)
                                    .position(x: inset + CGFloat(min(1, c.start / model.endTime)) * w,
                                              y: geo.size.height / 2)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                }
                // Instant visé : la position dans la VOD (et son chapitre), ou
                // le retard sur le direct quand on remonte sa fenêtre.
                .overlay {
                    if dragging {
                        let range = max(bounds.upperBound - bounds.lowerBound, 1)
                        scrubBubble(fraction: (dragValue - bounds.lowerBound) / range,
                                    label: isLive ? "−\(timeLabel(bounds.upperBound - dragValue))"
                                                  : scrubLabel(dragValue))
                    }
                }

            } else if canScrub {
                // Bornes encore inconnues — le temps qu'une nouvelle source se
                // charge. On garde la place de la barre : la faire disparaître
                // puis revenir faisait sauter la rangée de boutons dessous.
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(height: 3)
                    .frame(height: 28)
            }

            HStack(spacing: TSpace.md) {
                if isLive {
                    Button {
                        model.goLive(); scheduleAutoHide()
                    } label: {
                        HStack(spacing: TSpace.xs) {
                            Circle()
                                .fill(model.atLiveEdge ? Color.tLive : Color.white.opacity(0.5))
                                .frame(width: 7, height: 7)
                            Text(info.uptime.isEmpty ? store.t("live_on") : info.uptime)
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        }
                        .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)

                    if info.viewers > 0 {
                        overlayMeta(icon: "eye.fill", text: formatViewers(info.viewers))
                    }
                    if store.showLatency, let l = info.latency {
                        overlayMeta(icon: "waveform.path.ecg",
                                    text: String(format: "%.0f s", max(0, l)))
                    }
                } else {
                    // Pendant un glissement, l'instant visé plutôt que la
                    // position courante (en violet : ce n'est pas encore lu).
                    Text("\(timeLabel(dragging ? dragValue : model.position)) / \(timeLabel(model.endTime))")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundColor(dragging ? .tPurple : .white)
                    // Chapitre en cours ; un appui liste les chapitres pour y sauter.
                    if chapters.count > 1 {
                        Button {
                            hideTask?.cancel()
                            showChapters = true
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "list.bullet").font(.system(size: 10, weight: .bold))
                                Text(currentChapter?.title ?? "")
                                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, TSpace.sm)
                            .frame(height: 28)
                            .background(Color.black.opacity(0.4))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer(minLength: 0)

                // Minuteur de veille : visible pendant la lecture, pas seulement
                // dans les Réglages. Un appui ouvre le réglage rapide.
                if let sleep = sleepLabel {
                    Button { onSleep(); scheduleAutoHide() } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "moon.zzz.fill").font(.system(size: 10))
                            Text(sleep)
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, TSpace.sm)
                        .frame(height: 32)
                        .background(Color.black.opacity(0.4))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                // On regarde l'enregistrement d'un direct en cours : le retour
                // au direct était enfoui dans le menu « ⋯ », alors que c'est
                // l'action qu'on cherche en premier.
                if canReturnToLive {
                    Button { onBackToLive() } label: {
                        HStack(spacing: TSpace.xs) {
                            Circle().fill(Color.tLive).frame(width: 7, height: 7)
                            Text(store.t("back_to_live"))
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, TSpace.sm)
                        .frame(height: 32)
                        .background(Color.tLive.opacity(0.35))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                if model.pipPossible {
                    overlayButton(icon: "pip.enter") { model.togglePiP(); scheduleAutoHide() }
                }
                overlayButton(icon: "arrow.clockwise") { onRefresh() }

                // En paysage seulement : colonne → superposé → replié, en boucle.
                // Un libellé apparaît brièvement, sinon trois icônes muettes ne
                // disent pas dans quel état on vient d'entrer.
                if isLandscape {
                    overlayButton(icon: chatMode.icon) {
                        onToggleChat()
                        flash(store.t(chatMode.next.labelKey))
                        scheduleAutoHide()
                    }
                }

                // Bascule portrait / paysage. Le même bouton fait l'aller ET le
                // retour : sans ça, un téléphone dont la rotation est verrouillée
                // reste coincé en paysage.
                overlayButton(icon: isLandscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate") {
                    toggleOrientation(); scheduleAutoHide()
                }
            }
        }
    }

    // MARK: – Briques d'interface
    private var currentChapter: VodChapter? { chapter(at: model.position) }

    /// Passage coupé en cours de lecture (VOD seulement).
    private var currentMuted: MutedRange? {
        guard !isLive, !mutedRanges.isEmpty else { return nil }
        let t = dragging ? dragValue : model.position
        return mutedRanges.first { $0.contains(t) }
    }

    @ViewBuilder
    private func mutedNotice(_ r: MutedRange) -> some View {
        HStack(spacing: TSpace.sm) {
            Image(systemName: "speaker.slash.fill").font(.system(size: 11, weight: .bold))
            Text(store.t("vod_muted_here"))
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Button {
                model.seek(to: min(r.end + 0.5, model.endTime))
                scheduleAutoHide()
            } label: {
                HStack(spacing: 3) {
                    Text(store.t("vod_muted_skip")).font(.system(size: 12, weight: .bold))
                    Image(systemName: "forward.end.fill").font(.system(size: 10, weight: .bold))
                }
                .padding(.horizontal, 9).frame(height: 24)
                .background(Color.white.opacity(0.18))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(.white)
        .padding(.leading, 11).padding(.trailing, 4).frame(height: 32)
        .background(Color.black.opacity(0.62))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.tWarning.opacity(0.6), lineWidth: 1))
    }

    private func overlayButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .tGlass(in: Circle(), fallback: Color.black.opacity(0.4), clear: true)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func overlayMeta(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .foregroundColor(.white.opacity(0.85))
        .fixedSize()
    }

    /// Bulle au-dessus du curseur pendant un glissement : l'instant visé. Avant,
    /// rien ne l'indiquait — le compteur gardait la position courante — et on
    /// cherchait le bon moment à l'aveugle. `fraction` : place sur la barre (0…1).
    private func scrubBubble(fraction: Double, label: String) -> some View {
        GeometryReader { geo in
            // Le curseur du Slider s'arrête à une demi-largeur de pouce des bords.
            let inset: CGFloat = 14
            let x = inset + CGFloat(min(max(fraction, 0), 1)) * max(1, geo.size.width - inset * 2)
            // Bornée par sa propre largeur : près des bords, la bulle reste
            // entière au lieu de sortir de l'écran.
            let half = min(bubbleWidth / 2, geo.size.width / 2)
            Text(label)
                .font(.system(size: 14, weight: .bold).monospacedDigit())
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.8))
                .clipShape(Capsule())
                .fixedSize()
                .background(GeometryReader { g in
                    Color.clear.preference(key: BubbleWidthKey.self, value: g.size.width)
                })
                .position(x: min(max(x, half), geo.size.width - half), y: -18)
        }
        .onPreferenceChange(BubbleWidthKey.self) { bubbleWidth = $0 }
        .allowsHitTesting(false)
    }

    /// « 1:23:45 · Just Chatting » : l'instant, et le chapitre où il tombe.
    private func scrubLabel(_ t: Double) -> String {
        guard chapters.count > 1, let c = chapter(at: t) else { return timeLabel(t) }
        let title = c.title.count > 28 ? String(c.title.prefix(27)) + "…" : c.title
        return "\(timeLabel(t)) · \(title)"
    }

    private func chapter(at t: Double) -> VodChapter? {
        var found: VodChapter? = nil
        for c in chapters where c.start <= t + 0.5 { found = c }
        return found
    }

    // MARK: – Zoom à deux doigts
    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                pinching = true
                zoom = min(max(zoomBase * value, 1), 4)
                pan = clampedPan(pan)
            }
            .onEnded { _ in
                pinching = false
                // Rapetissée jusqu'au bout, l'image reprend sa place.
                if zoom < 1.05 {
                    resetZoom()
                } else {
                    zoomBase = zoom
                    panBase = pan
                    flash(String(format: "%.1f×", Double(zoom)))
                }
            }
    }

    /// Repère global : pendant le glissé vers le bas, le lecteur descend avec
    /// le doigt ; mesuré dans son propre repère (qui bouge), le déplacement se
    /// faussait à chaque image et le lecteur avançait par à-coups.
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: CoordinateSpace.global)
            .updating($panActive) { _, active, _ in active = true }
            .onChanged { value in
                // Un glissement sur la barre de lecture ne déplace rien.
                guard !dragging else { return }
                if zoom > 1 {
                    pan = clampedPan(CGSize(width: panBase.width + value.translation.width,
                                            height: panBase.height + value.translation.height))
                    return
                }
                // Deux doigts : c'est un zoom, le lecteur reste en place.
                if pinching {
                    if pulling == true { onPull(0) }
                    pulling = false
                    return
                }
                // Taille normale : seul un geste qui part vers le bas compte ;
                // un glissement de côté ne fait rien, comme avant.
                if pulling == nil {
                    pulling = value.translation.height > abs(value.translation.width)
                }
                if pulling == true { onPull(max(0, value.translation.height)) }
            }
            .onEnded { value in
                defer { pulling = nil }
                if zoom > 1 { panBase = pan; return }
                guard pulling == true else { return }
                onPullEnd(max(0, value.translation.height), value.predictedEndTranslation.height)
            }
    }

    /// L'image agrandie ne laisse jamais apparaître de vide : le décalage est
    /// borné à ce qui dépasse de la boîte.
    private func clampedPan(_ p: CGSize) -> CGSize {
        let maxX = surfaceSize.width  * (zoom - 1) / 2
        let maxY = surfaceSize.height * (zoom - 1) / 2
        return CGSize(width:  min(max(p.width,  -maxX), maxX),
                      height: min(max(p.height, -maxY), maxY))
    }

    private func resetZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            zoom = 1
            pan = .zero
        }
        zoomBase = 1
        panBase = .zero
    }

    /// Moitié d'écran qui recule ou avance de 10 s au double-tap.
    @ViewBuilder
    private func seekZone(seconds: Double, label: String) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                model.seekBy(seconds)
                accumulateSeek(seconds)
            }
    }

    /// Additionne les sauts tant qu'ils s'enchaînent. Un saut dans l'autre sens
    /// repart de zéro : enchaîner −10 après +30 doit afficher −10, pas +20.
    private func accumulateSeek(_ seconds: Double) {
        if seekTotal != 0, (seekTotal < 0) != (seconds < 0) { seekTotal = 0 }
        seekTotal += seconds
        let value = abs(Int(seekTotal.rounded()))
        flash("\(seekTotal < 0 ? "−" : "+")\(value) s", duration: 900_000_000)

        seekResetTask?.cancel()
        seekResetTask = Task {
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled else { return }
            seekTotal = 0
        }
    }

    /// Bandeau fugace au centre de l'image (±10 s, changement de mode du chat).
    private func flash(_ text: String, duration: UInt64 = 700_000_000) {
        withAnimation(.easeOut(duration: 0.15)) { seekFlash = text }
        Task {
            try? await Task.sleep(nanoseconds: duration)
            withAnimation(.easeOut(duration: 0.2)) { seekFlash = nil }
        }
    }

    // MARK: – Affichage des commandes
    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        if showControls { scheduleAutoHide() } else { hideTask?.cancel() }
    }

    /// Les commandes s'effacent seules après 3,5 s d'inactivité.
    private func scheduleAutoHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.25)) { showControls = false }
            }
        }
    }

    private func timeLabel(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let total = Int(s), h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }

    /// Passe en paysage, ou revient en portrait. Indispensable : avec la
    /// rotation verrouillée sur l'iPhone, tourner le téléphone ne suffit pas
    /// à ressortir du plein écran.
    private func toggleOrientation() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        let target: UIInterfaceOrientationMask = isLandscape ? .portrait : .landscapeRight
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { error in
            logger.warn("LECTEUR", "Rotation refusée", error.localizedDescription)
        }
        // Sans ça, iOS peut garder l'ancienne orientation tant qu'aucune vue
        // ne redemande la mise à jour.
        UIViewController.attemptRotationToDeviceOrientation()
    }
}

/// Largeur mesurée de la bulle du temps visé (voir `scrubBubble`).
private struct BubbleWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: – Bouton AirPlay
/// Sélecteur de sortie (AirPlay) natif d'iOS.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = UIColor(red: 0.57, green: 0.27, blue: 1, alpha: 1)
        v.prioritizesVideoDevices = true
        v.backgroundColor = .clear
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
