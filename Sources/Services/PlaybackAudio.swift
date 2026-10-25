import AVFoundation
import UIKit
#if os(iOS)
import CallKit
#endif

// ═══════════════════════════════════════════════════════════════════════════
//  Session audio de la lecture.
//
//  Catégorie `.playback`, mode `.moviePlayback`, réglée au lancement : le son
//  continue écran verrouillé et dans une autre app ; le PiP et AirPlay en ont
//  besoin. La session, elle, n'est activée qu'à l'ouverture d'un lecteur :
//  activée dès le lancement, elle coupait la musique des autres apps à la
//  simple ouverture de l'app, sans rien lire. À la fermeture du dernier
//  lecteur, elle est relâchée en prévenant les autres apps
//  (`notifyOthersOnDeactivation`) : une musique coupée par la vidéo peut
//  reprendre.
//
//  Interruptions (appel, Siri, alarme, autre app qui prend le son) : voir
//  PlaybackInterruptions, plus bas. Fichier partagé avec l'Apple TV, qui
//  n'en utilise que les interruptions.
// ═══════════════════════════════════════════════════════════════════════════
final class PlaybackAudio {
    static let shared = PlaybackAudio()

    /// Activer ou relâcher la session bloque le temps qu'iOS réponde : jamais
    /// sur le fil principal.
    private let queue = DispatchQueue(label: "tu.audio.session")
    // Tenus sur `queue` seulement.
    /// Détenteurs : « player » (écran du lecteur), « multi » (multi-live), et
    /// le PiP du lecteur immersif tant qu'il dure : fermer le lecteur ne doit
    /// pas relâcher la session sous un PiP qui joue.
    private var owners = Set<String>()
    /// Dernière demande : une relâche prévue n'a lieu que si aucun lecteur ne
    /// s'est ouvert entre-temps.
    private var generation = 0
    /// Minuteur de veille : la relâche ne réveillera pas les autres apps, même
    /// si un PiP la fait attendre. Oublié à l'ouverture suivante.
    private var quiet = false
    /// Relâche prévue qui préviendra les autres apps. Un aperçu de Découvrir
    /// lancé avant qu'elle n'ait lieu la reporte : c'est alors la fin de
    /// l'aperçu qui les prévient — relâchée sans, une musique coupée par la
    /// vidéo ne reprenait jamais seule.
    private var wakeOthersPending = false

    private init() {}

    /// Au lancement : la catégorie seulement, sans activer la session.
    static func configure() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        } catch {
            logger.warn("LECTEUR", "Session audio : catégorie refusée", error.localizedDescription)
        }
    }

    /// Un lecteur s'ouvre : le son passe à l'app (celui des autres apps
    /// s'arrête, comme pour toute vidéo).
    func claim(_ owner: String) {
        queue.async { [self] in
            owners.insert(owner)
            generation += 1
            quiet = false
            wakeOthersPending = false
            // Catégorie des lecteurs reposée à chaque ouverture : les aperçus
            // muets de Découvrir passent en « ambient », qui se tait en mode
            // silencieux — un lecteur ouvert juste après restait sans son.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                // Appel en cours, par exemple : AVPlayer la redemandera en jouant.
                logger.warn("LECTEUR", "Session audio refusée", error.localizedDescription)
            }
        }
    }

    /// Un lecteur se ferme. Au dernier, la session est relâchée un peu plus
    /// tard : passer du multi-live au lecteur (ou l'inverse) ferme l'un juste
    /// avant d'ouvrir l'autre, et la musique des autres apps ne doit pas
    /// reprendre le temps d'un éclair. `notifyOthers` faux (minuteur de
    /// veille) : la session est rendue sans réveiller la musique d'une autre
    /// app.
    func release(_ owner: String, notifyOthers: Bool = true) {
        queue.async { [self] in
            guard owners.remove(owner) != nil else { return }
            if !notifyOthers { quiet = true }
            guard owners.isEmpty else { return }
            generation += 1
            let wanted = generation
            let notify = !quiet
            quiet = false
            wakeOthersPending = notify
            queue.asyncAfter(deadline: .now() + 1.5) { [self] in
                deactivate(notifyOthers: notify, generation: wanted)
            }
        }
    }

    /// Aperçus muets (onglet Découvrir). `on` : catégorie « ambient », la
    /// musique d'une autre app continue ; jamais quand un lecteur tient la
    /// session. `off` : la session est relâchée PUIS la catégorie des lecteurs
    /// reposée — changer la catégorie d'une session active coupait la musique
    /// des autres apps.
    func previewAmbient(_ on: Bool) {
        queue.async { [self] in
            guard owners.isEmpty else { return }
            let session = AVAudioSession.sharedInstance()
            if on {
                // Une relâche prévue (lecteur fermé à l'instant) n'arrête pas
                // l'aperçu : elle attend sa fin (`wakeOthersPending`).
                generation += 1
                try? session.setCategory(.ambient, mode: .default)
            } else if wakeOthersPending {
                // Relâche du lecteur reportée par l'aperçu : elle repart, en
                // prévenant les autres apps, avec le même délai (un lecteur
                // qui s'ouvre aussitôt l'annule, sans réveil d'un instant).
                generation += 1
                let wanted = generation
                queue.asyncAfter(deadline: .now() + 1.5) { [self] in
                    guard wanted == generation, owners.isEmpty else { return }
                    deactivate(notifyOthers: true, generation: wanted)
                    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                }
            } else {
                try? session.setActive(false)
                try? session.setCategory(.playback, mode: .moviePlayback)
            }
        }
    }

    /// Lecture en pause depuis longtemps en arrière-plan (PlaybackYield,
    /// iPhone) : la session est rendue sans réveiller la musique des autres
    /// apps, si seul le lecteur la tient (ni PiP, ni multi-live, ni aperçu).
    /// Il en reste le détenteur : en repartant, AVPlayer la redemande.
    func relinquishIfIdle() {
        queue.async { [self] in
            guard owners.subtracting(["player"]).isEmpty else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: [])
                logger.info("LECTEUR", "Session audio relâchée",
                            "lecture en pause en arrière-plan, sans réveiller les autres apps")
            } catch {
                logger.warn("LECTEUR", "Session audio : relâche refusée", error.localizedDescription)
            }
        }
    }

    /// Active la session ; `done(true)` sur le fil principal si iOS la donne
    /// (refusée pendant un appel téléphonique, par exemple).
    func activate(_ done: @escaping (Bool) -> Void) {
        queue.async {
            let granted = (try? AVAudioSession.sharedInstance().setActive(true)) != nil
            DispatchQueue.main.async { done(granted) }
        }
    }

    /// Sur `queue`. Un son qui joue encore n'empêche rien : iOS l'arrête, rend
    /// la session inactive quand même et répond `isBusy` (doc d'Apple). Rien
    /// à réessayer — un nouvel essai couperait de nouveau un son relancé
    /// entre-temps. D'où le PiP, détenteur à part entière tant qu'il dure.
    private func deactivate(notifyOthers: Bool, generation wanted: Int) {
        guard wanted == generation, owners.isEmpty else { return }
        wakeOthersPending = false
        let detail = notifyOthers ? "les autres apps peuvent reprendre leur son"
                                  : "sans réveiller les autres apps (minuteur de veille)"
        do {
            try AVAudioSession.sharedInstance().setActive(
                false, options: notifyOthers ? .notifyOthersOnDeactivation : [])
            logger.info("LECTEUR", "Session audio relâchée", detail)
        } catch {
            if (error as NSError).code == AVAudioSession.ErrorCode.isBusy.rawValue {
                logger.warn("LECTEUR", "Session audio relâchée alors qu'un son jouait encore (arrêté par iOS)", detail)
            } else {
                logger.warn("LECTEUR", "Session audio : relâche refusée", error.localizedDescription)
            }
        }
    }
}

// MARK: – Interruptions (appel, Siri, alarme, autre app)
/// Interruptions du son, pour un lecteur. iOS met la lecture en pause au
/// début d'une interruption et ne la relance jamais : on la relance si elle
/// tournait quand l'interruption a commencé — jamais après une pause voulue.
///   • Fin avec `shouldResume` (fin d'appel, Siri, alarme) : tout de suite,
///     même en arrière-plan.
///   • Pas de fin, ou fin sans `shouldResume` (une app de musique mise en
///     pause ne rend pas la main) : au retour dans l'app, si aucun appel ne
///     dure, qu'aucune autre app ne joue de son et qu'iOS rend la session. On
///     ne coupe jamais le son d'une autre app sans un geste : sinon la lecture
///     reste en pause, le bouton lecture suffit (« Lecture » sur une tuile du
///     multi-live).
///   • Casque débranché : pause sans reprise (comportement d'Apple).
/// Tout se passe sur le fil principal. `resume` reçoit la durée de
/// l'interruption et rend ce qu'il a fait (journal), nil s'il n'y avait rien
/// à reprendre (élément en échec, fin de VOD, lecture déjà repartie).
final class PlaybackInterruptions {
    /// Au-delà, un direct est relu plutôt que recalé : l'app, suspendue
    /// quelques secondes après la coupure du son, ne relit plus la playlist,
    /// et le bord qu'elle connaît a vieilli d'autant. En deçà (Siri), le saut
    /// au bord suffit et repart aussitôt.
    static let longInterruption: TimeInterval = 15

    private struct WeakPlayer { weak var player: AVPlayer? }

    private let name: String
    private let resume: (TimeInterval) -> String?
    private var tokens: [NSObjectProtocol] = []
    private var watched: [WeakPlayer] = []
    /// Début de la dernière interruption.
    private var interruptedAt: Date?
    /// Pause d'iOS due à une interruption (AVPlayer en donne la raison) : elle
    /// et le début de l'interruption arrivent dans un ordre quelconque.
    private var systemPausedAt: Date?
    /// La lecture tournait au début de l'interruption : reprise due.
    private(set) var isPending = false
    private var activeCheck: DispatchWorkItem?
    #if os(iOS)
    /// Appels en cours : téléphone, FaceTime, apps d'appel passant par CallKit.
    /// Créé avec le lecteur, pour être à jour quand on le consulte.
    private let callObserver = CXCallObserver()
    #endif

    init(name: String, resume: @escaping (TimeInterval) -> String?) {
        self.name = name
        self.resume = resume
        let center = NotificationCenter.default
        tokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in self?.interruption(note) })
        tokens.append(center.addObserver(
            forName: AVPlayer.rateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] note in self?.rateChanged(note) })
        tokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in self?.routeChanged(note) })
        tokens.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.becameActive() })
    }

    deinit {
        activeCheck?.cancel()
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }

    /// Lecteurs suivis, à la place des précédents : un seul, ou les tuiles du
    /// multi-live.
    func watch(_ players: [AVPlayer]) { watched = players.map { WeakPlayer(player: $0) } }
    func watch(_ player: AVPlayer) { watch([player]) }

    /// Pause voulue, autre source, casque débranché : plus rien à reprendre.
    func settle() {
        isPending = false
        activeCheck?.cancel()
        activeCheck = nil
    }

    private var players: [AVPlayer] { watched.compactMap { $0.player } }

    private func interruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            interruptedAt = Date()
            // Encore en lecture, ou pause d'iOS déjà vue : elle tournait.
            let playing = players.contains { $0.currentItem != nil && $0.timeControlStatus != .paused }
                || systemPausedAt.map { abs($0.timeIntervalSinceNow) < 3 } == true
            if playing { isPending = true }
            logger.info("LECTEUR", "Interruption du son : début (\(name))",
                        isPending ? "lecture en cours : reprise prévue" : "lecture déjà en pause : pas de reprise")
        case .ended:
            let options = AVAudioSession.InterruptionOptions(
                rawValue: (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0)
            let shouldResume = options.contains(.shouldResume)
            guard isPending else {
                logger.info("LECTEUR", "Interruption du son : fin (\(name))",
                            "shouldResume \(shouldResume ? "oui" : "non") · rien à reprendre")
                return
            }
            guard shouldResume else {
                // Pas de feu vert d'iOS : on attend le retour dans l'app.
                logger.info("LECTEUR", "Interruption du son : fin (\(name))",
                            "shouldResume non · reprise au retour dans l'app, si aucun autre son ne joue")
                return
            }
            let since = interruptedAt.map { -$0.timeIntervalSinceNow } ?? 0
            settle()
            let done = resume(since)
            logger.info("LECTEUR", "Interruption du son : fin (\(name))",
                        "shouldResume oui · " + (done.map { "reprise : \($0)" } ?? "rien à reprendre"))
        @unknown default:
            break
        }
    }

    /// Raison donnée par AVPlayer : pause d'iOS (interruption), ou pause
    /// demandée dans l'app (bouton, PiP, commandes d'Apple) — alors c'est
    /// l'utilisateur qui décide. Une pause arrivée avec le début de
    /// l'interruption est celle d'iOS, quelle que soit sa raison.
    private func rateChanged(_ note: Notification) {
        guard let player = note.object as? AVPlayer, player.rate == 0,
              players.contains(where: { $0 === player }) else { return }
        let reason = Self.reason(note)
        let justInterrupted = interruptedAt.map { abs($0.timeIntervalSinceNow) < 3 } == true
        if reason == AVPlayer.RateDidChangeReason.audioSessionInterrupted {
            systemPausedAt = Date()
            if !isPending, justInterrupted {
                isPending = true
                logger.info("LECTEUR", "Interruption du son (\(name))", "lecture coupée par iOS : reprise prévue")
            }
        } else if reason == AVPlayer.RateDidChangeReason.setRateCalled, isPending, !justInterrupted {
            settle()
        }
    }

    private static func reason(_ note: Notification) -> AVPlayer.RateDidChangeReason? {
        let raw = note.userInfo?[AVPlayer.rateDidChangeReasonKey]
        if let reason = raw as? AVPlayer.RateDidChangeReason { return reason }
        if let text = raw as? String { return AVPlayer.RateDidChangeReason(rawValue: text) }
        return nil
    }

    private func routeChanged(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable,
              isPending || players.contains(where: { $0.currentItem != nil }) else { return }
        settle()
        logger.info("LECTEUR", "Sortie audio débranchée (\(name))", "pause sans reprise automatique")
    }

    private func becameActive() {
        guard isPending else { return }
        activeCheck?.cancel()
        // Une fin d'appel (shouldResume) peut suivre de peu le retour dans
        // l'app : elle passe d'abord.
        let check = DispatchWorkItem { [weak self] in self?.resumeIfQuiet() }
        activeCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: check)
    }

    /// Un appel dure encore. iOS peut rendre la session `.playback` pendant un
    /// appel tenu par une autre app (FaceTime, WhatsApp… : de quoi lancer
    /// SharePlay) : la vidéo repartirait en plein appel. Pas de CallKit sur
    /// l'Apple TV.
    private var inCall: Bool {
        #if os(iOS)
        return callObserver.calls.contains { !$0.hasEnded }
        #else
        return false
        #endif
    }

    private func resumeIfQuiet() {
        activeCheck = nil
        guard isPending else { return }
        if inCall {
            logger.info("LECTEUR", "Retour dans l'app après une interruption (\(name))",
                        "appel en cours : reprise à la fin de l'interruption")
            return
        }
        if AVAudioSession.sharedInstance().isOtherAudioPlaying {
            logger.info("LECTEUR", "Retour dans l'app après une interruption (\(name))",
                        "une autre app joue du son : lecture laissée en pause")
            return
        }
        // Session rendue par iOS ? Refusée tant qu'un appel téléphonique
        // dure : la fin de l'interruption relancera alors la lecture.
        PlaybackAudio.shared.activate { [weak self] granted in
            guard let self, self.isPending else { return }
            guard granted else {
                logger.info("LECTEUR", "Retour dans l'app après une interruption (\(self.name))",
                            "son encore pris (appel ?) : reprise à la fin de l'interruption")
                return
            }
            let since = self.interruptedAt.map { -$0.timeIntervalSinceNow } ?? 0
            self.settle()
            let done = self.resume(since)
            logger.info("LECTEUR", "Retour dans l'app après une interruption (\(self.name))",
                        "aucun autre son · " + (done.map { "reprise : \($0)" } ?? "rien à reprendre"))
        }
    }
}
