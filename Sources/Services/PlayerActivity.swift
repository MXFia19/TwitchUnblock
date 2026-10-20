import Foundation
import ActivityKit
import UIKit

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
//  iOS 16.2 minimum : en dessous, ces appels ne font rien.
// ═══════════════════════════════════════════════════════════════════════════
enum PlayerActivity {
    /// Réglage « Activité en direct » (Réglages → Lecteur) : coupé, aucune ne
    /// démarre (AppStore termine celle en cours).
    static let key = "cfg_live_activity"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// Démarre l'activité, ou met à jour celle en cours.
    /// `rate` : vitesse de lecture d'une VOD (la barre et le compteur avancent
    /// seuls, à ce rythme).
    static func update(_ meta: NowPlayingMeta, isLive: Bool, isPlaying: Bool,
                       position: Double = 0, duration: Double = 0, rate: Double = 1) {
        guard enabled else { return }
        guard #available(iOS 16.2, *) else { return }
        PlayerActivityController.shared.update(meta, isLive: isLive, isPlaying: isPlaying,
                                               position: position, duration: duration, rate: rate)
    }

    /// Lecteur fermé : l'activité disparaît aussitôt.
    static func end() {
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
        guard #available(iOS 16.2, *) else { return }
        if UIApplication.shared.applicationState == .active {
            PlayerActivityController.shared.end()
        } else {
            PlayerActivityController.shared.pause()
        }
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
