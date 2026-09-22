import SwiftUI
import AVKit
import AVFoundation

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
    private var timeObs: Any?
    private var statusObs: NSKeyValueObservation?
    /// Position demandée avant que l'élément ne soit prêt. Chercher tout de
    /// suite après `replaceCurrentItem` ne tient pas : la playlist HLS n'est
    /// pas encore chargée, la recherche part à la poubelle et la lecture
    /// démarre au début.
    private var pendingSeek: Double?
    private var pip: AVPictureInPictureController?
    private var lastCatchUp = Date.distantPast

    init(url: URL, isLive: Bool, savedTime: Double,
         onProgress: @escaping (Double) -> Void,
         onLatency:  @escaping (Double?) -> Void) {
        self.isLive     = isLive
        self.onProgress = onProgress
        self.onLatency  = onLatency
        super.init()
        load(url: url, seek: savedTime)
        timeObs = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] t in self?.tick(t) }
    }

    func load(url: URL, seek: Double = 0, isLive: Bool? = nil) {
        if let isLive { self.isLive = isLive }
        // Repart d'une fenêtre vierge : garder les bornes de la source
        // précédente affichait une barre fantaisiste le temps du chargement.
        startTime = 0; endTime = 0; currentDate = nil

        let item = AVPlayerItem(url: url)
        pendingSeek = seek > 5 ? seek : nil
        statusObs = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            DispatchQueue.main.async { self?.applyPendingSeek(on: item) }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        lastCatchUp = Date()   // laisse le flux démarrer avant tout rattrapage
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

        // Latence : écart entre l'heure réelle et l'horodatage du segment lu.
        currentDate = item.currentDate()
        if isLive, let date = currentDate {
            onLatency(Date().timeIntervalSince(date))
        } else {
            onLatency(nil)
        }

        catchUpIfNeeded(item)
    }

    /// Recolle au direct après une vraie dérive (pause longue, coupure réseau).
    /// Seuils volontairement larges : viser le bord en permanence fait caler.
    private func catchUpIfNeeded(_ item: AVPlayerItem) {
        guard lowLatency, isLive, isPlaying, endTime > 0 else { return }
        let behind = endTime - position
        guard behind > 30, Date().timeIntervalSince(lastCatchUp) > 60 else { return }
        lastCatchUp = Date()
        let recommended = item.recommendedTimeOffsetFromLive
        let offset = max(10, recommended.isValid && recommended.isNumeric
                             ? recommended.seconds : 0)
        logger.debug("LIVE", "Rattrapage du direct",
                     String(format: "%.0f s de retard", behind))
        seek(to: endTime - offset, exact: false)
    }

    var atLiveEdge: Bool { isLive && (endTime - position) < 12 }

    func togglePlay() {
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    func seek(to s: Double, exact: Bool = true) {
        guard endTime > startTime else { return }
        let clamped = max(startTime, min(endTime, s))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: exact ? .zero : .positiveInfinity,
                    toleranceAfter:  exact ? .zero : .positiveInfinity)
        position = clamped
    }

    func seekBy(_ delta: Double) { seek(to: position + delta) }

    func goLive() {
        seek(to: endTime - 6, exact: false)
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
        pendingSeek = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        pip = nil
    }

    deinit { if let o = timeObs { player.removeTimeObserver(o) } }
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
    /// Rembobinage au-delà de la fenêtre DVR : le direct ne sait pas y aller,
    /// on bascule sur l'enregistrement à ce nombre de secondes du début.
    var onSeekToArchive: (Double) -> Void = { _ in }

    var onProgress: (Double) -> Void = { _ in }
    var onLatency:  (Double?) -> Void = { _ in }
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

    init(url: URL, isLive: Bool, dvrEnabled: Bool, savedTime: Double,
         info: PlayerOverlayInfo,
         sleepLabel: String? = nil,
         chatMode: LandscapeChat = .column,
         isLandscape: Bool = false,
         controlsInset: CGFloat = 0,
         fillScreen: Bool = false,
         canReturnToLive: Bool = false,
         streamStartedAt: Date? = nil,
         archiveAvailable: Bool = false,
         onProgress: @escaping (Double) -> Void = { _ in },
         onLatency:  @escaping (Double?) -> Void = { _ in },
         onReduce:   @escaping () -> Void = {},
         onClose:    @escaping () -> Void = {},
         onMenu:     @escaping () -> Void = {},
         onRefresh:  @escaping () -> Void = {},
         onToggleChat: @escaping () -> Void = {},
         onSleep:    @escaping () -> Void = {},
         onBackToLive: @escaping () -> Void = {},
         onSeekToArchive: @escaping (Double) -> Void = { _ in }) {
        self.url = url; self.isLive = isLive; self.dvrEnabled = dvrEnabled
        self.savedTime = savedTime; self.info = info
        self.onProgress = onProgress; self.onLatency = onLatency
        self.sleepLabel = sleepLabel; self.chatMode = chatMode
        self.isLandscape = isLandscape; self.controlsInset = controlsInset
        self.fillScreen = fillScreen; self.canReturnToLive = canReturnToLive
        self.streamStartedAt = streamStartedAt; self.archiveAvailable = archiveAvailable
        self.onReduce = onReduce; self.onClose = onClose
        self.onMenu = onMenu; self.onRefresh = onRefresh
        self.onToggleChat = onToggleChat; self.onSleep = onSleep
        self.onBackToLive = onBackToLive; self.onSeekToArchive = onSeekToArchive
        _model = StateObject(wrappedValue: ImmersivePlayerModel(
            url: url, isLive: isLive, savedTime: savedTime,
            onProgress: onProgress, onLatency: onLatency))
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
            PlayerLayerView(player: model.player, fill: croppingFill) { layer in
                model.attachPiP(layer: layer)
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
        // Changement de source (direct ↔ enregistrement) : la position voulue
        // et la nature du flux doivent suivre. Sans elles, basculer sur
        // l'enregistrement rouvrait la VOD à 0:00 — il fallait re-balayer la
        // barre — et le modèle continuait de se croire en direct.
        .onChange(of: url) { model.load(url: $0, seek: savedTime, isLive: isLive) }
        .onAppear {
            model.lowLatency = store.lowLatency && isLive
            scheduleAutoHide()
        }
        .onChange(of: store.lowLatency) { model.lowLatency = $0 && isLive }
        .onDisappear {
            hideTask?.cancel()
            // En PiP la lecture continue hors de l'écran : ne pas tout couper.
            if !model.pipActive { model.teardown() }
        }
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

            // Play / pause au centre — centré sur la partie visible de l'image,
            // pas sur l'écran entier : le chat superposé en masque la droite.
            Button {
                model.togglePlay(); scheduleAutoHide()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 58, height: 58)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Circle())
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
        }
        .transition(.opacity)
        // En paysage, l'image descend jusqu'au bord physique : les commandes
        // suivent. Sinon le voile s'arrêtait à la zone sûre et laissait une
        // bande de vidéo en pleine lumière sous la barre, et les boutons
        // flottaient à une trentaine de points du bord quand le haut n'en
        // avait que huit — la barre d'accueil réserve cet espace.
        //
        // Verticalement seulement : sur les côtés, l'encoche rognerait le
        // bouton retour, et la marge y est déjà celle de l'exemple.
        .ignoresSafeArea(isLandscape ? SafeAreaRegions.all : [], edges: .vertical)
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
                    Text("\(timeLabel(model.position)) / \(timeLabel(model.endTime))")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundColor(.white)
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
    @ViewBuilder
    private func overlayButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(Color.black.opacity(0.4))
                .clipShape(Circle())
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
