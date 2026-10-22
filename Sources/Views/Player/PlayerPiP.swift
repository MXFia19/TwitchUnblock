import Foundation
import Combine

// ═══════════════════════════════════════════════════════════════════════════
//  Image dans l'image (PiP) du lecteur principal, entre les lecteurs et
//  MainTabView.
//
//  Les deux lecteurs le tiennent à jour : l'immersif (AVPictureInPicture-
//  Controller) et le natif (AVPlayerViewController). Seul l'immersif se
//  commande d'ici : AVPlayerViewController n'a rien de public pour démarrer
//  ou arrêter son PiP. Le multi-live n'a pas de PiP.
//
//  Ce que MainTabView en fait :
//   - PiP démarré (bouton, app en arrière-plan, lecteur quitté) : le lecteur
//     se réduit. Il restait en grand, noir, par-dessus l'app (l'image était
//     partie dans la fenêtre), et il fallait le fermer à la main ;
//   - bouton « agrandir » de la fenêtre : le lecteur revient en grand, sur la
//     même lecture (rappels onPiPStart / onPiPRestore des lecteurs) ;
//   - lecteur rouvert en grand pendant un PiP (mini-barre…) : le PiP
//     s'arrête et l'image revient dans le lecteur ;
//   - « PiP en quittant le lecteur » (Réglages → Lecteur) : PiP au lieu du
//     mini-lecteur.
//  Fil principal seulement.
// ═══════════════════════════════════════════════════════════════════════════

final class PlayerPiP: ObservableObject {
    static let shared = PlayerPiP()
    private init() {}

    /// Une fenêtre PiP montre le lecteur principal : la mini-barre le dit.
    @Published private(set) var active = false
    /// Lecteur qui a la fenêtre : la fin tardive d'un autre ne l'efface pas.
    private weak var owner: AnyObject?
    /// Lecteur immersif en place, et de quoi le faire passer en PiP (true si
    /// c'est parti) ou en faire revenir l'image. Des fermetures données par le
    /// lecteur plutôt que ses méthodes appelées d'ici : elles gardent son
    /// isolement d'acteur, quel que soit celui qu'AVKit lui fait hériter.
    private weak var immersive: AnyObject?
    private var startImmersive: (() -> Bool)?
    private var stopImmersive: (() -> Void)?
    /// Lecteur quitté avec « PiP en quittant le lecteur », PiP pas encore
    /// démarré : la réduction ordinaire, faite si le PiP échoue ou tarde.
    private var leaveFallback: (() -> Void)?
    private var leaveRequest = 0

    // MARK: Lecteurs
    /// Lecteur immersif dont le PiP est prêt (attachPiP). Les fermetures le
    /// tiennent en lien faible : rien ne le retient d'ici.
    func register(_ model: AnyObject, start: @escaping () -> Bool, stop: @escaping () -> Void) {
        immersive = model
        startImmersive = start
        stopImmersive = stop
    }

    /// Lecteur démonté : plus rien à lui demander (sauf s'il a déjà été remplacé).
    func unregister(_ model: AnyObject) {
        guard immersive === model else { return }
        immersive = nil
        startImmersive = nil
        stopImmersive = nil
    }

    func started(by player: AnyObject) {
        owner = player
        if !active { active = true }
        // Démarré : plus de repli à faire.
        leaveFallback = nil
    }

    /// `player` nil : lecteur libéré sans démontage (le lien faible vers lui
    /// vaut déjà nil). La fin d'un lecteur qui n'a plus la fenêtre ne change rien.
    func ended(by player: AnyObject?) {
        guard owner == nil || owner === player else { return }
        owner = nil
        // Publié au tour suivant : la fin arrive aussi d'un démontage, en
        // pleine mise à jour des vues. Un PiP reparti entre-temps la garde.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.owner == nil, self.active else { return }
            self.active = false
        }
    }

    /// Démarrage refusé par AVKit : le lecteur quitté se réduit tout de suite.
    func failed() { fallBack() }

    // MARK: MainTabView
    /// Lecteur quitté (glissé vers le bas, flèche) avec « PiP en quittant le
    /// lecteur » : le PiP démarre à la place du mini-lecteur, et le lecteur se
    /// réduit à son départ (onPiPStart). false s'il ne peut pas démarrer
    /// (lecteur natif, pause, échec, AVKit qui refuse) : l'appelant réduit
    /// comme avant. `fallback` : cette réduction, si le PiP échoue ou n'a pas
    /// démarré au bout de 2 s.
    func startOnLeave(fallback: @escaping () -> Void) -> Bool {
        guard !active, immersive != nil, let start = startImmersive else { return false }
        leaveRequest += 1
        let request = leaveRequest
        // Posé avant la demande : un refus annoncé tout de suite le trouve.
        leaveFallback = fallback
        guard start() else {
            leaveFallback = nil
            return false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.leaveRequest == request else { return }
            self.fallBack()
        }
        return true
    }

    /// Lecteur rouvert en grand (mini-barre, notification…) : l'image quitte
    /// la fenêtre PiP et revient dans le lecteur, qui restait noir sinon.
    func playerShown() {
        guard immersive != nil else { return }
        stopImmersive?()
    }

    private func fallBack() {
        guard let fallback = leaveFallback else { return }
        leaveFallback = nil
        logger.warn("LECTEUR", "PiP pas démarré : mini-lecteur", nil)
        fallback()
    }
}
