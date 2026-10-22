import SwiftUI
import AVKit
import AVFoundation

// État plein écran partagé : permet à ChatView de ne pas couper l'IRC/les points
// quand le lecteur passe en plein écran (ce qui déclenche un onDisappear transitoire).
enum PlayerFullscreen {
    static var isActive = false
}

// MARK: – AVPlayerViewController wrapper
struct NativeVideoPlayer: UIViewControllerRepresentable {
    let url: URL
    let savedTime: Double
    /// Ce qui se lit, quelle que soit la qualité (« vod:<id> », « clip:<slug> »…) :
    /// une adresse qui change sans lui est un changement de qualité, et la
    /// lecture reste où elle en est (voir updateUIViewController).
    var contentID: String = ""
    let onProgress: (Double) -> Void
    /// Latence mesurée du direct (nil si la playlist ne porte pas d'horodatage).
    var onLatency: (Double?) -> Void = { _ in }
    /// Distance au bord du direct, en secondes (nil hors direct).
    var onBehind: (Double?) -> Void = { _ in }
    /// Mode faible latence : ne s'applique qu'au direct.
    var lowLatency: Bool = false
    var isLive: Bool = false
    /// Titre, chaîne et image affichés sur l'écran verrouillé.
    var nowPlaying = NowPlayingMeta()
    /// Vitesse hors direct, et crans du menu système (vides en direct).
    var speed: Double = 1
    var speedOptions: [AVPlaybackSpeed] = []
    /// Vitesse choisie dans le menu d'Apple : retenue par le parent.
    var onSpeedChange: (Double) -> Void = { _ in }
    /// Vitesse imposée (bord d'un enregistrement en cours, AirPlay, vitesse
    /// non tenue), ou rendue loin de ce bord : pour cette lecture seulement,
    /// avec l'annonce à afficher (clé de traduction ; nil : la vitesse rendue).
    var onSpeedForced: (Double, String?) -> Void = { _, _ in }
    /// Pause pub du direct (bandeau du parent) : suit chaque nouvel AVPlayer.
    var adBreaks: AdBreakWatcher? = nil
    /// Lecture en cours ou non (pause, fin, échec), à chaque changement.
    var onPlaying: (Bool) -> Void = { _ in }
    /// PiP démarré : le parent réduit le lecteur ; bouton « agrandir » de la
    /// fenêtre : il le rend en grand (MainTabView, voir PlayerPiP).
    var onPiPStart: () -> Void = {}
    var onPiPRestore: () -> Void = {}

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.showsPlaybackControls = true
        vc.delegate = context.coordinator
        context.coordinator.playerVC = vc
        context.coordinator.adBreaks = adBreaks
        context.coordinator.onSpeedChange = onSpeedChange
        context.coordinator.onSpeedForced = onSpeedForced
        context.coordinator.onPlaying = onPlaying
        context.coordinator.onPiPStart = onPiPStart
        context.coordinator.onPiPRestore = onPiPRestore
        // Reprise : la progression enregistrée (une VOD vue jusqu'au bout
        // repart du début).
        startPlayer(in: vc, context: context, from: .init(seconds: savedTime, resume: true))
        return vc
    }

    /// Nouvel AVPlayer pour `url` (ouverture, autre qualité, bascule direct ↔
    /// enregistrement) : réglages, observateurs, départ, vitesse, lecture.
    private func startPlayer(in vc: AVPlayerViewController, context: Context,
                             from start: Coordinator.Start) {
        let coordinator = context.coordinator
        let item = VodUnmuteLoader.playerItem(url: url)
        let player = AVPlayer(playerItem: item)
        // Le son continue écran verrouillé, comme dans le lecteur immersif.
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        vc.player = player
        // Un ancien lecteur retrouve son son avant d'être lâché.
        adBreaks?.attach(player)
        // Adresse demandée, gardée telle quelle : après un repli AirPlay,
        // l'élément lit la playlist du CDN (https) et ne lui ressemble plus.
        coordinator.requestedURL = url
        coordinator.contentID = contentID
        coordinator.isLive = isLive
        coordinator.lowLatency = lowLatency && isLive
        coordinator.configureLatency(player)
        coordinator.setupObserver(player: player, onProgress: onProgress,
                                  onLatency: onLatency, onBehind: onBehind)
        coordinator.arm(item, start)
        // Nouvel AVPlayer : sa vitesse par défaut repartirait à 1×.
        applySpeed(vc, player: player, context: context)
        player.play()
        // Après play() : la Live Activity part en lecture, pas en pause.
        coordinator.applyMetadata(nowPlaying, to: player)
    }

    /// Menu de vitesse d'Apple hors direct seulement : en direct, il se
    /// battrait avec la tenue du direct. play() rend la vitesse par défaut,
    /// d'où `defaultRate` (1× en direct, même après une VOD en accéléré).
    private func applySpeed(_ vc: AVPlayerViewController, player: AVPlayer, context: Context) {
        vc.speeds = isLive ? [] : speedOptions
        // Le menu d'Apple n'a que les crans jusqu'à 2× : une vitesse
        // expérimentale (lecteur immersif) n'y passe pas.
        let rate = isLive ? 1 : VodSpeed.nearestSafe(speed)
        context.coordinator.speed = rate
        player.defaultRate = Float(rate)
        if let option = vc.speeds.first(where: { abs(Double($0.rate) - rate) < 0.01 }) {
            vc.selectSpeed(option)
        }
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSpeedChange = onSpeedChange
        coordinator.onSpeedForced = onSpeedForced
        coordinator.onPlaying = onPlaying
        coordinator.onPiPStart = onPiPStart
        coordinator.onPiPRestore = onPiPRestore
        // Comparée à l'adresse demandée, pas à celle de l'élément : après un
        // repli AirPlay (playlist du CDN), elles différaient toujours, et le
        // lecteur se recréait à chaque mise à jour — en boucle, jamais lisible.
        if coordinator.requestedURL != url {
            // Même contenu, autre qualité : la lecture reste où elle en est
            // (VOD, clip, VOD retrouvée ou téléchargée), un direct reculé exprès
            // garde son retard. Autre contenu (direct ↔ enregistrement) : la
            // progression enregistrée, comme à l'ouverture.
            let sameContent = !contentID.isEmpty && contentID == coordinator.contentID
                && isLive == coordinator.isLive
            let start: Coordinator.Start = sameContent ? coordinator.carryOver()
                                                       : .init(seconds: savedTime, resume: true)
            // L'ancien lecteur se tait avant d'être remplacé.
            vc.player?.pause()
            startPlayer(in: vc, context: context, from: start)
        } else if let player = vc.player {
            coordinator.applyMetadata(nowPlaying, to: player)
        }
    }

    // Force l'arrêt de la vidéo quand la vue est détruite
    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        // Lecteur fermé : plus rien ne le relance (fin d'interruption), ni ne
        // relance sa Live Activity (observateur tardif).
        coordinator.teardown()
        vc.player?.pause()
        coordinator.adBreaks?.detach()
        vc.player = nil
        // En arrière-plan (raid suivi, VOD suivante), l'activité reste pour
        // le lecteur suivant (voir PlayerActivity.playerRemoved).
        PlayerActivity.playerRemoved()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        weak var playerVC: AVPlayerViewController?
        private var timeObserver: Any?
        private var playerRef: AVPlayer?
        private var externalObs: NSKeyValueObservation?
        /// Lecture ou pause, d'après AVPlayer : la Live Activity la suit.
        private var timeControlObs: NSKeyValueObservation?

        /// Adresse demandée pour le lecteur en cours (voir updateUIViewController).
        var requestedURL: URL?
        /// Contenu du lecteur en cours (voir NativeVideoPlayer.contentID).
        var contentID = ""
        /// Lecture d'un direct (journaux LIVE).
        var isLive = false
        /// Pause pub du direct : détachée quand le lecteur disparaît.
        var adBreaks: AdBreakWatcher?
        /// Mode faible latence actif (direct uniquement).
        var lowLatency = false
        /// Vitesse retenue hors direct, et qui la reçoit quand elle change.
        var speed: Double = 1
        var onSpeedChange: (Double) -> Void = { _ in }
        var onSpeedForced: (Double, String?) -> Void = { _, _ in }
        /// Vitesse d'avant le retour à 1× au bord d'un enregistrement en
        /// cours : rendue quand la lecture s'en éloigne (retour en arrière).
        private var edgeHeldSpeed: Double?
        /// Vitesse réellement tenue (EffectiveRateProbe), comme le lecteur
        /// immersif : fenêtres manquées de suite, vitesse déjà réappliquée.
        private var rateProbe = EffectiveRateProbe()
        private var rateMisses = 0
        private var rateReapplied = false
        /// Lecture en cours ou non (voir NativeVideoPlayer.onPlaying), et la
        /// dernière annoncée pour le lecteur en cours.
        var onPlaying: (Bool) -> Void = { _ in }
        private var lastPlaying: Bool?
        /// PiP démarré, et bouton « agrandir » de sa fenêtre (voir
        /// NativeVideoPlayer.onPiPStart).
        var onPiPStart: () -> Void = {}
        var onPiPRestore: () -> Void = {}
        private var rateObserver: NSObjectProtocol?
        private var lastCatchUp = Date.distantPast
        private var latency = LiveLatencyController()
        private var sync = LiveSyncEstimator()
        private var stallObserver: NSObjectProtocol?
        private var stallTimes: [Date] = []
        private var lastStallSignal = Date.distantPast
        private var diagnostics: LiveDiagnostics?
        private var jumpObserver: NSObjectProtocol?
        /// Appel, Siri, autre app qui prend le son : la lecture repart à la
        /// fin (PlaybackInterruptions). nil une fois le lecteur fermé.
        var interruptions: PlaybackInterruptions?
        /// Démonté (vue fermée) : plus rien ne relance ce lecteur ni ne publie
        /// pour lui (Live Activity).
        private var tornDown = false
        /// Durée de VOD déjà envoyée à la Live Activity.
        private var activityDuration: Double = 0

        // MARK: Départ
        /// Où démarre un nouvel élément.
        struct Start {
            /// Position à retrouver (au-delà de 5 s), une fois l'élément prêt.
            var seconds: Double = 0
            /// `seconds` vient de la progression enregistrée : une VOD vue
            /// jusqu'au bout repart alors du début.
            var resume = false
            /// Direct reculé exprès : retard sur le bord à retrouver.
            var behind: Double? = nil
        }

        /// Départ en attente. Chercher juste après la création de l'élément ne
        /// tient pas en HLS (playlist pas encore chargée) : la lecture partait de
        /// 0:00, et ce 0:00, envoyé comme progression, écrasait la reprise.
        private var pendingSeek: Double?
        private var pendingIsResume = false
        private var pendingBehind: Double?
        /// Élément auquel s'applique le départ en attente.
        private weak var pendingItem: AVPlayerItem?
        private var statusObs: NSKeyValueObservation?

        /// Départ de `item`, appliqué une fois l'élément prêt.
        func arm(_ item: AVPlayerItem, _ start: Start) {
            clearPending()
            pendingSeek = !isLive && start.seconds > 5 ? start.seconds : nil
            pendingIsResume = start.resume
            pendingBehind = isLive ? start.behind : nil
            guard pendingSeek != nil || pendingBehind != nil else { return }
            pendingItem = item
            statusObs = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                guard item.status != .unknown else { return }
                DispatchQueue.main.async { self?.applyPendingSeek(on: item) }
            }
        }

        private func clearPending() {
            statusObs = nil
            pendingItem = nil
            pendingSeek = nil
            pendingBehind = nil
        }

        /// Élément prêt : le départ s'applique.
        private func applyPendingSeek(on item: AVPlayerItem) {
            guard item === pendingItem else { return }
            // En échec : le départ reste en attente (une autre qualité le
            // reprendra), et rien ne part comme progression — le 0:00 de
            // l'élément écraserait la reprise.
            guard item.status == .readyToPlay else { statusObs = nil; return }
            let target = pendingSeek, behind = pendingBehind, resume = pendingIsResume
            clearPending()
            guard !tornDown, let player = playerRef, player.currentItem === item else { return }
            if let behind {
                // Direct reculé exprès, passé à une autre qualité : même retard
                // sur le bord, et tenu (sinon la tenue du direct le défaisait).
                // Jamais plus près du bord que visé.
                guard let range = item.seekableTimeRanges.last?.timeRangeValue,
                      range.duration.seconds > 0 else { return }
                let t = max(range.start.seconds, (range.start + range.duration).seconds - behind)
                player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                            toleranceBefore: .positiveInfinity, toleranceAfter: .zero)
                latency.hold(true)
                return
            }
            guard let target else { return }
            // Reprise d'une VOD regardée jusqu'au bout (à moins de 30 s de la
            // fin, même règle que le lecteur immersif et le site) : le début.
            // Elle se rouvrait sur sa dernière seconde, et « Tout lire » passait
            // aussitôt à la suivante. Un enregistrement en cours n'a pas de fin.
            let length = item.duration.seconds
            if resume, length.isFinite, length > 0, target > length - 30 {
                logger.info("LECTEUR", "VOD déjà vue jusqu'au bout", "reprise au début")
                return
            }
            var t = target
            if let range = item.seekableTimeRanges.last?.timeRangeValue,
               range.duration.seconds > 0 {
                t = max(range.start.seconds, min((range.start + range.duration).seconds, t))
            }
            player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }

        /// Ce que le lecteur en cours doit retrouver dans un autre élément du
        /// même contenu (autre qualité) : sa position (VOD, clip, VOD retrouvée
        /// ou téléchargée), ou son retard voulu sur le bord (direct reculé en
        /// mode faible latence, seul cas où ce recul est connu). Avant, tout
        /// repartait de la progression enregistrée, qui vaut 0 hors VOD de
        /// Twitch. Un départ encore en attente passe tel quel.
        func carryOver() -> Start {
            if let pendingSeek { return Start(seconds: pendingSeek, resume: pendingIsResume) }
            if let pendingBehind { return Start(behind: pendingBehind) }
            guard let player = playerRef, let item = player.currentItem else { return Start() }
            guard isLive else {
                let t = player.currentTime().seconds
                return Start(seconds: t.isFinite ? max(0, t) : 0)
            }
            guard lowLatency, latency.holdingBehind,
                  let edge = item.seekableTimeRanges.last?.timeRangeValue.end, edge.isNumeric else { return Start() }
            let behind = (edge - item.currentTime()).seconds
            return behind.isFinite && behind > 0 ? Start(behind: behind) : Start()
        }

        /// Prépare le direct : le mode faible latence tient ensuite le bord du
        /// direct en continu (catchUpIfNeeded).
        ///
        /// Ne jamais remettre `automaticallyWaitsToMinimizeStalling = false` ni un
        /// `configuredTimeOffsetFromLive` inférieur à `recommendedTimeOffsetFromLive` :
        /// le lecteur démarre alors sans tampon et passe son temps à se recharger.
        func configureLatency(_ player: AVPlayer) {
            // Le Coordinator survit au changement de qualité (nouvel AVPlayer) :
            // la tenue du direct repart de zéro, recalage du démarrage compris.
            latency.reset()
            guard lowLatency else { return }
            lastCatchUp = Date()   // laisse le flux démarrer avant tout rattrapage
            logger.info("LIVE", "Mode faible latence actif", "tenue du bord du direct (sauts seulement, vitesse ×1)")
        }

        /// Tient le bord du direct par des sauts seulement : voir
        /// LiveLatencyController. En pause, on ne touche à rien.
        private func catchUpIfNeeded() {
            guard lowLatency, let player = playerRef, let item = player.currentItem,
                  let liveEdge = item.seekableTimeRanges.last?.timeRangeValue.end,
                  liveEdge.isValid, liveEdge.isNumeric else { return }
            let behind = (liveEdge - item.currentTime()).seconds
            // Le recalage du démarrage part dès que la lecture a commencé ; le
            // reste laisse d'abord le flux démarrer (quelques secondes).
            latency.adjust(player: player, item: item, behind: behind,
                           total: item.currentDate().map { Date().timeIntervalSince($0) },
                           enabled: player.rate > 0 && behind > 0,
                           settled: Date().timeIntervalSince(lastCatchUp) > 4)
        }

        /// Appui sur la latence : au bord du direct par un saut, au même recul
        /// que la tenue du direct, sans recharger le flux ; relancé s'il était
        /// en pause.
        private func goLive() {
            guard isLive, let player = playerRef, let item = player.currentItem,
                  let edge = item.seekableTimeRanges.last?.timeRangeValue.end,
                  edge.isValid, edge.isNumeric else { return }
            let target = max(0, edge.seconds - latency.minBehind(for: item))
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                        toleranceBefore: .positiveInfinity, toleranceAfter: .zero)
            latency.hold(false)
            if player.rate == 0 { player.play() }
        }

        /// Les commandes d'AVPlayerViewController (−15 s, barre) ne passent pas
        /// par notre code : un saut loin du bord est un recul voulu, que la
        /// tenue du direct ne doit pas défaire. Les sauts du contrôleur, eux,
        /// sont écartés par leur horodatage (marge pour une recherche lente),
        /// comme ceux du démarrage (position initiale, recalage).
        private func timeJumped(_ item: AVPlayerItem) {
            guard lowLatency, item === playerRef?.currentItem, latency.aligned,
                  Date().timeIntervalSince(lastCatchUp) > 4,
                  Date().timeIntervalSince(latency.lastJumpAt) > 5,
                  let edge = item.seekableTimeRanges.last?.timeRangeValue.end, edge.isNumeric else { return }
            let behind = (edge - item.currentTime()).seconds
            guard behind.isFinite else { return }
            latency.hold(behind > latency.minBehind(for: item) + 3)
        }

        // MARK: Plein écran et PiP — maintiennent PlayerFullscreen.isActive à jour
        /// Ce lecteur a mis le drapeau à vrai (plein écran, PiP) : il le rend
        /// au démontage, même si AVKit n'a pas prévenu de la fin.
        private var fullscreenShown = false
        private var pipShown = false

        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            fullscreenShown = true
            PlayerFullscreen.isActive = true
        }
        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                guard let self, !self.tornDown else { return }
                self.fullscreenShown = false
                // Un PiP parti du plein écran garde le chat actif.
                if !self.pipShown { PlayerFullscreen.isActive = false }
            }
        }
        /// PiP : comme dans le lecteur immersif, le chat garde son IRC et ses
        /// points tant qu'il dure, et le lecteur se réduit (MainTabView) — il
        /// restait en grand, sur la vignette « lu en PiP » d'Apple.
        func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            guard !tornDown else { return }
            pipShown = true
            PlayerFullscreen.isActive = true
            logger.info("LECTEUR", "PiP démarré", "lecteur natif")
            PlayerPiP.shared.started(by: self)
            onPiPStart()
        }
        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  failedToStartPictureInPictureWithError error: Error) {
            logger.warn("LECTEUR", "PiP impossible", "lecteur natif · \(error.localizedDescription)")
        }
        /// Bouton « agrandir » de la fenêtre : le lecteur revient en grand,
        /// puis AVKit y ramène l'image (même lecture, rien n'est rechargé).
        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            guard !tornDown else { completionHandler(false); return }
            logger.info("LECTEUR", "PiP : retour au lecteur", "lecteur natif")
            onPiPRestore()
            // Le temps que le lecteur réapparaisse (voir le lecteur immersif).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { completionHandler(true) }
        }
        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            guard !tornDown else { return }
            pipShown = false
            if !fullscreenShown { PlayerFullscreen.isActive = false }
            PlayerPiP.shared.ended(by: self)
            logger.info("LECTEUR", "PiP arrêté", "lecteur natif")
        }

        /// Jeton de l'observateur à bloc : `removeObserver(self)` ne le retire
        /// pas, il restait un observateur par lecteur ouvert.
        private var stopObserver: NSObjectProtocol?
        private var spatialObserver: NSObjectProtocol?
        private var goLiveObserver: NSObjectProtocol?

        override init() {
            super.init()
            spatialObserver = NotificationCenter.default.addObserver(
                forName: .tuSpatialAudioChanged, object: nil, queue: .main
            ) { [weak self] _ in self?.reloadForSpatialAudio() }
            goLiveObserver = NotificationCenter.default.addObserver(
                forName: .tuGoLive, object: nil, queue: .main
            ) { [weak self] _ in self?.goLive() }
            // Coupe instantanément le son si on reçoit le signal "ForceStopVideo" depuis la croix
            stopObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name("ForceStopVideo"), object: nil, queue: .main) { [weak self] _ in
                self?.playerVC?.player?.pause()
                self?.playerVC?.player = nil
            }
            interruptions = PlaybackInterruptions(name: "lecteur natif") { [weak self] since in
                self?.resumeAfterInterruption(since: since)
            }
        }

        /// Lecteur démonté (vue fermée) : observateurs retirés, et drapeau du
        /// plein écran et du PiP rendu — sinon le chat de la chaîne quittée,
        /// et tous ceux ouverts ensuite, ne coupaient plus leur IRC.
        func teardown() {
            guard !tornDown else { return }
            tornDown = true
            interruptions = nil
            clearPending()
            timeControlObs = nil
            externalObs = nil
            diagnostics = nil
            if let o = timeObserver { playerRef?.removeTimeObserver(o); timeObserver = nil }
            removeObservers()
            artworkTask?.cancel()
            if pipShown { PlayerPiP.shared.ended(by: self) }
            if fullscreenShown || pipShown {
                fullscreenShown = false
                pipShown = false
                PlayerFullscreen.isActive = false
            }
        }

        /// Observateurs à bloc (audio spatial compris : il n'était jamais
        /// retiré, un par lecteur ouvert restait appelé à chaque changement).
        private func removeObservers() {
            for token in [stopObserver, spatialObserver, goLiveObserver, jumpObserver, rateObserver, stallObserver] {
                if let token { NotificationCenter.default.removeObserver(token) }
            }
            stopObserver = nil
            spatialObserver = nil
            goLiveObserver = nil
            jumpObserver = nil
            rateObserver = nil
            stallObserver = nil
        }

        /// Fin d'une interruption du son : la lecture repart. VOD, clip, VOD
        /// téléchargée, enregistrement d'un direct : à l'endroit ; direct : au
        /// bord, comme « Direct » dans le lecteur immersif (un saut, jamais la
        /// vitesse), relu après une longue coupure ; reculé exprès (mode
        /// faible latence), à l'endroit tant que le direct garde ce moment.
        /// Rend ce qui a été fait (journal).
        private func resumeAfterInterruption(since: TimeInterval) -> String? {
            guard let player = playerRef, let item = player.currentItem, item.status != .failed,
                  player.timeControlStatus == .paused else { return nil }
            guard isLive else {
                let length = item.duration.seconds, at = item.currentTime().seconds
                // VOD finie : rien à reprendre.
                if length.isFinite, length > 0, at >= length - 1 { return nil }
                player.play()
                return String(format: "à %.0f s", at)
            }
            // Recul voulu, testé d'abord : connu en mode faible latence
            // seulement (timeJumped). Sans lui, le lecteur se tient déjà à
            // ~18 s du bord d'une fenêtre de 30 s : un recul n'y laisse que
            // quelques secondes, aucune coupure ne le garderait.
            let held = lowLatency && latency.holdingBehind
            if held, LiveLatencyController.stillInWindow(item, after: since) {
                player.play()
                return "direct, à l'endroit (recul voulu)"
            }
            let lost = held ? " (recul voulu sorti de la fenêtre du direct)" : ""
            if since >= PlaybackInterruptions.longInterruption, let asset = item.asset as? AVURLAsset {
                // App suspendue pendant un long appel : le bord a pu partir
                // sans nous. Nouvel élément, pris au bord.
                latency.reset()
                lastCatchUp = Date()
                clearPending()
                player.replaceCurrentItem(with: VodUnmuteLoader.playerItem(url: asset.url))
                if let meta = metadataShown { applyMetadata(meta, to: player) }
                player.play()
                return "direct relu au bord" + lost
            }
            if let edge = item.seekableTimeRanges.last?.timeRangeValue.end, edge.isNumeric {
                // Même recul que la tenue du direct ; tolérance avant
                // seulement : jamais plus près du bord que la cible.
                let back = CMTime(seconds: latency.minBehind(for: item), preferredTimescale: 600)
                player.seek(to: edge - back, toleranceBefore: .positiveInfinity, toleranceAfter: .zero)
                latency.hold(false)
            }
            player.play()
            return "direct, au bord" + lost
        }

        /// Réglage « Audio spatial » changé : l'élément est recréé au même
        /// endroit (rien ne garantit qu'iOS relise ce choix en cours de lecture).
        /// Un direct repart au bord ; une VOD, même en cours d'enregistrement
        /// (sans durée finie, elle était prise pour un direct), à l'endroit.
        private func reloadForSpatialAudio() {
            guard !tornDown, let player = playerRef,
                  let current = player.currentItem,
                  let asset = current.asset as? AVURLAsset else { return }
            let t = player.currentTime()
            let playing = player.rate != 0
            let item = VodUnmuteLoader.playerItem(url: asset.url)
            if isLive {
                // Nouvel élément du direct : la tenue repart de zéro.
                latency.reset()
                lastCatchUp = Date()
                clearPending()
            } else if let pendingSeek {
                // Départ pas encore appliqué : il suit le nouvel élément.
                arm(item, Start(seconds: pendingSeek, resume: pendingIsResume))
            } else {
                VodUnmuteLoader.seek(player, to: t, whenReady: item)
            }
            player.replaceCurrentItem(with: item)
            if playing { player.play() }
            if let meta = metadataShown { applyMetadata(meta, to: player) }
        }

        func setupObserver(player: AVPlayer,
                           onProgress: @escaping (Double) -> Void,
                           onLatency: @escaping (Double?) -> Void = { _ in },
                           onBehind: @escaping (Double?) -> Void = { _ in }) {
            if let existing = timeObserver { playerRef?.removeTimeObserver(existing) }
            playerRef = player
            // Nouvel AVPlayer (qualité, bascule direct ↔ enregistrement) :
            // c'est lui que les interruptions suivent, sans reprise en attente.
            interruptions?.watch(player)
            interruptions?.settle()
            sync.reset()
            activityDuration = 0
            resetRateCheck()
            // Journaux LIVE et sauts du lecteur : réabonnés à chaque nouvel
            // AVPlayer (changement de qualité).
            diagnostics = LiveDiagnostics(player: player) { [weak self] in self?.isLive ?? false }
            if isLive { LiveDiagnostics.logAudioRoute("début du direct") }
            // Calage (mémoire tampon vide) : le direct prend de l'avance sur
            // le bord ; répétés, la vue baisse la qualité (.tuPlaybackStalling).
            if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
            stallTimes = []
            stallObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemPlaybackStalled, object: nil, queue: .main
            ) { [weak self] note in
                guard let self, let item = note.object as? AVPlayerItem,
                      item === self.playerRef?.currentItem else { return }
                if self.isLive { self.latency.noteStall() }
                let now = Date()
                self.stallTimes = self.stallTimes.filter { now.timeIntervalSince($0) < 60 } + [now]
                guard self.stallTimes.count >= 2, now.timeIntervalSince(self.lastStallSignal) > 90 else { return }
                self.lastStallSignal = now
                self.stallTimes = []
                NotificationCenter.default.post(name: .tuPlaybackStalling, object: "native")
            }
            if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver) }
            jumpObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.timeJumpedNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let self, let item = note.object as? AVPlayerItem,
                      item === self.playerRef?.currentItem else { return }
                self.timeJumped(item)
                // La vitesse tenue se mesure de nouveau après le saut.
                self.rateProbe.reset()
                // Saut (barre, ±15 s, reprise) : la Live Activity repart d'ici.
                self.updateActivity()
            }
            // AirPlay ne lit pas les playlists réécrites : retour à celle du CDN.
            externalObs = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] p, _ in
                DispatchQueue.main.async {
                    guard let self, !self.tornDown, p === self.playerRef else { return }
                    // Départ encore en attente (reprise d'une VOD) : il suit le
                    // nouvel élément, au lieu de repartir de 0:00.
                    let waiting = self.pendingSeek != nil
                    let start = Start(seconds: self.pendingSeek ?? 0, resume: self.pendingIsResume)
                    guard let item = VodUnmuteLoader.fallBackForAirPlay(p, keepPosition: !waiting) else { return }
                    if waiting { self.arm(item, start) }
                    // Titre et image de l'écran verrouillé : propres à chaque élément.
                    if let meta = self.metadataShown { self.applyMetadata(meta, to: p) }
                }
            }
            // Lecture ou pause (commandes d'Apple, écran verrouillé, appel,
            // fin) : la Live Activity la suit, le parent aussi (écran allumé).
            lastPlaying = nil
            timeControlObs = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
                DispatchQueue.main.async {
                    // Pause ou attente : la vitesse tenue ne se mesure que sur
                    // une lecture continue.
                    if p.timeControlStatus != .playing { self?.rateProbe.reset() }
                    self?.updateActivity()
                    self?.reportPlaying()
                }
            }
            // Vitesse changée hors de nous : elle devient la vitesse par
            // défaut (play() la rend après une pause). Choisie dans le menu
            // d'Apple, elle est retenue par le parent ; imposée (AirPlay, bord
            // d'un enregistrement en cours), pour cette lecture seulement.
            // Rien en direct, ni en pause.
            if let rateObserver { NotificationCenter.default.removeObserver(rateObserver) }
            rateObserver = NotificationCenter.default.addObserver(
                forName: AVPlayer.rateDidChangeNotification, object: player, queue: .main
            ) { [weak self, weak player] note in
                guard let self, let player, !self.isLive, player.rate > 0 else { return }
                let v = VodSpeed.nearest(Double(player.rate))
                guard abs(v - self.speed) > 0.01 else { return }
                let raw = note.userInfo?[AVPlayer.rateDidChangeReasonKey]
                let reason = (raw as? AVPlayer.RateDidChangeReason)?.rawValue ?? (raw as? String)
                let chosen = reason == nil || reason == AVPlayer.RateDidChangeReason.setRateCalled.rawValue
                let held = self.speed
                self.speed = v
                player.defaultRate = Float(v)
                self.resetRateCheck()
                if chosen {
                    self.edgeHeldSpeed = nil
                    self.onSpeedChange(v)
                } else {
                    let atEdge = v < held && (player.currentItem.map { Coordinator.nearRecordingEdge($0) } ?? false)
                    self.edgeHeldSpeed = atEdge ? held : nil
                    self.onSpeedForced(v, atEdge ? "speed_caught_up" : "speed_unavailable")
                }
                self.updateActivity()
            }
            // 1 s : assez fin pour synchroniser le chat des VODs.
            let interval = CMTime(seconds: 1, preferredTimescale: 600)
            timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak player] time in
                guard let self, !self.tornDown else { return }
                // Élément remplacé sans nous : son départ ne s'appliquera plus.
                if self.pendingSeek != nil || self.pendingBehind != nil,
                   player?.currentItem !== self.pendingItem {
                    self.clearPending()
                }
                // Départ en attente (ouverture, autre qualité) : l'élément lit
                // encore 0:00. L'envoyer écrasait la progression enregistrée.
                if self.pendingSeek == nil { onProgress(time.seconds) }
                // Latence = écart entre l'heure réelle et l'horodatage du segment lu
                // (EXT-X-PROGRAM-DATE-TIME de la playlist HLS). nil si absent.
                let total = player?.currentItem?.currentDate().map { Date().timeIntervalSince($0) }
                onLatency(total)
                // Retard sur le direct tel que le voient les autres spectateurs :
                // la base de la synchro du chat (LiveSyncEstimator). Un direct
                // n'a pas de durée finie.
                if let item = player?.currentItem, item.duration.isIndefinite,
                   let edge = item.seekableTimeRanges.last?.timeRangeValue.end, edge.isNumeric {
                    onBehind(self.sync.offset(latency: total,
                                              behind: (edge - item.currentTime()).seconds))
                } else {
                    onBehind(nil)
                }
                if self.isLive, let item = player?.currentItem {
                    self.diagnostics?.tick(item: item)
                }
                // Durée d'une VOD connue après coup : la barre de la Live
                // Activity en a besoin. Celle d'un enregistrement en cours
                // grandit sans cesse : renvoyée par paliers d'une minute.
                if !self.isLive, let item = player?.currentItem {
                    let length = Coordinator.vodLength(item)
                    if length > 0, self.activityDuration == 0 || abs(length - self.activityDuration) > 60 {
                        self.updateActivity()
                    }
                }
                // Vitesse : bord d'un enregistrement en cours, vitesse tenue.
                if !self.isLive, let p = player, let item = p.currentItem, self.pendingSeek == nil {
                    self.checkRecordingEdge(p, item)
                    self.checkEffectiveRate(p)
                }
                self.catchUpIfNeeded()
            }
        }

        // MARK: Vitesse (hors direct)
        /// Enregistrement d'un direct en cours (pas de fin déclarée) lu près de
        /// son bord : en accéléré, on le rattrape.
        static func nearRecordingEdge(_ item: AVPlayerItem) -> Bool {
            guard !item.duration.seconds.isFinite,
                  let range = item.seekableTimeRanges.last?.timeRangeValue else { return false }
            let end = (range.start + range.duration).seconds, at = item.currentTime().seconds
            return end.isFinite && at.isFinite && end > 0 && end - at < 20
        }

        /// Loin du bord d'un enregistrement en cours (retour en arrière), ou
        /// enregistrement terminé : la vitesse peut revenir. Écart avec
        /// `nearRecordingEdge` pour ne pas osciller.
        private static func clearOfRecordingEdge(_ item: AVPlayerItem) -> Bool {
            if item.duration.seconds.isFinite { return true }
            guard let range = item.seekableTimeRanges.last?.timeRangeValue else { return false }
            let end = (range.start + range.duration).seconds, at = item.currentTime().seconds
            return end.isFinite && at.isFinite && end > 0 && end - at > 45
        }

        /// Accéléré au bord d'un enregistrement en cours, la lecture ne peut
        /// pas aller plus vite que la diffusion : 1×, montré dans le menu
        /// d'Apple (il affichait encore 2×). La vitesse d'avant revient quand
        /// la lecture s'éloigne du bord (retour en arrière).
        private func checkRecordingEdge(_ player: AVPlayer, _ item: AVPlayerItem) {
            if speed > 1, player.rate > 1, Coordinator.nearRecordingEdge(item) {
                let held = speed
                impose(1, on: player, notice: "speed_caught_up")
                edgeHeldSpeed = held
                logger.info("LECTEUR", "Vitesse ramenée à " + String(format: "×%g", 1.0),
                            "bord de l'enregistrement rattrapé")
            } else if let held = edgeHeldSpeed, player.rate > 0, Coordinator.clearOfRecordingEdge(item) {
                edgeHeldSpeed = nil
                impose(held, on: player, notice: nil)
                logger.info("LECTEUR", "Loin du bord de l'enregistrement : vitesse rendue", String(format: "×%g", held))
            }
        }

        /// Vitesse réellement tenue (voir EffectiveRateProbe) : d'abord
        /// réappliquée, puis, si la lecture ne la suit toujours pas, adoptée
        /// telle qu'elle joue — le menu d'Apple montre ce qui joue.
        private func checkEffectiveRate(_ player: AVPlayer) {
            guard speed != 1, UIApplication.shared.applicationState == .active,
                  let measured = rateProbe.sample(player) else { return }
            guard abs(measured - speed) > max(0.15, speed * 0.12) else { rateMisses = 0; return }
            rateMisses += 1
            guard rateMisses >= 2 else { return }
            rateMisses = 0
            guard rateReapplied else {
                rateReapplied = true
                logger.warn("LECTEUR", "Vitesse non tenue : réappliquée",
                            String(format: "×%.2f mesuré pour ×%g", measured, speed))
                player.playImmediately(atRate: Float(speed))
                rateProbe.reset()
                return
            }
            let real = VodSpeed.nearestSafe(measured)
            impose(real, on: player, notice: "speed_unavailable")
            logger.info("LECTEUR", "Vitesse ramenée à " + String(format: "×%g", real),
                        String(format: "×%.2f mesuré", measured))
        }

        private func resetRateCheck() {
            rateProbe.reset()
            rateMisses = 0
            rateReapplied = false
        }

        /// Vitesse posée par le lecteur lui-même : `speed` d'abord, pour que
        /// l'observateur de vitesse y reconnaisse la sienne ; le menu d'Apple
        /// la montre ; le parent la garde pour cette lecture seulement.
        private func impose(_ v: Double, on player: AVPlayer, notice: String?) {
            speed = v
            resetRateCheck()
            player.defaultRate = Float(v)
            if let vc = playerVC, let option = vc.speeds.first(where: { abs(Double($0.rate) - v) < 0.01 }) {
                vc.selectSpeed(option)
            }
            if player.rate != 0, abs(Double(player.rate) - v) > 0.01 { player.rate = Float(v) }
            onSpeedForced(v, notice)
            updateActivity()
        }

        // MARK: Live Activity
        /// L'état réel de la lecture (pause comprise) et, pour une VOD, sa
        /// position et sa durée : elle restait « en lecture », sans progression.
        /// PlayerActivity n'envoie que ce qui change à l'écran.
        func updateActivity() {
            guard !tornDown, let meta = metadataShown, let player = playerRef,
                  let item = player.currentItem else { return }
            let length = isLive ? 0 : Coordinator.vodLength(item)
            activityDuration = length
            let at = player.currentTime().seconds
            PlayerActivity.update(meta, isLive: isLive,
                                  isPlaying: player.timeControlStatus != .paused,
                                  position: at.isFinite ? max(0, at) : 0, duration: length,
                                  rate: isLive ? 1 : speed)
        }

        /// Lecture ou pause, une fois par changement ; à nouveau pour chaque
        /// nouvel AVPlayer (autre qualité : peut-être l'audio seul).
        private func reportPlaying() {
            guard !tornDown, let player = playerRef else { return }
            let playing = player.timeControlStatus != .paused
            guard playing != lastPlaying else { return }
            lastPlaying = playing
            onPlaying(playing)
        }

        /// Durée d'une VOD ; pour un enregistrement en cours, la fin de ce
        /// qu'on peut déjà lire. 0 si on ne la connaît pas encore.
        private static func vodLength(_ item: AVPlayerItem) -> Double {
            let d = item.duration.seconds
            if d.isFinite, d > 0 { return d }
            guard let range = item.seekableTimeRanges.last?.timeRangeValue else { return 0 }
            let end = (range.start + range.duration).seconds
            return end.isFinite && end > 0 ? end : 0
        }

        // MARK: Écran verrouillé
        // AVPlayerViewController publie lui-même la lecture et ses commandes sur
        // l'écran verrouillé ; il lui manquait seulement le titre, la chaîne et
        // l'image, qu'il lit dans les métadonnées de l'élément lu.
        private var metadataShown: NowPlayingMeta?
        private weak var metadataItem: AVPlayerItem?
        private var artworkData: Data?
        private var artworkTask: Task<Void, Never>?

        func applyMetadata(_ meta: NowPlayingMeta, to player: AVPlayer) {
            guard let item = player.currentItem,
                  meta != metadataShown || item !== metadataItem else { return }
            if meta.artworkURL != metadataShown?.artworkURL {
                artworkData = nil
                artworkTask?.cancel()
                if let address = meta.artworkURL, let url = URL(string: address) {
                    artworkTask = Task { [weak self, weak player] in
                        guard let (data, _) = try? await URLSession.shared.data(from: url),
                              !Task.isCancelled else { return }
                        await MainActor.run {
                            guard let self, let item = player?.currentItem else { return }
                            self.artworkData = data
                            self.writeMetadata(meta, to: item)
                        }
                    }
                }
            }
            metadataShown = meta
            metadataItem = item
            writeMetadata(meta, to: item)
            // Live Activity : mêmes infos, plus l'état de la lecture.
            updateActivity()
        }

        private func writeMetadata(_ meta: NowPlayingMeta, to item: AVPlayerItem) {
            func entry(_ identifier: AVMetadataIdentifier,
                       _ value: NSCopying & NSObjectProtocol) -> AVMetadataItem {
                let m = AVMutableMetadataItem()
                m.identifier = identifier
                m.value = value
                m.extendedLanguageTag = "und"
                return m
            }
            var items = [entry(.commonIdentifierTitle, meta.title as NSString),
                         entry(.commonIdentifierArtist, meta.artist as NSString)]
            if let artworkData {
                items.append(entry(.commonIdentifierArtwork, artworkData as NSData))
            }
            item.externalMetadata = items
        }

        deinit {
            if let obs = timeObserver { playerRef?.removeTimeObserver(obs) }
            removeObservers()
            artworkTask?.cancel()
        }
    }
}

// MARK: – Full Video Player View
struct VideoPlayerView: View {
    let qualityLinks: QualityLinks
    /// VOD à reprendre et dont on garde la progression (nil sinon).
    let vodId: String?
    /// Direct en cours, donné par l'appelant : faux pendant son rembobinage,
    /// et pour un clip ou une VOD retrouvée ou téléchargée, qui n'ont pas
    /// d'identifiant de VOD mais ne sont pas des directs. Décide de la tenue
    /// du direct, de la latence et de la synchro du chat.
    let isLive: Bool
    /// Ce qui se lit, quelle que soit la qualité (« vod:<id> »…) : changer de
    /// qualité garde la lecture où elle en est (NativeVideoPlayer).
    var contentID: String = ""
    /// Hauteur et cadence de chaque qualité (qualité préférée) ; vide quand
    /// la source ne les donne pas.
    var variants: [String: VariantInfo] = [:]
    /// Mode compact (chat ouvert) : masque la barre Source / le lien pour laisser
    /// un maximum de place au chat. Seul le lecteur reste visible.
    var compact: Bool = false
    /// Titre, chaîne et image affichés sur l'écran verrouillé.
    var nowPlaying = NowPlayingMeta()
    /// Vitesse hors direct (VODs : retenue ; clip : 1× au départ), et qui la
    /// reçoit quand on la change dans le menu d'Apple.
    var speed: Double = 1
    var onSpeedChange: (Double) -> Void = { _ in }
    /// Vitesse imposée par le lecteur (bord d'un enregistrement en cours,
    /// AirPlay, vitesse non tenue) ou rendue loin de ce bord : pour cette
    /// lecture seulement, annoncée par-dessus l'image.
    var onSpeedForced: (Double) -> Void = { _ in }
    /// Position de lecture remontee au parent (utilisee par le chat des VODs).
    var onTime: (Double) -> Void = { _ in }
    /// Latence du direct remontee au parent (affichage).
    var onLatency: (Double?) -> Void = { _ in }
    /// Distance au bord du direct remontee au parent (synchro auto du chat).
    var onBehind: (Double?) -> Void = { _ in }
    /// Une image joue (lecture en cours, hors audio seul) : le parent empêche
    /// alors la mise en veille de l'écran.
    var onPlaying: (Bool) -> Void = { _ in }
    /// Annonce brève au lancement (direct servi par le compte, sans pub).
    var notice: String? = nil
    /// Glissé vers le bas sur l'image : la vidéo et le chat descendent
    /// ensemble, puis passent en mini-lecteur (distance, puis distance et
    /// fin prévue du geste, au doigt levé).
    var onPull: (CGFloat) -> Void = { _ in }
    var onPullEnd: (CGFloat, CGFloat) -> Void = { _, _ in }
    // Actions affichees a cote du bouton Source (nil = bouton masque).
    var onChat: (() -> Void)? = nil
    var onRewind: (() -> Void)? = nil
    var onBackToLive: (() -> Void)? = nil
    /// Qualité voulue par le parent quand il change lui-même de source
    /// (qualités supérieures : 1080p sans pub le temps d'une pause pub, puis
    /// retour au compte) : prise dès que les liens l'ont, tant qu'aucune n'a
    /// été choisie ici.
    var wantedQuality: String? = nil
    /// Pause pub à l'écran (secondes restantes, nil hors pause), pour le parent.
    var onAdBreak: (Int?) -> Void = { _ in }
    /// PiP démarré : le parent réduit le lecteur ; bouton « agrandir » de la
    /// fenêtre : il le rend en grand.
    var onPiPStart: () -> Void = {}
    var onPiPRestore: () -> Void = {}

    @EnvironmentObject private var store: AppStore
    @State private var selectedQuality: String = ""
    /// Qualité choisie ici (menu, ou baissée après des calages) : reprise dès
    /// que les liens l'ont de nouveau (retour d'une pause pub), et
    /// `wantedQuality` ne passe plus devant.
    @State private var picked: String? = nil
    @State private var showQualityPicker = false
    @State private var currentTime: Double = 0
    @State private var lastPersisted: Double = -99
    @State private var latency: Double? = nil
    /// Pause pub cousue par Twitch dans le direct : bandeau, son coupé.
    @StateObject private var adBreaks = AdBreakWatcher()
    @State private var noticeShown: String? = nil

    private var qualities: [String] { sortQualities(Array(qualityLinks.keys), variants: variants) }
    /// Qualité lue : celle choisie, sinon (pas encore choisie, ou absente des
    /// nouveaux liens) la préférence. Calculée ici plutôt que corrigée après
    /// coup : le temps d'un rendu, l'adresse manquait, et le lecteur était
    /// détruit puis recréé (ou restait absent, zone vidéo vide).
    private var quality: String {
        if let picked {
            if qualityLinks[picked] != nil { return picked }
        } else if let wanted = wantedQuality, qualityLinks[wanted] != nil {
            return wanted
        }
        return qualityLinks[selectedQuality] != nil ? selectedQuality : preferredSelection(qualityLinks)
    }
    private var currentURL: URL? { qualityLinks[quality].flatMap(URL.init) }

    var body: some View {
        VStack(spacing: 0) {

            // ── Player ──────────────────────────────────────────────
            if let url = currentURL {
                nativePlayer(url: url)
                    // Glissé vers le bas sur l'image : réduit le lecteur, comme
                    // le bandeau (geste simultané : ceux d'Apple restent).
                    .modifier(PlayerPullGesture(onPull: onPull, onPullEnd: onPullEnd))
            }

            // En mode compact (chat ouvert) on n'affiche que le lecteur.
            if !compact {
            // ── Options bar ─────────────────────────────────────────
            // Tous les boutons partagent la même hauteur fixe : sinon une icône
            // SF Symbol (taille « body » par défaut) rend son bouton plus haut
            // que celui qui ne contient que du texte en 12 pt.
            HStack(spacing: 8) {
                // Qualité : bouton compact, il laisse la place aux actions.
                Button { showQualityPicker.toggle() } label: {
                    actionLabel(text: qualityLabel(quality), emoji: "🎬",
                                fg: .white, bg: Color.tPrimary)
                }

                if let rewind = onRewind {
                    Button(action: rewind) {
                        actionLabel(text: store.t("rewind"), icon: "gobackward",
                                    fg: .tPrimary, bg: Color.tPrimary.opacity(0.15),
                                    border: .tPrimary)
                    }
                }

                if let backLive = onBackToLive {
                    Button(action: backLive) {
                        actionLabel(text: store.t("back_to_live"), dot: true,
                                    fg: .white, bg: Color.tLive)
                    }
                }

                Spacer(minLength: 0)

                if let chat = onChat {
                    Button(action: chat) {
                        actionLabel(text: "Chat", icon: "bubble.left.fill",
                                    fg: .white, bg: Color.tPrimary)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .background(Color.tCard)

            // ── Quality picker ──────────────────────────────────────
            if showQualityPicker {
                VStack(spacing: 0) {
                    ForEach(qualities, id: \.self) { q in
                        Button {
                            // Toucher la qualité déjà cochée ne change pas la préférence.
                            if q != quality {
                                store.rememberQualityChoice(q, among: qualities, variants: variants)
                            }
                            currentTime = 0
                            selectedQuality = q
                            picked = q
                            showQualityPicker = false
                        } label: {
                            HStack {
                                Text(q == quality ? "✓  " : "    ")
                                    .foregroundColor(q == quality ? .tPrimary : .clear)
                                Text(qualityLabel(q))
                                    .foregroundColor(q == quality ? .tPrimary : .tMuted)
                                    .fontWeight(q == quality ? .bold : .semibold)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        Divider().background(Color.tBorder)
                    }
                }
                .background(Color.tSurface)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.tBorder, lineWidth: 1))
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            } // fin if !compact
        }
        .background(Color.tCard)
        .cornerRadius(16)
        .onAppear {
            if selectedQuality.isEmpty { selectedQuality = preferredSelection(qualityLinks) }
        }
        // Autres liens (bascule direct ↔ rembobinage, autre source) : la
        // qualité en cours peut ne plus y être ; on repart de la préférence
        // au lieu de rester sans image.
        .onChange(of: qualityLinks) { links in
            if links[selectedQuality] == nil { selectedQuality = preferredSelection(links) }
        }
        // Calages répétés : qualité trop haute pour le débit (données mobiles,
        // Wi-Fi faible) → « Auto » (elle suit le débit), ou un cran dessous.
        // La préférence enregistrée ne change pas.
        .onReceive(NotificationCenter.default.publisher(for: .tuPlaybackStalling)) { note in
            guard note.object as? String == "native" else { return }
            let current = quality
            guard !isAutoQuality(current), !isAudioQuality(current) else { return }
            var next = qualityLinks.keys.first(where: isAutoQuality)
            if next == nil {
                let keys = Array(qualityLinks.keys)
                let height = { (k: String) in qualityHeight(k, among: keys, variants: variants) }
                let video = keys.filter { !isAudioQuality($0) && !isAutoQuality($0) }.sorted { height($0) > height($1) }
                if let i = video.firstIndex(of: current), i + 1 < video.count { next = video[i + 1] }
            }
            guard let next, next != current else { return }
            logger.warn("LECTEUR", "Calages répétés : qualité baissée", "\(current) → \(next)")
            selectedQuality = next
            picked = next
        }
        // Qualités supérieures sans abonnement : le parent bascule de source
        // pendant les pauses pub (MainTabView.adBreakChanged).
        .onReceive(adBreaks.$remaining) { onAdBreak($0) }
    }

    /// Qualité préférée, ou la plus proche en dessous (même règle que le lecteur immersif).
    private func preferredSelection(_ links: QualityLinks) -> String {
        // En données mobiles : la qualité choisie pour elles (Auto par défaut).
        launchQualityKey(Array(links.keys), pref: store.preferredQuality, cellularPref: store.cellularQuality,
                         cellular: NetworkStatus.shared.isCellular, variants: variants)
    }

    // Lecteur natif (AVPlayerViewController) avec PiP + reprise de position.
    @ViewBuilder
    private func nativePlayer(url: URL) -> some View {
        NativeVideoPlayer(
            url: url,
            savedTime: vodId.map { store.getVodProgress($0) } ?? 0,
            contentID: contentID,
            onProgress: { time in
                currentTime = time
                onTime(time)
                // Progression persistee au plus toutes les 5 s (l'observateur tourne a 1 s,
                // inutile d'ecrire dans UserDefaults a chaque tick).
                if let id = vodId, abs(time - lastPersisted) >= 5 {
                    lastPersisted = time
                    store.setVodProgress(id, time: time)
                }
            },
            onLatency: { value in
                // Seul le direct a une latence exploitable.
                let measured = isLive ? value : nil
                if latency != measured { latency = measured }
                onLatency(measured)
            },
            onBehind: { value in onBehind(isLive ? value : nil) },
            lowLatency: store.lowLatency,
            isLive: isLive,
            nowPlaying: nowPlaying,
            speed: speed,
            speedOptions: VodSpeed.all.map {
                AVPlaybackSpeed(rate: Float($0),
                                localizedName: $0 == 1 ? store.t("speed_normal") : VodSpeed.label($0, store.lang))
            },
            onSpeedChange: onSpeedChange,
            onSpeedForced: { v, key in
                onSpeedForced(v)
                // Vitesse rendue (pas de clé) : « Vitesse 2× », comme le
                // lecteur immersif.
                showNotice(key.map { store.t($0) }
                           ?? store.t("speed") + " " + (v == 1 ? store.t("speed_normal") : VodSpeed.label(v, store.lang)))
            },
            adBreaks: adBreaks,
            // Audio seul : rien à regarder, l'écran peut s'éteindre.
            onPlaying: { playing in onPlaying(playing && !isAudioQuality(quality)) },
            onPiPStart: onPiPStart,
            onPiPRestore: onPiPRestore
        )
        .aspectRatio(16/9, contentMode: .fit)
        .background(Color.black)
        .overlay(alignment: .topLeading) {
            // Un appui ramène au bord du direct, sans recharger. Rien pendant
            // un glissé du lecteur (PlayerPull.guarded) : il part aussi d'ici.
            if store.showLatency, isLive {
                Button {
                    PlayerPull.guarded {
                        NotificationCenter.default.post(name: .tuGoLive, object: nil)
                    }
                } label: {
                    latencyChip
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.t("back_to_live"))
                .padding(8)
            }
        }
        .overlay(alignment: .top) {
            AdBreakBanner(watcher: adBreaks).padding(.top, 44).padding(.horizontal, 12)
        }
        .overlay(alignment: .bottom) {
            if let text = noticeShown {
                Text(text)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
                    .padding(.bottom, 56)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onAppear { showNotice(notice) }
        .onChange(of: notice) { showNotice($0) }
    }

    /// Annonce affichée 2,5 s par-dessus l'image.
    private func showNotice(_ text: String?) {
        guard let text else { return }
        withAnimation(.easeOut(duration: 0.15)) { noticeShown = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation(.easeOut(duration: 0.2)) { if noticeShown == text { noticeShown = nil } }
        }
    }

    // MARK: – Débogage : pastille de latence
    @ViewBuilder
    private var latencyChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform.path.ecg").font(.system(size: 9, weight: .bold))
            Text(latency.map { String(format: "%.1f s", max(0, $0)) } ?? "—")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
        }
        .foregroundColor(latencyColor)
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(Color.black.opacity(0.55))
        .cornerRadius(6)
    }

    /// Vert < 8 s (faible latence), jaune < 20 s, rouge au-delà.
    private var latencyColor: Color {
        guard let l = latency else { return .tMuted }
        if l < 8  { return .tSuccess }
        if l < 20 { return .tWarning }
        return .tDanger
    }

    // MARK: – Bouton de la barre d'actions (hauteur commune)
    @ViewBuilder
    private func actionLabel(text: String, emoji: String? = nil, icon: String? = nil,
                             dot: Bool = false, fg: Color, bg: Color,
                             border: Color? = nil) -> some View {
        HStack(spacing: 4) {
            if let emoji { Text(emoji).font(.system(size: 12)) }
            if let icon  { Image(systemName: icon).font(.system(size: 12, weight: .bold)) }
            if dot       { Circle().fill(fg).frame(width: 6, height: 6) }
            Text(text).font(.system(size: 12, weight: .bold))
        }
        .foregroundColor(fg)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(bg)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(border ?? .clear, lineWidth: border == nil ? 0 : 1)
        )
    }

    private func qualityLabel(_ q: String) -> String { qualityText(q, store.lang) }
}
