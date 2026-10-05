import Foundation
import ActivityKit

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
    /// Démarre l'activité, ou met à jour celle en cours.
    static func update(_ meta: NowPlayingMeta, isLive: Bool, isPlaying: Bool,
                       position: Double = 0, duration: Double = 0) {
        guard #available(iOS 16.2, *) else { return }
        PlayerActivityController.shared.update(meta, isLive: isLive, isPlaying: isPlaying,
                                               position: position, duration: duration)
    }

    /// Lecteur fermé : l'activité disparaît aussitôt.
    static func end() {
        guard #available(iOS 16.2, *) else { return }
        PlayerActivityController.shared.end()
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

    var currentID: String? { activity?.id }

    func update(_ meta: NowPlayingMeta, isLive: Bool, isPlaying: Bool,
                position: Double, duration: Double) {
        let channel = meta.artist.isEmpty ? meta.title : meta.artist
        guard !channel.isEmpty else { return }

        let vodProgress = !isLive && duration > 0
        let newState = PlayerActivityAttributes.ContentState(
            title: meta.title == channel ? "" : meta.title,
            game: isLive ? meta.game : "",
            viewers: isLive && meta.viewers > 0 ? formatViewers(meta.viewers) : "",
            isPlaying: isPlaying,
            startedAt: isLive ? meta.startedAt
                              : (vodProgress ? Date().addingTimeInterval(-position) : nil),
            position: vodProgress ? position : 0,
            duration: vodProgress ? duration : 0)

        // Même chaîne, même nature (direct ou VOD) : simple mise à jour.
        if let activity, let attributes,
           attributes.channel == channel, attributes.isLive == isLive {
            guard Self.changed(from: state, to: newState) else { return }
            state = newState
            Task { await activity.update(ActivityContent(state: newState, staleDate: nil)) }
            return
        }

        // Sinon, nouvelle activité : l'ancienne (autre chaîne) disparaît.
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
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
            logger.warn("ACTIVITY", "Live Activity refusée", error.localizedDescription)
        }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        attributes = nil
        state = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Une VOD en lecture recalcule son départ à chaque appel (heure moins
    /// position) : à 2 s près, c'est le même affichage, inutile de l'envoyer.
    private static func changed(from old: PlayerActivityAttributes.ContentState?,
                                to new: PlayerActivityAttributes.ContentState) -> Bool {
        guard let old else { return true }
        if old.title != new.title || old.game != new.game || old.viewers != new.viewers
            || old.isPlaying != new.isPlaying || old.duration != new.duration { return true }
        if !new.isPlaying, abs(old.position - new.position) > 1 { return true }
        switch (old.startedAt, new.startedAt) {
        case (nil, nil):            return false
        case let (a?, b?):          return abs(a.timeIntervalSince(b)) > 2
        default:                    return true
        }
    }
}
