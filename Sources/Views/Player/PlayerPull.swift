import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Glissé vers le bas du lecteur (flèche retour au doigt).
//
//  Le décalage vit dans un objet à part, observé par le seul
//  `PlayerPullEffect` : à chaque image du geste, seul ce petit modificateur
//  se recalcule. Gardé en @State de MainTabView, il redessinait tout l'écran
//  (lecteur, chat, onglets) à chaque déplacement du doigt — d'où un glissé
//  saccadé.
// ═══════════════════════════════════════════════════════════════════════════

final class PlayerPull: ObservableObject {
    /// Décalage vers le bas, en points (0 = lecteur en place).
    @Published var y: CGFloat = 0
}

/// Le lecteur suit le doigt et rapetisse un peu, comme dans l'app Twitch :
/// on voit qu'il est en train d'être rangé.
struct PlayerPullEffect: ViewModifier {
    @ObservedObject var pull: PlayerPull

    func body(content: Content) -> some View {
        let progress = min(max(pull.y, 0) / 500, 1)
        content
            .scaleEffect(1 - progress * 0.12, anchor: .top)
            .offset(y: pull.y)
    }
}
