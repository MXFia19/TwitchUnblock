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
    var onLayer: ((AVPlayerLayer) -> Void)? = nil

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let v = PlayerLayerUIView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        onLayer?(v.playerLayer)
        return v
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }
}

// MARK: – Modèle (lecture, fenêtre seekable, PiP)
final class ImmersivePlayerModel: NSObject, ObservableObject {
    let player = AVPlayer()

    @Published var isPlaying = true
    @Published var position:  Double = 0   // temps courant (s)
    @Published var startTime: Double = 0   // début de la fenêtre rembobinable
    @Published var endTime:   Double = 0   // bord du direct, ou fin de la VOD
    @Published var pipActive  = false
    @Published var pipPossible = false

    let isLive: Bool
    /// Rattrape le bord du direct quand la lecture a dérivé (mode faible latence).
    var lowLatency = false

    private let onProgress: (Double) -> Void
    private let onLatency:  (Double?) -> Void
    private var timeObs: Any?
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

    func load(url: URL, seek: Double = 0) {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        if seek > 5 { player.seek(to: CMTime(seconds: seek, preferredTimescale: 600)) }
        player.play()
        isPlaying = true
        lastCatchUp = Date()   // laisse le flux démarrer avant tout rattrapage
    }

    private func tick(_ t: CMTime) {
        guard let item = player.currentItem else { return }

        if let range = item.seekableTimeRanges.last?.timeRangeValue,
           range.duration.seconds > 0 {
            startTime = range.start.seconds
            endTime   = (range.start + range.duration).seconds
        } else if item.duration.seconds.isFinite {
            startTime = 0
            endTime   = item.duration.seconds
        }
        if t.seconds.isFinite {
            position = t.seconds
            onProgress(position)
        }

        // Latence : écart entre l'heure réelle et l'horodatage du segment lu.
        if isLive, let date = item.currentDate() {
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
    @State private var seekFlash: String? = nil

    init(url: URL, isLive: Bool, dvrEnabled: Bool, savedTime: Double,
         info: PlayerOverlayInfo,
         sleepLabel: String? = nil,
         chatMode: LandscapeChat = .column,
         isLandscape: Bool = false,
         controlsInset: CGFloat = 0,
         onProgress: @escaping (Double) -> Void = { _ in },
         onLatency:  @escaping (Double?) -> Void = { _ in },
         onReduce:   @escaping () -> Void = {},
         onClose:    @escaping () -> Void = {},
         onMenu:     @escaping () -> Void = {},
         onRefresh:  @escaping () -> Void = {},
         onToggleChat: @escaping () -> Void = {},
         onSleep:    @escaping () -> Void = {}) {
        self.url = url; self.isLive = isLive; self.dvrEnabled = dvrEnabled
        self.savedTime = savedTime; self.info = info
        self.onProgress = onProgress; self.onLatency = onLatency
        self.sleepLabel = sleepLabel; self.chatMode = chatMode
        self.isLandscape = isLandscape; self.controlsInset = controlsInset
        self.onReduce = onReduce; self.onClose = onClose
        self.onMenu = onMenu; self.onRefresh = onRefresh
        self.onToggleChat = onToggleChat; self.onSleep = onSleep
        _model = StateObject(wrappedValue: ImmersivePlayerModel(
            url: url, isLive: isLive, savedTime: savedTime,
            onProgress: onProgress, onLatency: onLatency))
    }

    /// Un direct sans DVR n'est pas rembobinable : la barre reste décorative.
    private var canScrub: Bool { !isLive || dvrEnabled }

    var body: some View {
        ZStack {
            PlayerLayerView(player: model.player) { layer in
                model.attachPiP(layer: layer)
            }

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
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { toggleControls() }
        .onChange(of: url) { model.load(url: $0) }
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
            // Les barres se replient de la largeur du chat superposé : leurs
            // boutons restent entièrement visibles et cliquables, et suivent
            // la largeur du chat quand on la fait varier.
            // Pas d'animation ici : pendant un glissement la marge doit coller
            // au doigt. Le changement de disposition, lui, est déjà animé par
            // le `withAnimation` du bouton qui le déclenche.
            .padding(.trailing, controlsInset)
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
            if canScrub, model.endTime > model.startTime {
                Slider(
                    value: Binding(
                        get: { dragging ? dragValue : model.position },
                        set: { dragValue = $0 }
                    ),
                    in: model.startTime...max(model.endTime, model.startTime + 1),
                    onEditingChanged: { editing in
                        dragging = editing
                        if editing { dragValue = model.position; hideTask?.cancel() }
                        else { model.seek(to: dragValue); scheduleAutoHide() }
                    }
                )
                .tint(.tPrimary)
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
                flash(label)
            }
    }

    /// Bandeau fugace au centre de l'image (±10 s, changement de mode du chat).
    private func flash(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { seekFlash = text }
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
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
