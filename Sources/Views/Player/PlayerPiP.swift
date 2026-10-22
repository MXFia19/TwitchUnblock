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
//   - PiP démarré (bouton, app en arrière-plan) : le lecteur se réduit. Il
//     restait en grand, noir, par-dessus l'app (l'image était partie dans la
//     fenêtre), et il fallait le fermer à la main ;
//   - bouton « agrandir » de la fenêtre : le lecteur revient en grand, sur la
//     même lecture (rappels onPiPStart / onPiPRestore des lecteurs) ;
//   - lecteur rouvert en grand pendant un PiP (mini-barre…) : le PiP
//     s'arrête et l'image revient dans le lecteur.
//  Fil principal seulement.
// ═══════════════════════════════════════════════════════════════════════════

final class PlayerPiP: ObservableObject {
    static let shared = PlayerPiP()
    private init() {}

    /// Une fenêtre PiP montre le lecteur principal : la mini-barre le dit.
    @Published private(set) var active = false
    /// Lecteur qui a la fenêtre : la fin tardive d'un autre ne l'efface pas.
    private weak var owner: AnyObject?
    /// Lecteur immersif en place : celui dont l'image revient de la fenêtre.
    private weak var immersive: ImmersivePlayerModel?

    // MARK: Lecteurs
    /// Lecteur immersif dont le PiP est prêt (attachPiP), ou démonté.
    func register(_ model: ImmersivePlayerModel) { immersive = model }

    func unregister(_ model: ImmersivePlayerModel) {
        if immersive === model { immersive = nil }
    }

    func started(by player: AnyObject) {
        owner = player
        if !active { active = true }
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

    // MARK: MainTabView
    /// Lecteur rouvert en grand (mini-barre, notification…) : l'image quitte
    /// la fenêtre PiP et revient dans le lecteur, qui restait noir sinon.
    func playerShown() {
        immersive?.stopPiPForPlayer()
    }
}
