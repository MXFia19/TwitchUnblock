import Foundation
import ActivityKit
import UIKit
import AVFoundation
import MediaPlayer
import CallKit

// ═══════════════════════════════════════════════════════════════════════════
//  Live Activity du lecteur (écran verrouillé, Dynamic Island) : la chaîne,
//  le titre, et l'état de la lecture — badge EN DIRECT, spectateurs, durée du
//  live, progression d'une VOD. L'extension TwitchUnblockWidgets la dessine.
//
//  Mise à jour par l'app elle-même, sans serveur de notifications : la lecture
//  continue en arrière-plan, l'app tourne donc tant que l'activité est utile.
//  Seuls les changements visibles sont envoyés (lecture/pause, saut, chaîne,
//  titre, spectateurs) : durée du live et barre d'une VOD avancent seules.
//
//  Une autre app qui joue, ou une longue pause en arrière-plan : l'app laisse
//  sa place (PlaybackYield, plus bas).
//
//  iOS 16.2 minimum : en dessous, ces appels ne font rien.
// ═══════════════════════════════════════════════════════════════════════════
enum PlayerActivity {
    /// Réglage « Activité en direct » (Réglages → Lecteur) : coupé, aucune ne
    /// démarre (AppStore termine celle en cours).
    static let key = "cfg_live_activity"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// Dernier état envoyé par le lecteur ; nil sans lecteur. De quoi
    /// démarrer l'activité au retour dans l'app quand iOS l'a refusée en
    /// arrière-plan (lecture reprise après avoir laissé la place).
    private struct LastState {
        var meta: NowPlayingMeta
        var isLive: Bool
        var isPlaying: Bool
        var position: Double
        var duration: Double
        var rate: Double
        var at: Date
    }
    private static var last: LastState?

    /// Démarre l'activité, ou met à jour celle en cours.
    /// `rate` : vitesse de lecture d'une VOD (la barre et le compteur avancent
    /// seuls, à ce rythme).
    static func update(_ meta: NowPlayingMeta, isLive: Bool, isPlaying: Bool,
                       position: Double = 0, duration: Double = 0, rate: Double = 1) {
        last = LastState(meta: meta, isLive: isLive, isPlaying: isPlaying, position: position,
                         duration: duration, rate: rate, at: Date())
        // Place laissée à une autre app : l'activité revient avec la lecture,
        // pas sur une pause, un titre ou des spectateurs mis à jour.
        guard PlaybackYield.playerChanged(playing: isPlaying) else { return }
        guard enabled else { return }
        guard #available(iOS 16.2, *) else { return }
        PlayerActivityController.shared.update(meta, isLive: isLive, isPlaying: isPlaying,
                                               position: position, duration: duration, rate: rate)
    }

    /// Lecteur fermé : l'activité disparaît aussitôt. `playerClosed` faux
    /// (réglage « Activité en direct » coupé) : le lecteur reste suivi.
    static func end(playerClosed: Bool = true) {
        if playerClosed {
            last = nil
            PlaybackYield.playerClosed()
        }
        guard #available(iOS 16.2, *) else { return }
        PlayerActivityController.shared.end()
    }

    /// Lecteur démonté (vue retirée). Au premier plan, l'activité disparaît :
    /// le lecteur suivant en démarre une. En arrière-plan — raid suivi, VOD
    /// suivante de « Tout lire », écran verrouillé —, iOS refuse au suivant
    /// d'en démarrer une autre, et elle disparaissait : elle reste, en pause
    /// d'ici là, et il la reprend (voir `shownChannel`). La vraie fermeture
    /// la termine (MainTabView.stopPlayer).
    static func playerRemoved() {
        guard UIApplication.shared.applicationState != .active else { end(); return }
        last?.isPlaying = false
        PlaybackYield.playerChanged(playing: false)
        guard #available(iOS 16.2, *) else { return }
        PlayerActivityController.shared.pause()
    }

    /// Retour dans l'app : la lecture a repris en arrière-plan (fin d'une
    /// interruption, écran verrouillé) après que l'app a laissé sa place, et
    /// iOS a refusé d'y démarrer l'activité. Elle démarre ici, sans attendre
    /// le prochain changement.
    fileprivate static func startIfMissing() {
        guard let l = last, l.isPlaying, enabled else { return }
        guard #available(iOS 16.2, *), PlayerActivityController.shared.currentID == nil else { return }
        // Une VOD a avancé depuis le dernier état (à sa vitesse).
        var position = l.position
        if !l.isLive {
            position += Date().timeIntervalSince(l.at) * l.rate
            if l.duration > 0 { position = min(position, l.duration) }
        }
        PlayerActivityController.shared.update(l.meta, isLive: l.isLive, isPlaying: true,
                                               position: position, duration: l.duration, rate: l.rate)
    }

    /// Activités restées d'une session précédente (app fermée en pleine
    /// lecture) : iOS les garderait affichées des heures. `wait` bloque un
    /// instant, à la fermeture de l'app, le temps qu'elles se terminent.
    static func endOthers(wait: Bool = false) {
        guard #available(iOS 16.2, *) else { return }
        let current = PlayerActivityController.shared.currentID
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for activity in Activity<PlayerActivityAttributes>.activities where activity.id != current {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            done.signal()
        }
        if wait { _ = done.wait(timeout: .now() + 1) }
    }
}

@available(iOS 16.2, *)
private final class PlayerActivityController {
    static let shared = PlayerActivityController()

    private var activity: Activity<PlayerActivityAttributes>?
    private var attributes: PlayerActivityAttributes?
    private var state: PlayerActivityAttributes.ContentState?
    /// iOS a refusé l'activité faute de la clé NSSupportsLiveActivities
    /// (app réinstallée par un outil qui réécrit l'Info.plist) : plus d'essai
    /// avant le prochain lancement. Chaque lecture en redemandait une, et
    /// chaque refus ajoutait une ligne au journal.
    private var unsupported = false

    var currentID: String? { activity?.id }

    func update(_ meta: NowPlayingMeta, isLive: Bool, isPlaying: Bool,
                position: Double, duration: Double, rate: Double) {
        let channel = meta.artist.isEmpty ? meta.title : meta.artist
        guard !channel.isEmpty else { return }

        let vodProgress = !isLive && duration > 0
        // À 1,5×, la VOD finit 1,5 fois plus tôt : départ « virtuel » à
        // maintenant − position / vitesse, et barre sur durée / vitesse.
        let speed = vodProgress && rate.isFinite && rate > 0 ? rate : 1
        var newState = PlayerActivityAttributes.ContentState(
            title: meta.title == channel ? "" : meta.title,
            game: isLive ? meta.game : "",
            viewers: isLive && meta.viewers > 0 ? formatViewers(meta.viewers) : "",
            isPlaying: isPlaying,
            startedAt: isLive ? meta.startedAt
                              : (vodProgress ? Date().addingTimeInterval(-position / speed) : nil),
            position: vodProgress ? position : 0,
            duration: vodProgress ? duration : 0,
            rate: speed == 1 ? nil : speed)

        if let activity, let attributes {
            let shown = state.map { attributes.channel(in: $0) } ?? attributes.channel
            let shownLive = state.map { attributes.isLive(in: $0) } ?? attributes.isLive
            let same = shown == channel && shownLive == isLive
            // Même chaîne, même nature (direct ou VOD) : simple mise à jour.
            // Autre chaîne, app en arrière-plan (raid suivi écran verrouillé) :
            // iOS refuse d'en démarrer une autre — l'activité disparaissait
            // jusqu'au retour dans l'app. Celle-ci est reprise, et affiche la
            // nouvelle chaîne.
            if same || UIApplication.shared.applicationState != .active {
                if attributes.channel != channel || attributes.isLive != isLive {
                    newState.shownChannel = channel
                    newState.shownIsLive = isLive
                    newState.shownLiveLabel = meta.liveLabel
                }
                guard Self.changed(from: state, to: newState) else { return }
                if !same { logger.info("ACTIVITY", "Live Activity reprise pour une autre chaîne (arrière-plan)", channel) }
                state = newState
                Task { await activity.update(ActivityContent(state: newState, staleDate: nil)) }
                return
            }
        }

        // Sinon, nouvelle activité : l'ancienne (autre chaîne) disparaît.
        end()
        guard !unsupported, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attrs = PlayerActivityAttributes(channel: channel, isLive: isLive,
                                             liveLabel: meta.liveLabel)
        do {
            activity = try Activity.request(attributes: attrs,
                                            content: ActivityContent(state: newState, staleDate: nil),
                                            pushType: nil)
            attributes = attrs
            state = newState
            logger.info("ACTIVITY", "Live Activity démarrée", channel)
        } catch {
            if Self.isMissingPlistKey(error) {
                unsupported = true
                logger.warn("ACTIVITY", "Live Activity impossible avec cette installation",
                            "clé NSSupportsLiveActivities absente : plus d'essai avant le prochain lancement")
            } else {
                logger.warn("ACTIVITY", "Live Activity refusée", error.localizedDescription)
            }
        }
    }

    /// Refus « Target does not include NSSupportsLiveActivities plist key »
    /// (ActivityAuthorizationError.unsupportedTarget), reconnu à son texte.
    private static func isMissingPlistKey(_ error: Error) -> Bool {
        let text = "\(error) \(error.localizedDescription)"
        return text.contains("NSSupportsLiveActivities") || text.contains("unsupportedTarget")
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        attributes = nil
        state = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Plus rien ne joue, mais l'activité reste (voir PlayerActivity.playerRemoved).
    func pause() {
        guard let activity, var paused = state, paused.isPlaying else { return }
        paused.isPlaying = false
        state = paused
        let content = ActivityContent(state: paused, staleDate: nil)
        Task { await activity.update(content) }
    }

    /// Une VOD en lecture recalcule son départ à chaque appel (heure moins
    /// position) : à 2 s près, c'est le même affichage, inutile de l'envoyer.
    private static func changed(from old: PlayerActivityAttributes.ContentState?,
                                to new: PlayerActivityAttributes.ContentState) -> Bool {
        guard let old else { return true }
        if old.title != new.title || old.game != new.game || old.viewers != new.viewers
            || old.isPlaying != new.isPlaying || old.duration != new.duration
            || old.rate != new.rate || old.shownChannel != new.shownChannel
            || old.shownIsLive != new.shownIsLive || old.shownLiveLabel != new.shownLiveLabel { return true }
        if !new.isPlaying, abs(old.position - new.position) > 1 { return true }
        switch (old.startedAt, new.startedAt) {
        case (nil, nil):            return false
        case let (a?, b?):          return abs(a.timeIntervalSince(b)) > 2
        default:                    return true
        }
    }
}

// MARK: – Place laissée à une autre app
/// La Live Activity restait dans la Dynamic Island quand une autre app jouait
/// (Spotify…) : la toucher ouvrait TwitchUnblock au lieu de cette app. L'app
/// laisse donc sa place, et la reprend quand la lecture repart :
///   • son pris par une autre app (interruption hors appel, avec un autre
///     son qui joue 10 s après, ou toujours en cours 16 s après) : Live
///     Activity terminée, « À l'écoute » effacé ;
///   • pause en arrière-plan : iOS suspend l'app quelques secondes après la
///     fin du son, et plus rien ne pourrait alors retirer l'activité quand
///     une autre app se met à jouer. Un délai est demandé à iOS, et elle est
///     terminée juste avant la suspension (≈ 20 s ; pas sous un PiP, qui
///     garde l'app en marche ; sa fenêtre fermée, ≈ 20 s après). « À
///     l'écoute » reste, pour reprendre depuis l'écran verrouillé ; avec
///     l'activité, il s'efface (session audio rendue sans bruit) après 3 min
///     de pause, si l'app tourne alors — réveillée après coup, elle laisse
///     d'abord passer ce qui l'a réveillée (« lecture » de l'écran verrouillé).
/// Jamais pendant un appel, ni pendant une interruption qui n'est pas finie
/// (Siri, alarme) : la lecture repart à sa fin (PlaybackInterruptions),
/// activité comprise. Rien ne change au premier plan, ni d'un direct à
/// l'autre en arrière-plan (raid suivi, VOD suivante : quelques secondes).
/// Tout se passe sur le fil principal.
enum PlaybackYield {
    /// Activité terminée pour laisser la place : pas de nouvelle tant que la
    /// lecture ne reprend pas.
    private(set) static var activityYielded = false
    /// « À l'écoute » effacé : les lecteurs ne le republient qu'en lecture.
    private(set) static var nowPlayingYielded = false
    /// Lecteur ouvert, en lecture ou non ; nil sans lecteur.
    private static var playing: Bool?
    /// Son interrompu (début reçu, pas encore la fin).
    private static var interruptedAt: Date?
    private static var interruptionCheck: DispatchWorkItem?
    /// Pause en arrière-plan, depuis.
    private static var pausedAt: Date?
    private static var pauseWork: [DispatchWorkItem] = []
    /// Délai demandé à iOS avant la suspension.
    private static var backgroundTime: UIBackgroundTaskIdentifier = .invalid
    private static let calls = CXCallObserver()
    /// Pause en arrière-plan au-delà de laquelle « À l'écoute » s'efface.
    private static let pauseLimit: TimeInterval = 3 * 60

    private static let observing: Void = {
        let center = NotificationCenter.default
        _ = center.addObserver(forName: AVAudioSession.interruptionNotification,
                               object: nil, queue: .main) { note in
            PlaybackYield.interruption(note)
        }
        _ = center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                               object: nil, queue: .main) { _ in
            if PlaybackYield.playing == false { PlaybackYield.armPause() }
        }
        _ = center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                               object: nil, queue: .main) { _ in
            PlaybackYield.disarmPause()
            PlayerActivity.startIfMissing()
        }
    }()

    /// État envoyé par le lecteur (PlayerActivity.update). Rend faux quand
    /// l'activité ne doit pas être touchée : place laissée, toujours en pause.
    @discardableResult
    static func playerChanged(playing now: Bool) -> Bool {
        _ = observing
        let was = playing
        playing = now
        if now {
            // Un état « en lecture » répété (déjà en lecture) ne défait rien :
            // il peut arriver juste après le début d'une interruption.
            if was != true {
                if activityYielded || nowPlayingYielded {
                    logger.info("LECTEUR", "Lecture reprise : l'app reprend sa place", nil)
                }
                reset()
            }
            return true
        }
        if UIApplication.shared.applicationState != .active { armPause() }
        return !activityYielded
    }

    /// Fenêtre PiP fermée (PlayerPiP.ended). Une pause en arrière-plan
    /// commencée sous la fenêtre n'avait pas de fin d'activité prévue (l'app
    /// tournait) ; fermée — souvent après la pause, la croix arrêtant la
    /// lecture —, l'app va être suspendue avec l'activité : elle est prévue
    /// d'ici, comme sans PiP.
    static func pipClosed() {
        guard playing == false, pausedAt != nil, !activityYielded,
              UIApplication.shared.applicationState != .active else { return }
        disarmPause()
        armPause()
    }

    /// Lecteur fermé : tout repart de zéro pour le suivant.
    static func playerClosed() {
        playing = nil
        reset()
    }

    private static func reset() {
        activityYielded = false
        nowPlayingYielded = false
        interruptedAt = nil
        cancelInterruptionCheck()
        disarmPause()
    }

    // MARK: Son pris par une autre app
    private static func interruption(_ note: Notification) {
        guard playing != nil, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        cancelInterruptionCheck()
        switch type {
        case .began:
            interruptedAt = Date()
            guard !nowPlayingYielded else { releaseTimeIfIdle(); return }
            holdTime()
            checkOtherAudio(after: 4, seen: 0, left: 2)
        case .ended:
            interruptedAt = nil
            // Fin sans reprise : la lecture reste en pause, et cette pause en
            // arrière-plan compte d'ici. Une reprise la désarme aussitôt.
            if playing == false, UIApplication.shared.applicationState != .active {
                disarmPause()
                armPause()
            } else {
                releaseTimeIfIdle()
            }
        @unknown default:
            releaseTimeIfIdle()
        }
    }

    /// Un autre son, vu deux fois de suite (vers 4 s puis 10 s) ; ou, sans
    /// rien entendre, un son toujours pris 16 s après le début (une app qui
    /// garde la session sans jouer) : Siri ou une notification rendent la
    /// main avant. Un appel n'est jamais pris pour une autre app.
    private static func checkOtherAudio(after delay: TimeInterval, seen: Int, left: Int) {
        let work = DispatchWorkItem {
            PlaybackYield.interruptionCheck = nil
            guard PlaybackYield.interruptedAt != nil, PlaybackYield.playing == false,
                  !PlaybackYield.nowPlayingYielded,
                  !PlaybackYield.calls.calls.contains(where: { !$0.hasEnded }) else {
                PlaybackYield.releaseTimeIfIdle()
                return
            }
            let session = AVAudioSession.sharedInstance()
            let other = session.secondaryAudioShouldBeSilencedHint || session.isOtherAudioPlaying
            let count = other ? seen + 1 : 0
            if count >= 2 || left == 0 {
                // Session déjà rendue par l'interruption : rien à relâcher.
                PlaybackYield.yieldAll(count >= 2 ? "une autre app joue du son"
                                                  : "son toujours pris par une autre app",
                                       relinquish: false)
                PlaybackYield.releaseTimeIfIdle()
            } else {
                PlaybackYield.checkOtherAudio(after: 6, seen: count, left: left - 1)
            }
        }
        interruptionCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func cancelInterruptionCheck() {
        interruptionCheck?.cancel()
        interruptionCheck = nil
    }

    // MARK: Pause en arrière-plan
    /// iOS va suspendre l'app : rien ne la garde (une fenêtre PiP, même en
    /// pause, la laisse tourner — et y montre déjà l'image).
    private static var suspending: Bool { !PlayerPiP.shared.active }

    fileprivate static func armPause() {
        guard pausedAt == nil, playing == false else { return }
        pausedAt = Date()
        if !activityYielded, suspending {
            holdTime()
            // Juste avant la suspension (≈ 30 s accordées par iOS), et assez
            // tard pour un raid suivi ou la VOD suivante (quelques secondes).
            let soon = max(3, min(20, UIApplication.shared.backgroundTimeRemaining - 8))
            let work = DispatchWorkItem { PlaybackYield.pausedTooLong(all: false) }
            pauseWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + soon, execute: work)
        }
        if !nowPlayingYielded { armPauseLimit(after: pauseLimit) }
    }

    /// Fin des 3 min de pause, à l'heure réelle : l'app suspendue entre-temps
    /// la voit passée à son réveil.
    private static func armPauseLimit(after delay: TimeInterval) {
        let due = Date().addingTimeInterval(delay)
        let work = DispatchWorkItem { PlaybackYield.pauseLimitReached(due: due) }
        pauseWork.append(work)
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + delay, execute: work)
    }

    /// Échéance passée depuis plus de 2 s : l'app était suspendue et vient
    /// d'être réveillée — le plus souvent par « lecture » sur l'écran
    /// verrouillé, traité juste après. Effacer « À l'écoute » et rendre la
    /// session audio d'abord pouvait couper cette reprise (session relâchée
    /// sur sa file pendant que la lecture repartait) : nouvel essai dans 2 s,
    /// que la reprise annule (disarmPause).
    private static func pauseLimitReached(due: Date) {
        if Date().timeIntervalSince(due) > 2 {
            armPauseLimit(after: 2)
            return
        }
        pausedTooLong(all: true)
    }

    fileprivate static func disarmPause() {
        pausedAt = nil
        pauseWork.forEach { $0.cancel() }
        pauseWork = []
        releaseTimeIfIdle()
    }

    private static func pausedTooLong(all: Bool) {
        // Revenu dans l'app, lecture repartie, ou son interrompu (appel,
        // Siri : la lecture repart à la fin, activité comprise).
        guard playing == false, pausedAt != nil, interruptedAt == nil,
              UIApplication.shared.applicationState != .active else {
            releaseTimeIfIdle()
            return
        }
        if all {
            yieldAll("en pause depuis plus de 3 min en arrière-plan", relinquish: true)
            releaseTimeIfIdle()
        } else if suspending {
            yieldActivity("lecture en pause en arrière-plan")
            // Le temps que la fin de l'activité parte avant la suspension.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { PlaybackYield.releaseTimeIfIdle() }
        } else {
            // PiP ouvert entre-temps : l'app tourne, les 3 min décideront.
            releaseTimeIfIdle()
        }
    }

    // MARK: Place laissée
    private static func yieldActivity(_ why: String) {
        guard !activityYielded else { return }
        activityYielded = true
        guard #available(iOS 16.2, *), PlayerActivityController.shared.currentID != nil else { return }
        PlayerActivityController.shared.end()
        logger.info("ACTIVITY", "Live Activity terminée : place laissée", why)
    }

    private static func yieldAll(_ why: String, relinquish: Bool) {
        yieldActivity(why)
        guard !nowPlayingYielded else { return }
        nowPlayingYielded = true
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if relinquish { PlaybackAudio.shared.relinquishIfIdle() }
        logger.info("LECTEUR", "« À l'écoute » effacé : place laissée", why)
    }

    // MARK: Délai d'arrière-plan
    private static func holdTime() {
        guard backgroundTime == .invalid else { return }
        backgroundTime = UIApplication.shared.beginBackgroundTask(withName: "playback-yield") {
            PlaybackYield.timeRanOut()
        }
    }

    /// Délai d'iOS écoulé : l'app va être suspendue. En pause (hors
    /// interruption), l'activité part maintenant : plus rien ne pourrait la
    /// retirer ensuite.
    private static func timeRanOut() {
        cancelInterruptionCheck()
        if playing == false, pausedAt != nil, interruptedAt == nil, suspending,
           UIApplication.shared.applicationState != .active {
            yieldActivity("délai d'arrière-plan écoulé")
        }
        endTime()
    }

    /// Délai rendu à iOS quand plus rien n'en a besoin : ni vérification du
    /// son en cours, ni activité à terminer avant la suspension.
    private static func releaseTimeIfIdle() {
        let pauseNeedsTime = pausedAt != nil && !activityYielded && interruptedAt == nil && suspending
        guard interruptionCheck == nil, !pauseNeedsTime else { return }
        endTime()
    }

    private static func endTime() {
        guard backgroundTime != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTime)
        backgroundTime = .invalid
    }
}
