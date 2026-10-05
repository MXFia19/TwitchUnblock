import Foundation
import ActivityKit

// ═══════════════════════════════════════════════════════════════════════════
//  Live Activity du lecteur : ce que l'app envoie, ce que l'extension
//  TwitchUnblockWidgets dessine sur l'écran verrouillé et dans la Dynamic
//  Island. Ce fichier est compilé dans les DEUX cibles (dossier Shared) :
//  iOS ne relie l'activité à sa vue que si le type est le même des deux côtés.
// ═══════════════════════════════════════════════════════════════════════════
@available(iOS 16.1, *)
struct PlayerActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var game: String
        /// Spectateurs déjà mis en forme (« 12.3k ») : l'extension n'a pas le
        /// code de l'app.
        var viewers: String
        var isPlaying: Bool
        /// Direct : début de la diffusion, pour une durée qui défile seule.
        /// VOD : début « virtuel » de la lecture (heure de la mise à jour moins
        /// la position), pour une barre qui avance seule tant qu'on ne met pas
        /// en pause — sans mise à jour à chaque seconde.
        var startedAt: Date?
        /// VOD : position au moment de la mise à jour (affichée en pause).
        var position: Double
        /// VOD : durée totale ; 0 pour un direct.
        var duration: Double
    }

    /// Chaîne regardée. Changer de chaîne crée une nouvelle activité.
    var channel: String
    var isLive: Bool
    /// « EN DIRECT », « LIVE NOW »… dans la langue choisie dans l'app.
    var liveLabel: String
}
