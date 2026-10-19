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
    /// Son coupé (bouton du lecteur, ou pause pub) : suit `player.isMuted`.
    @Published private(set) var muted = false
    private var mutedObs: NSKeyValueObservation?

    /// Bouton haut-parleur : coupe ou remet le son.
    func toggleMute() { player.isMuted.toggle() }
    /// Élément en échec (réseau perdu longtemps, playlist ou segment refusés) :
    /// l'image restait figée et ▶ ne faisait rien. La vue le dit, avec
    /// « Réessayer ».
    @Published private(set) var failed = false
    /// Pause pub cousue par Twitch dans le direct : bandeau, son coupé.
    let adBreaks = AdBreakWatcher()

    /// Pas une constante : une bascule douce direct → enregistrement remplace
    /// la source sans reconstruire le modèle. Figée, elle laissait le lecteur
    /// se croire en direct sur une VOD (rattrapage, latence, bord du direct).
    private(set) var isLive: Bool
    /// Rattrape le bord du direct quand la lecture a dérivé (mode faible latence).
    var lowLatency = false

    /// Vitesse de lecture hors direct (cran de VodSpeed). Un direct joue
    /// toujours à 1× : en direct, elle est seulement retenue pour la bascule
    /// sur l'enregistrement.
    @Published private(set) var speed: Double = 1
    /// Vitesse imposée par le lecteur (refus, AirPlay, bord du DVR rattrapé) :
    /// la vue la retient pour la lecture en cours (pas dans la préférence) et
    /// annonce `notice`.
    struct SpeedChange: Equatable {
        let value: Double
        let notice: String
        let id: Int
    }
    @Published private(set) var forcedSpeed: SpeedChange?
    private var rateObs: NSObjectProtocol?

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
    /// Élément créé par `load` : celui auquel s'applique la position en attente.
    private weak var loadedItem: AVPlayerItem?
    /// La position en attente vient de la progression enregistrée (ouverture,
    /// autre source) et pas d'un changement de qualité : une VOD finie repart
    /// alors du début.
    private var pendingIsResume = false
    /// Direct passé à une autre qualité alors qu'on l'avait reculé exprès :
    /// retard sur le bord à retrouver, une fois le nouvel élément prêt.
    private var pendingBehind: Double?
    /// Échecs : lecture interrompue en route, élément déjà traité (le statut
    /// et la notification arrivent tous deux), relances d'un direct.
    private var failObs: NSObjectProtocol?
    /// Calages de l'élément en cours (minute écoulée) : répétés, la qualité
    /// est trop haute pour le débit (.tuPlaybackStalling).
    private var stallObs: NSObjectProtocol?
    private var stallTimes: [Date] = []
    private var lastStallSignal = Date.distantPast
    private weak var failedItem: AVPlayerItem?
    private var autoReloads = 0
    private var lastAutoReload = Date.distantPast
    /// Pause voulue (bouton, écran verrouillé, PiP) : un direct en échec
    /// n'est alors pas relancé seul, il serait reparti avec le son (jamais
    /// après une pause voulue, comme PlaybackAudio) ; la carte propose
    /// « Réessayer ».
    private var pausedByUser = false
    /// Démonté (vue fermée) : plus rien ne relance ce lecteur ni ne publie
    /// pour lui.
    private var tornDown = false
    private var pip: AVPictureInPictureController?
    /// PiP en cours : il tient la session audio tant qu'il dure. Fermer le
    /// lecteur la relâcherait sous lui, et iOS couperait son son. Rendue à la
    /// fin du PiP, au démontage, ou avec le modèle (le délégué ne reçoit pas
    /// toujours la fin, B9.1).
    private let pipOwner = "pip " + UUID().uuidString
    private var pipHoldsSession = false
    private var lastCatchUp = Date.distantPast
    private var latency = LiveLatencyController()
    private var sync = LiveSyncEstimator()
    private var diagnostics: LiveDiagnostics?

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
    private var spatialObs: NSObjectProtocol?
    /// Appui sur la latence sous le lecteur (.tuGoLive) : retour au direct.
    private var goLiveObs: NSObjectProtocol?
    /// Appel, Siri, autre app qui prend le son : la lecture repart à la fin
    /// (PlaybackInterruptions).
    private var interruptions: PlaybackInterruptions?
    /// Lecteur qui a publié « À l'écoute » en dernier : la fermeture d'un
    /// ancien lecteur, arrivée après l'ouverture du suivant, effaçait ses
    /// infos (écran verrouillé et Centre de contrôle vides quelques secondes).
    private static weak var nowPlayingOwner: ImmersivePlayerModel?

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
        // Journaux LIVE (vitesse et raison, calages, sortie audio) : de quoi
        // vérifier sur appareil qu'un direct ne change plus de vitesse.
        diagnostics = LiveDiagnostics(player: player) { [weak self] in self?.isLive ?? false }
        adBreaks.attach(player)
        load(url: url, seek: savedTime, resume: true)
        // Lecture arrêtée en route sur une erreur (réseau perdu longtemps,
        // segment refusé) : seulement pour l'élément en cours.
        failObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main
        ) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            self?.itemFailed(item, error: note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)
        }
        // Calage (mémoire tampon vide) : le direct prend de l'avance sur le
        // bord, et des calages répétés font baisser la qualité.
        stallObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem else { return }
            self.stalled()
        }
        timeObs = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] t in self?.tick(t) }
        // Pause venue d'ailleurs (appel, casque débranché, fin de la VOD) : le
        // bouton et l'écran verrouillé doivent la refléter, sinon il fallait
        // appuyer deux fois sur lecture. Et l'inverse : une reprise depuis le
        // PiP ne passe pas par setPlaying, le bouton restait sur « lecture ».
        timeControlObs = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            DispatchQueue.main.async {
                guard let self, self.player.currentItem != nil else { return }
                switch p.timeControlStatus {
                case .paused where self.isPlaying:   self.isPlaying = false
                case .playing where !self.isPlaying: self.isPlaying = true
                default: return
                }
                self.refreshNowPlaying(force: true)
                self.updateActivity()
            }
        }
        // Vitesse changée sans nous (récepteur AirPlay qui la refuse, bord d'un
        // enregistrement en cours atteint) : elle devient la vitesse retenue,
        // sinon le menu montrerait une vitesse qui ne joue pas.
        rateObs = NotificationCenter.default.addObserver(
            forName: AVPlayer.rateDidChangeNotification, object: player, queue: .main
        ) { [weak self] note in self?.rateChanged(note) }
        // AirPlay ne lit pas les playlists réécrites : retour à celle du CDN.
        externalObs = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.fallBackForAirPlay() }
        }
        // Son coupé par le bouton ou par la pause pub : l'icône suit.
        mutedObs = player.observe(\.isMuted, options: [.initial, .new]) { [weak self] p, _ in
            let value = p.isMuted
            DispatchQueue.main.async { if self?.muted != value { self?.muted = value } }
        }
        setupRemoteCommands()
        spatialObs = NotificationCenter.default.addObserver(
            forName: .tuSpatialAudioChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.reloadForSpatialAudio() }
        goLiveObs = NotificationCenter.default.addObserver(
            forName: .tuGoLive, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isLive else { return }
            self.goLive()
        }
        interruptions = PlaybackInterruptions(name: "lecteur") { [weak self] since in
            self?.resumeAfterInterruption(since: since)
        }
        interruptions?.watch(player)
    }

    /// Réglage « Audio spatial » changé : l'élément est recréé au même endroit
    /// (rien ne garantit qu'iOS relise ce choix en cours de lecture).
    private func reloadForSpatialAudio() {
        guard let asset = player.currentItem?.asset as? AVURLAsset else { return }
        let wasPlaying = isPlaying
        // Départ encore en attente (reprise, recul d'un direct) : il suit le
        // nouvel élément, `position` vaut encore 0.
        load(url: asset.url, seek: isLive ? 0 : (pendingSeek ?? position),
             resume: pendingSeek != nil && pendingIsResume, behind: pendingBehind ?? heldBehind,
             exact: !isLive)
        if !wasPlaying { setPlaying(false) }
    }

    /// AirPlay ne lit pas les playlists réécrites : retour à celle du CDN
    /// (VodUnmuteLoader). Un départ encore en attente (reprise d'une VOD) suit
    /// le nouvel élément : effacé par `tick` (élément ≠ `loadedItem`), la VOD
    /// repartait de 0:00, et ce 0:00 écrasait la progression enregistrée.
    private func fallBackForAirPlay() {
        guard !tornDown else { return }
        let waiting = pendingSeek != nil
        guard let item = VodUnmuteLoader.fallBackForAirPlay(player, keepPosition: !waiting) else { return }
        loadedItem = item
        observeStatus(item)
    }

    /// Retard sur le bord d'un direct reculé exprès (barre, −10 s) ; nil au
    /// bord, ou hors direct.
    private var heldBehind: Double? {
        guard isLive, latency.holdingBehind, endTime > position else { return nil }
        return endTime - position
    }

    /// Autre qualité du même contenu : une VOD, un clip, une VOD retrouvée ou
    /// téléchargée reprennent à l'endroit lu ; un direct reculé exprès garde
    /// son retard sur le bord, sinon il repart au bord comme avant. Avant,
    /// tout repartait de la progression enregistrée, qui vaut 0 hors VOD de
    /// Twitch, et le recul d'un direct était perdu. Choisie avant que le
    /// départ ne s'applique (élément pas encore prêt), elle garde ce départ :
    /// `position` vaut encore 0, la VOD repartait de 0:00 et cette position
    /// écrasait la reprise.
    func switchQuality(to url: URL) {
        if isLive {
            load(url: url, behind: pendingBehind ?? heldBehind)
        } else {
            load(url: url, seek: pendingSeek ?? position, resume: pendingSeek != nil && pendingIsResume,
                 exact: true)
        }
    }

    /// Calage de l'élément en cours. Deux en une minute (90 s au moins entre
    /// deux signaux) : MainTabView passe en « Auto » ou un cran en dessous.
    private func stalled() {
        if isLive { latency.noteStall() }
        let now = Date()
        stallTimes = stallTimes.filter { now.timeIntervalSince($0) < 60 } + [now]
        // Le calage lui-même est noté par PlaybackDiagnostics.
        if isLive { logger.debug("LIVE", "Avance sur le bord après un calage", "+\(Int(latency.stallMargin)) s") }
        guard stallTimes.count >= 2, now.timeIntervalSince(lastStallSignal) > 90 else { return }
        lastStallSignal = now
        stallTimes = []
        NotificationCenter.default.post(name: .tuPlaybackStalling, object: "immersive")
    }

    /// `resume` : `seek` vient de la progression enregistrée (une VOD finie
    /// repart alors du début). `behind` : direct seulement, retard sur le
    /// bord à retrouver une fois l'élément prêt. `exact` : hors direct, `seek`
    /// est l'endroit voulu (instant visé, autre qualité, relance), appliqué
    /// même sous 5 s — un enregistrement en cours partait sinon de son bord.
    func load(url: URL, seek: Double = 0, isLive: Bool? = nil,
              resume: Bool = false, behind: Double? = nil, exact: Bool = false) {
        if let isLive { self.isLive = isLive }
        stallTimes = []
        // Repart d'une fenêtre vierge : garder les bornes de la source
        // précédente affichait une barre fantaisiste le temps du chargement.
        startTime = 0; endTime = 0; currentDate = nil
        sync.reset()
        // Même modèle pour un changement de qualité ou une bascule direct ↔
        // enregistrement : la tenue du direct repart de zéro (recalage compris).
        latency.reset()
        // Nouvelle source, lancée : plus de reprise en attente, ni de pause
        // voulue (l'appelant la remet s'il le faut).
        interruptions?.settle()
        failed = false
        pausedByUser = false
        if self.isLive { LiveDiagnostics.logAudioRoute("début du direct") }

        // Adresse `tuunmute://` : passages coupés rétablis (VodUnmuteLoader).
        let item = VodUnmuteLoader.playerItem(url: url)
        loadedItem = item
        if seek > 5 {
            pendingSeek = seek
        } else {
            pendingSeek = exact && !self.isLive ? max(0, seek) : nil
        }
        pendingIsResume = resume
        pendingBehind = self.isLive ? behind : nil
        observeStatus(item)
        // Coupé pour une VOD téléchargée en AirPlay (fallBackForAirPlay) :
        // rétabli pour la lecture suivante, sur le même lecteur.
        player.allowsExternalPlayback = true
        player.replaceCurrentItem(with: item)
        // play() rend à la lecture la vitesse par défaut, qui survit au
        // changement d'élément : 1× pour un direct, même après une VOD en
        // accéléré (retour au direct sur le même lecteur).
        player.defaultRate = self.isLive ? 1 : Float(speed)
        player.play()
        // AirPlay déjà actif (autre qualité, relance, bascule direct ↔
        // enregistrement) : l'état ne change pas, l'observateur ne voit rien,
        // et le récepteur ne sait pas lire une adresse maison. Repli tout de suite.
        if player.isExternalPlaybackActive { fallBackForAirPlay() }
        isPlaying = true
        lastCatchUp = Date()   // laisse le flux démarrer avant tout rattrapage
        refreshNowPlaying(force: true)
        updateActivity()
    }

    /// Prêt : le départ en attente s'applique ; en échec : la carte.
    private func observeStatus(_ item: AVPlayerItem) {
        statusObs = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            switch item.status {
            case .readyToPlay: DispatchQueue.main.async { self?.applyPendingSeek(on: item) }
            case .failed:      DispatchQueue.main.async { self?.itemFailed(item, error: item.error) }
            default:           break
            }
        }
    }

    private func applyPendingSeek(on item: AVPlayerItem) {
        guard player.currentItem === item else { return }
        if let behind = pendingBehind {
            pendingBehind = nil
            // Direct reculé exprès, passé à une autre qualité : même retard
            // sur le bord, dans la fenêtre, et tenu — sinon le recalage du
            // démarrage le défaisait. Jamais plus près du bord que visé.
            guard let range = item.seekableTimeRanges.last?.timeRangeValue,
                  range.duration.seconds > 0 else { return }
            let t = max(range.start.seconds, (range.start + range.duration).seconds - behind)
            player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                        toleranceBefore: .positiveInfinity, toleranceAfter: .zero)
            position = t
            latency.hold(true)
            return
        }
        guard let target = pendingSeek else { return }
        pendingSeek = nil
        // Reprise d'une VOD regardée jusqu'au bout (à moins de 30 s de la
        // fin, même règle que le site et le multi-live) : le début. Elle se
        // rouvrait sur sa dernière seconde, et « Tout lire » passait aussitôt
        // à la suivante. Un enregistrement en cours n'a pas de fin : rien.
        let length = item.duration.seconds
        if pendingIsResume, length.isFinite, length > 0, target > length - 30 {
            logger.info("LECTEUR", "VOD déjà vue jusqu'au bout", "reprise au début")
            position = 0
            return
        }
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

    /// Élément en échec. Un direct se relit seul, deux fois au plus par
    /// minute (à 2 puis 4 s) : le flux revient souvent après une coupure.
    /// Sinon, ou pour une VOD, ou si on l'avait mis en pause (il repartirait
    /// seul, avec le son), la vue dit que la lecture s'est arrêtée et propose
    /// « Réessayer » (le lecteur relit alors les liens).
    private func itemFailed(_ item: AVPlayerItem, error: Error?) {
        guard !tornDown, player.currentItem === item, failedItem !== item else { return }
        failedItem = item
        let reason = error?.localizedDescription ?? "?"
        if Date().timeIntervalSince(lastAutoReload) > 60 { autoReloads = 0 }
        if isLive, autoReloads < 2, !pausedByUser, let asset = item.asset as? AVURLAsset {
            autoReloads += 1
            lastAutoReload = Date()
            let attempt = autoReloads
            logger.warn("LECTEUR", "Lecture du direct interrompue", "\(reason) · relance \(attempt)/2")
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt) * 2) { [weak self] in
                guard let self, !self.tornDown, self.player.currentItem === item else { return }
                // Mis en pause entre-temps : pas de relance, la carte.
                guard !self.pausedByUser else {
                    self.showFailure(reason + " · en pause, pas de relance")
                    return
                }
                self.load(url: asset.url)
            }
            return
        }
        // VOD lue telle quelle : un passage coupé listé « -unmuted.ts », que
        // le CDN refuse, l'arrête net. Relancée une fois au même endroit,
        // réécrite sur l'appareil (une adresse déjà réécrite ne change plus :
        // pas de seconde relance).
        if !isLive, let asset = item.asset as? AVURLAsset {
            let safe = VodUnmuteLoader.mutedSafe(asset.url)
            if safe != asset.url {
                // Arrêtée avant que la reprise ne s'applique : le départ en
                // attente, pas `position` (encore 0) — la VOD repartait du
                // début et écrasait la progression enregistrée.
                let at = pendingSeek ?? position
                let resume = pendingSeek != nil && pendingIsResume
                logger.warn("LECTEUR", "VOD interrompue", "\(reason) · relance, passages coupés réécrits")
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.tornDown, self.player.currentItem === item else { return }
                    self.load(url: safe, seek: at, resume: resume, exact: true)
                }
                return
            }
        }
        showFailure(isLive && pausedByUser ? reason + " · en pause, pas de relance" : reason)
    }

    /// « Passer » un passage coupé alors que la lecture s'est arrêtée : un
    /// élément en échec ne cherche plus. Relu juste après, réécrit sur l'appareil.
    func reload(at t: Double) {
        guard let asset = (player.currentItem ?? loadedItem)?.asset as? AVURLAsset else { return }
        load(url: VodUnmuteLoader.mutedSafe(asset.url), seek: t)
    }

    /// La lecture s'est arrêtée : la carte « Réessayer » s'affiche.
    private func showFailure(_ reason: String) {
        logger.warn("LECTEUR", "Lecture interrompue", reason)
        failed = true
        isPlaying = false
        refreshNowPlaying(force: true)
        updateActivity()
    }

    /// Bornes de la barre. La durée d'abord : sur un enregistrement, la
    /// fenêtre cherchable ne couvre au départ que les premières secondes
    /// chargées, et la barre affichait « 0:00 / 0:24 » sur une VOD de
    /// plusieurs heures. Un direct n'a pas de durée finie, il retombe donc
    /// sur la fenêtre.
    private func updateWindow(_ item: AVPlayerItem) {
        let dur = item.duration.seconds
        if dur.isFinite, dur > 0 {
            startTime = 0
            endTime   = dur
        } else if let range = item.seekableTimeRanges.last?.timeRangeValue,
                  range.duration.seconds > 0 {
            startTime = range.start.seconds
            endTime   = (range.start + range.duration).seconds
        }
    }

    private func tick(_ t: CMTime) {
        guard let item = player.currentItem else { return }

        updateWindow(item)
        // Élément remplacé sans nous (repli AirPlay) : la position en attente
        // ne s'y appliquera plus.
        if pendingSeek != nil, item !== loadedItem { pendingSeek = nil }
        // Position en attente (ouverture, autre qualité) : l'élément lit
        // encore 0:00. La garder évite d'enregistrer 0 comme progression le
        // temps du chargement, et de faire sauter la barre au début.
        if t.seconds.isFinite, pendingSeek == nil {
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
        // lui qui sépare le chat de l'image (voir LiveSyncEstimator). Bornes
        // pas encore connues (rechargement, autre qualité) : rien d'envoyé —
        // un nil remettait le retard du chat à 0 une ou deux secondes, et les
        // messages passaient devant l'image.
        if !(isLive && endTime == 0) {
            onBehind(isLive && endTime > position
                     ? sync.offset(latency: total, behind: endTime - position) : nil)
        }
        if isLive { diagnostics?.tick(item: item) }

        // Enregistrement d'un direct en cours lu en accéléré : près de son bord,
        // retour à 1× (rien ne le garantit avant iOS 26.4).
        if speed > 1, player.rate > 1, nearRecordingEdge {
            force(speed: 1, notice: "speed_caught_up", why: "bord de l'enregistrement rattrapé")
        }

        catchUpIfNeeded(item)
    }

    /// Tient le bord du direct par des sauts seulement (LiveLatencyController).
    /// Seuils volontairement larges : viser le bord en permanence fait caler.
    private func catchUpIfNeeded(_ item: AVPlayerItem) {
        // Le recalage du démarrage part dès que la lecture a commencé ; le
        // reste laisse d'abord le flux démarrer (quelques secondes).
        latency.adjust(player: player, item: item, behind: endTime - position,
                       total: currentDate.map { Date().timeIntervalSince($0) },
                       enabled: lowLatency && isLive && isPlaying && endTime > position,
                       settled: Date().timeIntervalSince(lastCatchUp) > 4)
    }

    /// Au bord du direct : à moins de 12 s, ou du recul que le flux
    /// recommande (+ 4 s) s'il est plus grand. Sans faible latence, AVPlayer
    /// se tient à ~18 s du bord d'une playlist Twitch d'origine : « Direct ·
    /// −18 s » restait affiché en permanence au lieu de la durée du live.
    var atLiveEdge: Bool {
        guard isLive else { return false }
        var slack: Double = 12
        if let rec = player.currentItem?.recommendedTimeOffsetFromLive, rec.isValid, rec.isNumeric {
            slack = max(slack, rec.seconds + 4)
        }
        return endTime - position < slack
    }

    func togglePlay() { setPlaying(!isPlaying) }

    func setPlaying(_ on: Bool) {
        // En échec (carte « Réessayer ») : rien ne relance un élément mort —
        // ni « lecture » de l'écran verrouillé ou des écouteurs, ni « Direct ».
        // Le croire en lecture gardait l'écran allumé sans fin, et l'écran
        // verrouillé affichait « en lecture ». « Réessayer » relit les liens.
        if on, failed { return }
        if on { player.play() } else { player.pause() }
        // Pause voulue (bouton, écran verrouillé) : rien ne la relance seul,
        // ni la fin d'une interruption, ni la relance d'un direct en échec.
        if !on { interruptions?.settle() }
        pausedByUser = !on
        isPlaying = on
        refreshNowPlaying(force: true)
        updateActivity()
    }

    func seek(to s: Double, exact: Bool = true) {
        guard endTime > startTime else { return }
        // Direct : jamais plus près du bord que le plancher du retard (4 s
        // affichées, voir LiveLatencyController).
        let ceiling = isLive ? endTime - (player.currentItem.map { latency.minBehind(for: $0) } ?? 6) : endTime
        let clamped = max(startTime, min(max(startTime, ceiling), s))
        // Approché : on peut atterrir avant la position visée (début du
        // segment), jamais après — donc jamais plus près du bord que le plancher.
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: exact ? .zero : .positiveInfinity,
                    toleranceAfter:  .zero)
        position = clamped
        // Recul voulu (barre, −10 s) : la tenue du direct ne doit pas le
        // défaire. Près du bord, elle reprend la main.
        if isLive { latency.hold(ceiling - clamped > 3) }
        refreshNowPlaying(force: true)
        updateActivity()
    }

    func seekBy(_ delta: Double) { seek(to: position + delta) }

    func goLive() {
        // Bornes relues : en pause, `tick` ne tourne plus et le bord du direct
        // a avancé sans elles (longue pause, interruption).
        if let item = player.currentItem { updateWindow(item) }
        // Même recul que la tenue du direct : plus près sur une playlist
        // relue toutes les 2 s (mode faible latence), jamais sous le plancher.
        let back = player.currentItem.map { latency.minBehind(for: $0) } ?? 6
        seek(to: endTime - back, exact: false)
        latency.hold(false)
        if !isPlaying { togglePlay() }
    }

    // MARK: Interruptions
    /// Fin d'une interruption du son (appel, Siri, autre app) : la lecture
    /// repart (voir PlaybackInterruptions). VOD, clip, VOD téléchargée,
    /// enregistrement d'un direct : à l'endroit exact. Direct : au bord, comme
    /// le bouton « Direct » — par un saut, jamais par la vitesse — et relu
    /// après une longue coupure ; reculé exprès, à l'endroit tant que le
    /// direct garde ce moment. Rend ce qui a été fait (journal).
    private func resumeAfterInterruption(since: TimeInterval) -> String? {
        guard let item = player.currentItem, item.status != .failed,
              player.timeControlStatus == .paused else { return nil }
        guard isLive else {
            // VOD finie : rien à reprendre. Un enregistrement encore en cours
            // (rembobinage d'un direct) n'a pas de fin : il repart.
            let length = item.duration.seconds
            if length.isFinite, length > 0, position >= length - 1 { return nil }
            setPlaying(true)
            return String(format: "à %.0f s", position)
        }
        // Recul voulu (barre, −10 s) : testé d'abord, quelle que soit la durée
        // de la coupure. La fenêtre du direct ne garde que ses 30 dernières
        // secondes : après un appel, le moment en est presque toujours sorti,
        // et on revient au bord comme un direct suivi.
        let held = latency.holdingBehind
        if held, LiveLatencyController.stillInWindow(item, after: since) {
            setPlaying(true)
            return "direct, à l'endroit (recul voulu)"
        }
        let lost = held ? " (recul voulu sorti de la fenêtre du direct)" : ""
        if since >= PlaybackInterruptions.longInterruption, let asset = item.asset as? AVURLAsset {
            // App suspendue pendant un long appel : le bord a pu partir sans
            // nous. Nouvel élément, pris au bord (recalage compris).
            load(url: asset.url, seek: 0)
            return "direct relu au bord" + lost
        }
        goLive()
        // goLive ne relance que si `isPlaying` est déjà faux : la pause
        // d'iOS peut ne pas encore avoir été vue.
        setPlaying(true)
        return "direct, au bord" + lost
    }

    // MARK: Vitesse (VODs)
    /// Vitesse voulue, ramenée au cran le plus proche. `defaultRate` d'abord :
    /// play() le restaure (écran verrouillé, PiP, repli AirPlay). L'état réel
    /// du lecteur (`rate ≠ 0`) plutôt que `isPlaying` pour l'appliquer tout de
    /// suite, qui peut être en retard d'un événement.
    func setSpeed(_ value: Double) {
        let v = VodSpeed.nearest(value)
        // Sous 1× : un élément prêt peut dire qu'il ne sait pas ralentir. Avant
        // qu'il le soit, la propriété n'a pas de sens : le refus éventuel
        // arrivera alors par rateDidChange.
        if !isLive, v < 1, let item = player.currentItem, item.status == .readyToPlay,
           !item.canPlaySlowForward {
            force(speed: 1, notice: "speed_unavailable", why: "lecture lente refusée par l'élément")
            return
        }
        speed = v
        guard !isLive else { return }
        player.defaultRate = Float(v)
        if player.rate != 0 { player.rate = Float(v) }
        refreshNowPlaying(force: true)
        updateActivity()
    }

    /// Changement de vitesse venu du lecteur. Les nôtres (setSpeed, play())
    /// donnent la vitesse retenue et ne font rien ici. Comparée au cran : une
    /// vitesse hors cran maintenue par le lecteur ne relance rien. La raison
    /// va au journal (PiP, AirPlay, refus… à départager sur appareil).
    private func rateChanged(_ note: Notification) {
        let rate = Double(player.rate)
        let raw = note.userInfo?[AVPlayer.rateDidChangeReasonKey]
        let reason = (raw as? AVPlayer.RateDidChangeReason)?.rawValue ?? (raw as? String) ?? "?"
        // Pause ou reprise demandée depuis le PiP (ses boutons ne passent pas
        // par setPlaying) : retenue comme celle du bouton.
        if pipActive, reason == AVPlayer.RateDidChangeReason.setRateCalled.rawValue {
            pausedByUser = rate == 0
        }
        let v = VodSpeed.nearest(rate)
        guard !isLive, player.currentItem != nil, rate > 0, abs(v - speed) > 0.01 else { return }
        force(speed: v,
              notice: nearRecordingEdge ? "speed_caught_up" : "speed_unavailable",
              why: String(format: "×%.2f imposé par le lecteur · ", rate) + reason,
              apply: false)
    }

    /// Enregistrement d'un direct en cours (pas de fin déclarée) lu près de
    /// son bord : en accéléré, on finit par le rattraper.
    private var nearRecordingEdge: Bool {
        guard !isLive, let item = player.currentItem, !item.duration.seconds.isFinite,
              endTime > 0 else { return false }
        return endTime - position < 20
    }

    /// Vitesse imposée : elle devient la vitesse retenue (la vue la garde
    /// pour la lecture en cours), sinon re-choisir la vitesse affichée dans le
    /// menu ne ferait rien. `apply` faux quand la vitesse vient du lecteur : elle
    /// est adoptée telle quelle, la reposer arrondie au cran relancerait
    /// rateDidChange sans fin s'il maintient la sienne.
    private func force(speed v: Double, notice: String, why: String, apply: Bool = true) {
        speed = v
        player.defaultRate = Float(v)
        if apply, player.rate != 0, abs(Double(player.rate) - v) > 0.01 { player.rate = Float(v) }
        forcedSpeed = SpeedChange(value: v, notice: notice, id: (forcedSpeed?.id ?? 0) + 1)
        logger.info("LECTEUR", "Vitesse ramenée à " + String(format: "×%g", v), why)
        refreshNowPlaying(force: true)
        updateActivity()
    }

    // MARK: PiP
    func attachPiP(layer: AVPlayerLayer) {
        guard pip == nil, !tornDown, AVPictureInPictureController.isPictureInPictureSupported(),
              let p = AVPictureInPictureController(playerLayer: layer) else { return }
        p.delegate = self
        p.canStartPictureInPictureAutomaticallyFromInline = true
        pip = p
        // Appelé depuis makeUIView, en pleine mise à jour des vues : publier
        // tout de suite donnait « Publishing changes from within view
        // updates » (bouton PiP absent jusqu'au rendu suivant).
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.tornDown else { return }
            self.pipPossible = true
        }
    }

    func togglePiP() {
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() }
        else { pip.startPictureInPicture() }
    }

    /// Session audio prise par le PiP (début) ou rendue (fin, démontage).
    private func holdSessionForPiP(_ on: Bool) {
        guard on != pipHoldsSession else { return }
        pipHoldsSession = on
        if on { PlaybackAudio.shared.claim(pipOwner) } else { PlaybackAudio.shared.release(pipOwner) }
    }

    /// Fin du PiP, rappelée par AVKit ou faite au démontage (une seule fois) :
    /// le chat peut de nouveau se couper, la session audio est rendue.
    private func pipEnded() {
        guard pipActive else { return }
        pipActive = false
        PlayerFullscreen.isActive = false
        holdSessionForPiP(false)
    }

    /// Vue fermée (croix, mini-barre, autre vidéo, chat seul, autre
    /// lecteur) : toujours un démontage complet, PiP compris. Le PiP était
    /// laissé en place, mais le modèle partait avec la vue : son délégué ne
    /// recevait jamais la fin, `PlayerFullscreen.isActive` restait vrai — les
    /// chats ouverts ensuite ne coupaient plus ni IRC, ni PubSub, ni points —
    /// et la Live Activity restait sur l'écran verrouillé. Un PiP qu'on garde
    /// (lecteur réduit, autre onglet, app en arrière-plan) ne passe pas par
    /// ici : la vue reste en place.
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if let pip, pip.isPictureInPictureActive { pip.stopPictureInPicture() }
        pipEnded()
        if let o = timeObs { player.removeTimeObserver(o); timeObs = nil }
        statusObs = nil
        timeControlObs = nil
        pendingSeek = nil
        pendingBehind = nil
        // Lecteur fermé : une fin d'interruption ne doit plus le relancer.
        interruptions = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        adBreaks.detach()
        pip = nil
        holdSessionForPiP(false)
        if let o = spatialObs { NotificationCenter.default.removeObserver(o); spatialObs = nil }
        if let o = goLiveObs { NotificationCenter.default.removeObserver(o); goLiveObs = nil }
        if let o = rateObs { NotificationCenter.default.removeObserver(o); rateObs = nil }
        if let o = failObs { NotificationCenter.default.removeObserver(o); failObs = nil }
        if let o = stallObs { NotificationCenter.default.removeObserver(o); stallObs = nil }
        mutedObs = nil
        clearNowPlaying()
    }

    deinit {
        if let o = timeObs { player.removeTimeObserver(o) }
        if let o = spatialObs { NotificationCenter.default.removeObserver(o) }
        if let o = goLiveObs { NotificationCenter.default.removeObserver(o) }
        if let o = rateObs { NotificationCenter.default.removeObserver(o) }
        if let o = failObs { NotificationCenter.default.removeObserver(o) }
        for (command, target) in remoteTargets { command.removeTarget(target) }
        // Libéré pendant un PiP (lecteur fermé sans démontage) : la session
        // n'est plus tenue par personne d'ici.
        if pipHoldsSession { PlaybackAudio.shared.release(pipOwner) }
        // Libéré sans démontage : ni drapeau du PiP resté vrai, ni « À
        // l'écoute » ni Live Activity orphelins. Un lecteur qui a pris la main
        // entre-temps garde les siens (le lien faible vers celui-ci vaut déjà
        // nil ; vers l'autre, non).
        guard !tornDown else { return }
        if pipActive { PlayerFullscreen.isActive = false }
        if Self.nowPlayingOwner == nil {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            PlayerActivity.end()
        }
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
        // Démonté : rien à montrer (une vue réapparue après coup relançait
        // sinon une Live Activity pour un lecteur arrêté).
        guard !tornDown else { return }
        activityDuration = isLive ? 0 : endTime
        PlayerActivity.update(nowPlaying, isLive: isLive, isPlaying: isPlaying,
                              position: position, duration: activityDuration,
                              rate: isLive ? 1 : speed)
    }

    private func loadArtwork(_ address: String?) {
        artworkTask?.cancel()
        artwork = nil
        guard let address, let url = URL(string: address) else { return }
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data), !Task.isCancelled else { return }
            await MainActor.run {
                // Autre image demandée pendant le téléchargement (raid, autre
                // direct) : celle-ci arrive trop tard. Tester l'annulation
                // avant ce bloc laissait passer l'ancienne miniature.
                guard let self, self.nowPlaying.artworkURL == address else { return }
                self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.refreshNowPlaying(force: true)
            }
        }
    }

    /// iOS fait avancer seul le temps affiché à partir de la vitesse (celle de
    /// la VOD, pas toujours 1×) : on ne réécrit qu'aux changements d'état, et
    /// toutes les 5 s contre la dérive.
    ///
    /// Publié dès qu'un élément se lit, titre connu ou non : sans « À
    /// l'écoute », iOS ne tient pas l'app pour celle qui joue, et le Centre de
    /// contrôle (audio spatial compris) ne la règle pas.
    private func refreshNowPlaying(force: Bool = false) {
        guard player.currentItem != nil else { return }
        guard force || Date().timeIntervalSince(lastNowPlayingUpdate) > 5 else { return }
        lastNowPlayingUpdate = Date()
        Self.nowPlayingOwner = self
        let untitled = nowPlaying.title.isEmpty && nowPlaying.artist.isEmpty
        let rate = isLive ? 1.0 : speed
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: untitled ? "TwitchUnblock" : nowPlaying.title,
            MPMediaItemPropertyArtist: nowPlaying.artist,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
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
        // Un autre lecteur a déjà pris la main : on ne touche pas à ses infos.
        guard Self.nowPlayingOwner == nil || Self.nowPlayingOwner === self else { return }
        Self.nowPlayingOwner = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        // En arrière-plan (raid suivi, VOD suivante), l'activité reste pour
        // le lecteur suivant (voir PlayerActivity.playerRemoved).
        PlayerActivity.playerRemoved()
    }
}

extension ImmersivePlayerModel: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        // Lecteur fermé pendant que le PiP démarrait : il n'a plus rien à
        // montrer, et ne doit rien retenir.
        guard !tornDown else { c.stopPictureInPicture(); return }
        pipActive = true
        PlayerFullscreen.isActive = true   // garde l'IRC et les points actifs
        holdSessionForPiP(true)
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        pipEnded()
    }
}

// MARK: – Lecteur immersif
struct ImmersivePlayer: View {
    let url: URL
    let isLive: Bool
    /// Autorise le rembobinage dans la fenêtre DVR du direct.
    let dvrEnabled: Bool
    let savedTime: Double
    /// Ce qui se lit, quelle que soit la qualité (« live:<chaîne> »,
    /// « vod:<id> »…) : une adresse qui change sans lui est un changement de
    /// qualité, et la lecture reste où elle en est.
    var contentID: String = ""
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
    /// Multi-live et rembobinage, quand c'est possible : boutons de la barre
    /// du bas s'ils y sont mis (Réglages → Personnaliser).
    var onMultiLive: (() -> Void)? = nil
    var multiLiveOn = false
    var multiLiveFull = false
    var onRewind: (() -> Void)? = nil
    /// Titre, chaîne et image affichés sur l'écran verrouillé.
    var nowPlaying = NowPlayingMeta()
    /// Vitesse voulue hors direct : celle des VODs, retenue (store.vodSpeed),
    /// ou celle du clip en cours. Ignorée en direct.
    var speed: Double = 1
    /// Vitesse imposée par le lecteur (refus, AirPlay, bord du DVR) : le parent
    /// la réécrit dans la préférence, seule source de vérité.
    var onSpeedChange: (Double) -> Void = { _ in }
    /// Annonce brève au lancement (direct servi par le compte, sans pub).
    var notice: String? = nil

    var onProgress: (Double) -> Void = { _ in }
    var onLatency:  (Double?) -> Void = { _ in }
    var onBehind:   (Double?) -> Void = { _ in }
    /// Lecture en cours ou non (pause, échec) : le parent n'empêche la mise
    /// en veille de l'écran que pendant la lecture.
    var onPlaying:  (Bool) -> Void = { _ in }
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
    /// Direct en paysage : le double-tap affiche ou masque le chat ; rend le
    /// nouvel état, pour le bandeau.
    var onToggleChatVisibility: () -> LandscapeChat = { .hidden }
    var onSleep:    () -> Void = {}

    @EnvironmentObject private var store: AppStore
    @StateObject private var model: ImmersivePlayerModel
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>? = nil
    /// Touchers sur l'image (voir `tap`) : le précédent, l'état des commandes
    /// avant lui, et une série de doubles-tapes en cours.
    @State private var lastTapAt = Date.distantPast
    @State private var lastTapZone: TapZone? = nil
    @State private var controlsBeforeTap = true
    @State private var tapStreak = false
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
    /// Effacement prévu du bandeau fugace : un seul à la fois.
    @State private var flashTask: Task<Void, Never>? = nil
    /// Contenu chargé dans le modèle (voir `contentID`).
    @State private var shownContent = ""
    /// Instant visé avant la fenêtre du direct (barre « toute la diffusion »),
    /// appliqué tel quel à l'enregistrement quand il arrive. Passé par la
    /// seule progression enregistrée, un instant proche du début était ignoré
    /// (sous 5 s) : l'enregistrement en cours partait de son bord, le présent.
    @State private var archiveTarget: Double? = nil
    /// Secondes cumulées des doubles-tapes rapprochés, pour afficher « +30 s »
    /// au troisième plutôt que trois fois « +10 s » sans savoir où l'on est.
    @State private var seekTotal: Double = 0
    @State private var seekResetTask: Task<Void, Never>? = nil
    /// Liste des chapitres ouverte (feuille : ne se referme pas toute seule).
    @State private var showChapters = false
    /// Fiche du direct ou de la VOD (titre en entier, catégorie…), ouverte en
    /// touchant le titre ; « Voir la chaîne » l'ouvre une fois la fiche fermée.
    @State private var showInfo = false
    @State private var channelAfterInfo = false
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
    /// Revient seul à faux, même si le geste est interrompu (Centre de
    /// contrôle, appel) : remis à faux dans onEnded seulement, il bloquait
    /// ensuite le glissé vers le bas.
    @GestureState private var pinching = false

    init(url: URL, isLive: Bool, dvrEnabled: Bool, savedTime: Double,
         contentID: String = "",
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
         speed: Double = 1,
         onSpeedChange: @escaping (Double) -> Void = { _ in },
         notice: String? = nil,
         onProgress: @escaping (Double) -> Void = { _ in },
         onLatency:  @escaping (Double?) -> Void = { _ in },
         onBehind:   @escaping (Double?) -> Void = { _ in },
         onPlaying:  @escaping (Bool) -> Void = { _ in },
         onPull:     @escaping (CGFloat) -> Void = { _ in },
         onPullEnd:  @escaping (CGFloat, CGFloat) -> Void = { _, _ in },
         onReduce:   @escaping () -> Void = {},
         onClose:    @escaping () -> Void = {},
         onMenu:     @escaping () -> Void = {},
         onRefresh:  @escaping () -> Void = {},
         onToggleChat: @escaping () -> Void = {},
         onToggleChatVisibility: @escaping () -> LandscapeChat = { .hidden },
         onSleep:    @escaping () -> Void = {},
         onBackToLive: @escaping () -> Void = {},
         onSeekToArchive: @escaping (Double) -> Void = { _ in },
         onMultiLive: (() -> Void)? = nil,
         multiLiveOn: Bool = false,
         multiLiveFull: Bool = false,
         onRewind: (() -> Void)? = nil) {
        self.url = url; self.isLive = isLive; self.dvrEnabled = dvrEnabled
        self.savedTime = savedTime; self.contentID = contentID
        self.info = info; self.onChannel = onChannel
        self.onProgress = onProgress; self.onLatency = onLatency
        self.onBehind = onBehind; self.onPlaying = onPlaying
        self.onPull = onPull; self.onPullEnd = onPullEnd
        self.sleepLabel = sleepLabel; self.chatMode = chatMode
        self.isLandscape = isLandscape; self.controlsInset = controlsInset
        self.fillScreen = fillScreen; self.canReturnToLive = canReturnToLive
        self.streamStartedAt = streamStartedAt; self.archiveAvailable = archiveAvailable
        self.chapters = chapters; self.nowPlaying = nowPlaying
        self.speed = speed; self.onSpeedChange = onSpeedChange; self.notice = notice
        self.mutedRanges = mutedRanges; self.unmutedCount = unmutedCount
        self.onReduce = onReduce; self.onClose = onClose
        self.onMenu = onMenu; self.onRefresh = onRefresh
        self.onToggleChat = onToggleChat; self.onSleep = onSleep
        self.onToggleChatVisibility = onToggleChatVisibility
        self.onBackToLive = onBackToLive; self.onSeekToArchive = onSeekToArchive
        self.onMultiLive = onMultiLive; self.multiLiveOn = multiLiveOn
        self.multiLiveFull = multiLiveFull; self.onRewind = onRewind
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
    /// normalement, avant elle on passe la main à l'enregistrement. Au bout de
    /// la barre (aimanté sur quelques secondes) : le direct, comme le bouton
    /// « Direct ». La fenêtre s'arrête avant la fin de la barre (délai de
    /// publication de Twitch), et ramener le curseur à droite ouvrait la VOD
    /// en cours à sa fin.
    private func seekBroadcast(to target: Double, span: BroadcastSpan) {
        if target >= span.windowEnd - 3 {
            model.goLive()
        } else if target >= span.windowStart {
            // `span.playhead`, pas `model.position` : le repère est celui de la
            // prise du curseur. La lecture a continué pendant le glissement, et
            // s'appuyer sur la position courante décalait l'arrivée d'autant.
            model.seek(to: span.playhead + (target - span.current))
        } else {
            logger.info("LECTEUR", "Rembobinage hors fenêtre DVR",
                        String(format: "→ %.0f s depuis le début", target))
            archiveTarget = target
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
            // En paysage la surface va jusqu'en haut et en bas de l'écran
            // (indicateur d'accueil compris) : l'image reste centrée sur l'écran
            // réel. Sur les côtés, elle s'arrête à la zone sûre : jusqu'au bord
            // physique, une image plus étroite que l'écran (chat en colonne)
            // passait sous la Dynamic Island ou l'encoche. Centrée en 16:9, elle
            // n'y va pas (bandes égales sur les côtés, l'île dans l'une). Seul
            // « Remplir l'écran » va jusqu'aux bords, île comprise.
            //
            // En portrait, jamais : la boîte est déjà en 16:9, déborder ne
            // faisait que la rendre plus haute que large et rogner les côtés.
            .ignoresSafeArea(isLandscape ? SafeAreaRegions.all : [],
                             edges: isLandscape && !croppingFill ? .vertical : .all)

            // Double-tap ±10 s, en VOD seulement. En direct, avancer n'a pas
            // de sens (on est au bord, ou presque) : en paysage, le double-tap
            // affiche ou masque le chat, et le bouton « Direct » des commandes
            // ramène au bord après une pause ou un retard.
            if !isLive {
                HStack(spacing: 0) {
                    tapZone(.back)
                    tapZone(.forward)
                }
            } else if isLandscape {
                tapZone(.chat)
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

            // Lecture arrêtée sur une erreur : on le dit, avec de quoi relancer
            // (le lecteur relit alors les liens). Visible commandes masquées.
            if model.failed { failureCard }

            // Passage dont Twitch a coupé le son : on le dit (sinon on croit à
            // une panne) et on propose de le sauter.
            if let muted = currentMuted {
                mutedNotice(muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, showControls ? 58 : TSpace.sm)
                    .padding(.trailing, controlsInset)
                    .transition(.opacity)
            }

            // Pause pub de la chaîne (direct) : on dit ce qu'est cet écran et
            // quand le direct revient ; le son est coupé pendant ce temps.
            AdBreakBanner(watcher: model.adBreaks)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, showControls ? 58 : TSpace.sm)
                .padding(.horizontal, TSpace.md)
                .padding(.trailing, controlsInset)
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
        .onTapGesture { tap(.plain) }
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
        // Même contenu, autre qualité : la lecture reste où elle en est
        // (voir switchQuality).
        .onChange(of: url) { newURL in
            if !contentID.isEmpty, contentID == shownContent, isLive == model.isLive {
                model.switchQuality(to: newURL)
                return
            }
            shownContent = contentID
            let wasLive = model.isLive
            if wasLive, !isLive, let target = archiveTarget {
                // Instant visé sur la barre : même au tout début.
                model.load(url: newURL, seek: target, isLive: false, exact: true)
            } else {
                model.load(url: newURL, seek: savedTime, isLive: isLive, resume: true)
            }
            archiveTarget = nil
            // Bascule sur l'enregistrement : la vitesse retenue s'y applique.
            // Pas à un changement de qualité ou de source d'une VOD.
            if wasLive, !isLive, model.speed != 1 { flash(speedFlash) }
        }
        // La boîte change du tout au tout : on repart de l'image entière.
        .onChange(of: isLandscape) { _ in resetZoom() }
        .onAppear {
            shownContent = contentID
            // Sans condition : le modèle sait s'il lit un direct (la tenue du
            // bord ne joue qu'en direct). Fixé à faux par une vue ouverte sur
            // l'enregistrement, il le restait au retour au direct.
            model.lowLatency = store.lowLatency
            model.setNowPlaying(nowPlaying)
            // L'élément se charge encore : rien n'a joué à 1×. Une vitesse
            // retenue est annoncée, elle ne doit pas surprendre.
            model.setSpeed(speed)
            if !isLive, model.speed != 1 { flash(speedFlash, duration: 1_500_000_000) }
            if let notice { flash(notice, duration: 2_500_000_000) }
            scheduleAutoHide()
            onPlaying(model.isPlaying)
        }
        .onChange(of: model.isPlaying) { onPlaying($0) }
        .onChange(of: notice) { n in
            if let n { flash(n, duration: 2_500_000_000) }
        }
        // Vitesse choisie dans le menu ⋯. Égale à celle du modèle : c'est la
        // réécriture d'une vitesse imposée, déjà annoncée.
        .onChange(of: speed) { v in
            let echo = VodSpeed.nearest(v) == model.speed
            model.setSpeed(v)
            if !echo, !isLive { flash(speedFlash) }
        }
        .onChange(of: model.forcedSpeed) { change in
            guard let change else { return }
            onSpeedChange(change.value)
            flash(store.t(change.notice), duration: 2_500_000_000)
        }
        .onChange(of: nowPlaying) { model.setNowPlaying($0) }
        // Son rétabli sur des passages coupés : on le signale une fois.
        .onChange(of: unmutedCount) { n in
            if n > 0 { flash(store.t("vod_unmuted"), duration: 2_500_000_000) }
        }
        .animation(.easeInOut(duration: 0.2), value: currentMuted)
        .onChange(of: store.lowLatency) { model.lowLatency = $0 }
        .onDisappear {
            hideTask?.cancel()
            flashTask?.cancel()
            // Pas de retour au portrait ici : la vue disparaît aussi à chaque
            // relance (⟳, « Réessayer », raid suivi, VOD suivante), et le
            // lecteur suivant s'ouvrait en portrait malgré le paysage forcé.
            // La fermeture, la réduction et le chat seul s'en chargent
            // (MainTabView).
            // Toujours démonté, PiP compris : la vue ne disparaît que quand
            // on ferme le lecteur ou qu'on passe à autre chose (voir
            // ImmersivePlayerModel.teardown). Réduit ou en arrière-plan, elle
            // reste en place et le PiP continue.
            model.teardown()
        }
        // Attachée à la racine : la feuille reste ouverte même quand les
        // commandes se masquent (un Menu dans la barre se refermait avec elle).
        .sheet(isPresented: $showChapters, onDismiss: { scheduleAutoHide() }) {
            chaptersSheet
        }
        .sheet(isPresented: $showInfo, onDismiss: {
            let openChannel = channelAfterInfo
            channelAfterInfo = false
            if openChannel { onChannel?() } else { scheduleAutoHide() }
        }) {
            infoSheet
        }
    }

    // ── Fiche : le titre en entier (coupé dans la barre du haut) ──────
    @ViewBuilder private var infoSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text(info.title.isEmpty ? info.channel : info.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.tText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .listRowBackground(Color.tCard)
                if !info.game.isEmpty || info.viewers > 0 || !info.uptime.isEmpty {
                    Section {
                        if !info.game.isEmpty { infoRow("gamecontroller.fill", info.game) }
                        if info.viewers > 0 {
                            infoRow("eye.fill", "\(formatViewers(info.viewers)) \(store.tn("viewers", info.viewers, abbreviated: info.viewers >= 1000))")
                        }
                        if !info.uptime.isEmpty { infoRow("clock.fill", info.uptime) }
                    }
                    .listRowBackground(Color.tCard)
                }
                if onChannel != nil {
                    Section {
                        Button {
                            channelAfterInfo = true
                            showInfo = false
                        } label: {
                            Label(store.t("see_channel"), systemImage: "person.crop.square")
                                .foregroundColor(.tPrimary)
                        }
                    }
                    .listRowBackground(Color.tCard)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.tDark)
            .navigationTitle(info.channel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(store.t("close")) { showInfo = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private func infoRow(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text).foregroundColor(.tText)
        } icon: {
            Image(systemName: icon).foregroundColor(.tMuted)
        }
        .font(.system(size: 15))
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
            // Voile : rend le texte lisible sur une image claire. Il porte les
            // mêmes doubles-tapes que l'image (il la couvre tant que les
            // commandes sont affichées : le premier toucher les masquait, et
            // le double-tap ne faisait rien).
            LinearGradient(colors: [.black.opacity(0.65), .black.opacity(0.15),
                                    .black.opacity(0.65)],
                           startPoint: .top, endPoint: .bottom)
                .overlay { controlsTapLayer }
                // En paysage, l'image descend jusqu'aux bords physiques : le
                // voile suit. Sinon il s'arrêtait à la zone sûre et laissait
                // une bande de vidéo en pleine lumière au-dessus et en dessous.
                .ignoresSafeArea(isLandscape ? SafeAreaRegions.all : [], edges: .vertical)

            // Play / pause au centre — centré sur la partie visible de l'image,
            // pas sur l'écran entier : le chat superposé en masque la droite.
            // En échec, la carte « Réessayer » prend sa place.
            if !model.failed {
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
            }

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

                // Nom en clair, titre estompé : le nom prime. Toucher le nom
                // ouvre la chaîne ; le titre (souvent coupé), sa fiche.
                if info.title.isEmpty {
                    Text(info.channel).font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { onChannel?() }
                } else {
                    HStack(spacing: 0) {
                        Text(info.channel).font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .layoutPriority(1)
                            .contentShape(Rectangle())
                            .onTapGesture { onChannel?() }
                        Text("  \(info.title)").font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.65))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                hideTask?.cancel()
                                showInfo = true
                            }
                            .accessibilityAddTraits(.isButton)
                    }
                }

                // AirPlay : envoyer la vidéo vers une Apple TV ou une TV
                // compatible. Masquable (Réglages → Personnaliser).
                if store.customization.shows(player: "airplay") {
                    AirPlayButton()
                        .frame(width: 32, height: 32)
                        .tGlass(in: Circle(), fallback: Color.black.opacity(0.4), clear: true)
                }
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
                    // Au bord : point rouge et durée du live. En retard (pause,
                    // coupure, retour en arrière), un vrai bouton « Direct » avec
                    // le retard, qui ramène au bord — le point grisé d'avant
                    // passait inaperçu.
                    Button {
                        model.goLive(); scheduleAutoHide()
                    } label: {
                        if model.atLiveEdge && model.isPlaying {
                            HStack(spacing: TSpace.xs) {
                                Circle().fill(Color.tLive).frame(width: 7, height: 7)
                                Text(info.uptime.isEmpty ? store.t("live_on") : info.uptime)
                                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            }
                            .foregroundColor(.white)
                        } else {
                            HStack(spacing: TSpace.xs) {
                                Image(systemName: "forward.end.fill").font(.system(size: 10, weight: .bold))
                                Text(store.t("back_to_live") + lateLabel(model.endTime - model.position))
                                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, TSpace.sm)
                            .frame(height: 28)
                            .background(Color.tLive.opacity(0.85))
                            .clipShape(Capsule())
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(store.t("back_to_live"))

                    if info.viewers > 0 {
                        overlayMeta(icon: "eye.fill", text: formatViewers(info.viewers))
                    }
                    // Un appui sur la latence ramène au bord, comme « Direct ».
                    if store.showLatency, let l = info.latency {
                        Button { model.goLive(); scheduleAutoHide() } label: {
                            overlayMeta(icon: "waveform.path.ecg",
                                        text: String(format: "%.0f s", max(0, l)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(store.t("back_to_live"))
                    }
                } else {
                    // Pendant un glissement, l'instant visé plutôt que la
                    // position courante (en violet : ce n'est pas encore lu).
                    HStack(spacing: 0) {
                        Text("\(timeLabel(dragging ? dragValue : model.position)) / \(timeLabel(model.endTime))")
                            .foregroundColor(dragging ? .tPurple : .white)
                        // Vitesse retenue d'une VOD à l'autre : toujours visible
                        // quand elle n'est pas normale.
                        if model.speed != 1 {
                            Text(" · " + VodSpeed.label(model.speed, store.lang))
                                .foregroundColor(.white)
                                .accessibilityLabel(store.t("speed") + " " + VodSpeed.label(model.speed, store.lang))
                        }
                    }
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
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

                // Son, PiP, recharger, chat, rotation… dans l'ordre choisi
                // (Réglages → Personnaliser), chacun seulement quand il sert.
                ForEach(barButtons, id: \.self) { key in
                    barButton(key)
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
                let after = model.endTime > 0 ? min(r.end + 0.5, model.endTime) : r.end + 0.5
                // Lecture arrêtée (élément en échec) : chercher ne fait plus
                // rien, on relit juste après le passage.
                if model.failed { model.reload(at: after) } else { model.seek(to: after) }
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

    /// Lecture arrêtée sur une erreur (ImmersivePlayerModel.failed) :
    /// « Réessayer » relit les liens, comme ⟳.
    private var failureCard: some View {
        VStack(spacing: TSpace.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.tWarning)
            Text(store.t("player_failed"))
                .font(.system(size: 14, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { onRefresh() } label: {
                Text(store.t("retry"))
                    .font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 16).frame(height: 34)
                    .background(Capsule().fill(Color.tPrimary))
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(.white)
        .padding(TSpace.md)
        .frame(maxWidth: 300)
        .background(Color.black.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Centrée sur la partie visible de l'image, comme ▶ (chat superposé).
        .offset(x: -controlsInset / 2)
        .transition(.opacity)
    }

    /// Touchers du voile des commandes : mêmes zones que sur l'image (±10 s en
    /// VOD, chat en paysage pendant un direct), voir `tap`.
    @ViewBuilder private var controlsTapLayer: some View {
        if !isLive {
            HStack(spacing: 0) {
                tapZone(.back)
                tapZone(.forward)
            }
        } else {
            tapZone(isLandscape ? .chat : .plain)
        }
    }

    /// Ce qu'un double-tap fait à cet endroit de l'image.
    private enum TapZone { case back, forward, chat, plain }

    private func tapZone(_ zone: TapZone) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { tap(zone) }
    }

    /// Un toucher agit aussitôt (commandes affichées ou masquées). Avec un
    /// double-tap reconnu par SwiftUI, chaque simple toucher attendait de
    /// savoir si un second suivait : en paysage pendant un direct et en VOD,
    /// les commandes mettaient près d'une seconde à répondre. Le double-tap se
    /// déduit donc de l'écart : un second toucher au même endroit dans les
    /// 0,3 s remet les commandes comme avant le premier et fait son action
    /// (±10 s, chat) ; en VOD les suivants l'enchaînent (+20 s, +30 s…).
    private func tap(_ zone: TapZone) {
        let now = Date()
        let quick = zone != .plain && zone == lastTapZone && now.timeIntervalSince(lastTapAt) < 0.3
        lastTapAt = now
        lastTapZone = zone
        guard quick else {
            tapStreak = false
            controlsBeforeTap = showControls
            toggleControls()
            return
        }
        if !tapStreak {
            tapStreak = true
            if showControls != controlsBeforeTap { toggleControls() }
        }
        switch zone {
        case .back:    model.seekBy(-10); accumulateSeek(-10)
        case .forward: model.seekBy(10); accumulateSeek(10)
        case .chat:
            toggleChatVisibility()
            // Une bascule par double-tap : le toucher suivant repart de zéro.
            lastTapAt = .distantPast
        case .plain:   break
        }
        if showControls { scheduleAutoHide() }
    }

    /// Direct en paysage : chat affiché ou masqué, et le nouvel état annoncé.
    private func toggleChatVisibility() {
        let mode = onToggleChatVisibility()
        flash(store.t(mode.labelKey))
    }

    /// Boutons affichés de la barre du bas, dans l'ordre choisi.
    private var barButtons: [String] {
        let c = store.customization
        return c.playerButtons.filter { c.shows(player: $0) }
    }

    /// Un bouton de la barre du bas (clés de UICustomization.defaultPlayer) ;
    /// rien quand il ne sert pas ici.
    @ViewBuilder
    private func barButton(_ key: String) -> some View {
        switch key {
        case "mute":
            // Couper / remettre le son, sans toucher au volume du téléphone.
            overlayButton(icon: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                model.toggleMute()
                flash(store.t(model.player.isMuted ? "player_muted" : "player_unmuted"))
                scheduleAutoHide()
            }
        case "pip":
            if model.pipPossible {
                overlayButton(icon: "pip.enter") { model.togglePiP(); scheduleAutoHide() }
            }
        case "refresh":
            overlayButton(icon: "arrow.clockwise") { onRefresh() }
        case "chat":
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
        case "rotate":
            // Bascule portrait / paysage. Le même bouton fait l'aller ET le
            // retour : sans ça, un téléphone dont la rotation est verrouillée
            // reste coincé en paysage.
            overlayButton(icon: isLandscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate") {
                toggleOrientation(); scheduleAutoHide()
            }
        case "sleep":
            // Minuteur en cours : sa pastille, plus à gauche, en tient lieu.
            if sleepLabel == nil {
                overlayButton(icon: "moon.zzz") { onSleep(); scheduleAutoHide() }
            }
        case "multi":
            if let onMultiLive {
                overlayButton(icon: multiLiveOn ? "minus.square" : "square.grid.2x2") {
                    let done = multiLiveOn ? "multi_removed" : (multiLiveFull ? "multi_full" : "multi_added")
                    onMultiLive()
                    flash(store.t(done))
                    scheduleAutoHide()
                }
            }
        case "rewind":
            if let onRewind {
                overlayButton(icon: "gobackward") { onRewind(); scheduleAutoHide() }
            }
        default:
            EmptyView()
        }
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
            .updating($pinching) { _, active, _ in active = true }
            .onChanged { value in
                zoom = min(max(zoomBase * value, 1), 4)
                pan = clampedPan(pan)
            }
            .onEnded { _ in
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

    /// Retard sur le direct, à côté de « Direct » : « · −45 s », « · −2:05 » ;
    /// rien sous 15 s (une pause à peine commencée).
    private func lateLabel(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded())
        guard s >= 15 else { return "" }
        return s >= 60 ? " · −\(s / 60):\(String(format: "%02d", s % 60))" : " · −\(s) s"
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

    /// « Vitesse 1,5× », annoncé au changement et à l'ouverture. 1× se dit
    /// « Normale », comme dans le menu ⋯.
    private var speedFlash: String {
        store.t("speed") + " " + (model.speed == 1 ? store.t("speed_normal")
                                                    : VodSpeed.label(model.speed, store.lang))
    }

    /// Bandeau fugace au centre de l'image (±10 s, changement de mode du chat).
    /// Un seul effacement en attente : celui d'un bandeau précédent effaçait
    /// aussi le suivant, trop tôt (deux doubles-tapes à 0,5 s d'écart :
    /// « +20 s » disparaissait au bout de 0,4 s).
    private func flash(_ text: String, duration: UInt64 = 700_000_000) {
        withAnimation(.easeOut(duration: 0.15)) { seekFlash = text }
        flashTask?.cancel()
        flashTask = Task {
            try? await Task.sleep(nanoseconds: duration)
            guard !Task.isCancelled else { return }
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
        PlayerOrientation.forcedLandscape = target == .landscapeRight
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { error in
            logger.warn("LECTEUR", "Rotation refusée", error.localizedDescription)
        }
        // Sans ça, iOS peut garder l'ancienne orientation tant qu'aucune vue
        // ne redemande la mise à jour.
        UIViewController.attemptRotationToDeviceOrientation()
    }
}

/// Paysage demandé par le bouton de rotation du lecteur. Avec la rotation
/// verrouillée, l'app restait couchée une fois le lecteur fermé ou réduit :
/// sur iPhone, elle revient alors au portrait. L'iPad, ou un téléphone
/// simplement tourné (rotation libre), garde son orientation. Appelé
/// seulement depuis l'interface (fil principal).
enum PlayerOrientation {
    static var forcedLandscape = false

    static func restorePortraitIfForced() {
        guard forcedLandscape else { return }
        forcedLandscape = false
        guard UIDevice.current.userInterfaceIdiom == .phone,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              scene.effectiveGeometry.interfaceOrientation.isLandscape else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { error in
            logger.warn("LECTEUR", "Retour au portrait refusé", error.localizedDescription)
        }
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

// MARK: – Pause pub de la chaîne
/// Bandeau d'une pause pub cousue par Twitch (AdBreakWatcher) : ce qu'est
/// l'écran violet, et dans combien de temps le direct revient. Rien hors
/// pause. `compact` : une ligne, pour les tuiles du multi-live.
struct AdBreakBanner: View {
    @ObservedObject var watcher: AdBreakWatcher
    var compact = false

    @EnvironmentObject private var store: AppStore

    /// Pas de session web, ou réglage coupé : un abonné ne profite pas de son
    /// abonnement sans pub, on le lui dit.
    private var showsLoginHint: Bool {
        !store.subAdFree || (store.twitchWebToken ?? "").isEmpty
    }

    var body: some View {
        if let left = watcher.remaining {
            Group {
                if compact {
                    HStack(spacing: 5) {
                        Image(systemName: "megaphone.fill").font(.system(size: 10, weight: .bold))
                        Text(store.t("ad_break_short").replacingOccurrences(of: "{n}", with: "\(left)"))
                            .font(.system(size: 11, weight: .bold))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "megaphone.fill").font(.system(size: 12, weight: .bold))
                            Text(store.t("ad_break_title")).font(.system(size: 13, weight: .bold))
                        }
                        Text(store.t("ad_break_sub").replacingOccurrences(of: "{n}", with: "\(left)"))
                            .font(.system(size: 12, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        if showsLoginHint {
                            Text(store.t("ad_break_login_hint"))
                                .font(.system(size: 11))
                                .opacity(0.75)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(maxWidth: 360, alignment: .leading)
                    .background(Color.black.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.tPurple.opacity(0.6), lineWidth: 1))
                }
            }
            .foregroundColor(.white)
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
        }
    }
}
