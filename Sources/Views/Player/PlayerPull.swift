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
    /// Hauteur du lecteur (relevée par MainTabView) : seuil du geste, et
    /// distance de la glissade finale. Pas publiée : rien à redessiner.
    var height: CGFloat = 800

    /// Start following as soon as the finger moves down. Small sideways jitter
    /// stays undecided rather than rejecting the entire swipe on its first sample.
    static func direction(for translation: CGSize) -> Bool? {
        if translation.height > abs(translation.width) { return true }
        if translation.height < -8 || abs(translation.width) >= 8 { return false }
        return nil
    }

    /// Glissé à partir duquel on réduit : 15 % de la hauteur, entre 80 et
    /// 120 points (un iPhone en paysage n'a pas la place d'aller plus loin).
    static func threshold(for height: CGFloat) -> CGFloat {
        min(120, max(80, height * 0.15))
    }
}

/// Le lecteur suit le doigt et rapetisse un peu, comme dans l'app Twitch :
/// on voit qu'il est en train d'être rangé.
struct PlayerPullEffect: ViewModifier {
    @ObservedObject var pull: PlayerPull
    /// « Réduire les animations » (Accessibilité) : le lecteur suit le doigt
    /// sans rapetisser.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let progress = reduceMotion ? 0 : min(max(pull.y, 0) / 500, 1)
        content
            .scaleEffect(1 - progress * 0.12, anchor: .top)
            .offset(y: pull.y)
    }
}

/// A downward pull on the header or native video moves their shared player surface.
/// Gesture state stays here so tracking a finger does not redraw MainTabView.
struct PlayerPullGesture: ViewModifier {
    var onPull: (CGFloat) -> Void
    var onPullEnd: (CGFloat, CGFloat) -> Void

    @GestureState private var active = false
    @State private var pulling: Bool? = nil

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($active) { _, active, _ in active = true }
                    .onChanged { value in
                        if pulling == nil {
                            pulling = PlayerPull.direction(for: value.translation)
                        }
                        guard pulling == true else { return }
                        onPull(max(0, value.translation.height))
                    }
                    .onEnded { value in
                        let shouldFinish = pulling == true
                        pulling = nil
                        if shouldFinish {
                            onPullEnd(max(0, value.translation.height), value.predictedEndTranslation.height)
                        }
                    }
            )
            .onChange(of: active) { active in
                guard !active else { return }
                // Cancellation does not call onEnded (for example, opening Control Center).
                if pulling == true { onPull(0) }
                pulling = nil
            }
    }
}
