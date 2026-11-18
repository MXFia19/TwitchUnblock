import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Chat posé sur l'image, déplacé au doigt (demande de joey) : en paysage, la
//  poignée du haut du chat se glisse où l'on veut — loin de la facecam, par
//  exemple —, et au lâcher le chat s'aimante à la plus proche des six places
//  de Réglages → Chat → Chat posé sur l'image : les quatre coins (moitié
//  haute ou basse d'un côté), ou le milieu d'un bord, sur toute la hauteur.
//  Le réglage suit (même place enregistrée, sauvegarde et site compris).
//
//  Le déplacement vit dans un objet à part, comme PlayerPull : seuls le
//  chat (ChatMoveEffect), sa poignée et l'aperçu de sa place se redessinent
//  à chaque image du geste, pas tout MainTabView.
// ═══════════════════════════════════════════════════════════════════════════

final class ChatMove: ObservableObject {
    /// Déplacement depuis sa place (zéro au repos).
    @Published var offset: CGSize = .zero

    var moving: Bool { offset != .zero }

    /// Pose du chat sur sa nouvelle place.
    static let snap = Animation.spring(response: 0.32, dampingFraction: 0.86)

    /// Place la plus proche du milieu du chat déplacé de `moved` : le côté
    /// le plus proche, et en hauteur la moitié haute, la moitié basse ou toute
    /// la hauteur (milieux à 1/4, 1/2 et 3/4 de l'écran). Le chat garde sa
    /// taille pendant le geste : glissé de côté, un chat sur toute la hauteur
    /// le reste ; descendu, il va dans le coin du bas. Sans déplacement, la
    /// même place.
    static func target(from layout: ChatOverlayLayout, moved: CGSize,
                       size: CGSize, chatWidth: CGFloat) -> ChatOverlayLayout {
        let x = (layout.side == .left ? chatWidth / 2 : size.width - chatWidth / 2) + moved.width
        let middle: CGFloat
        switch layout.height {
        case .top:    middle = size.height * 0.25
        case .bottom: middle = size.height * 0.75
        case .full:   middle = size.height * 0.5
        }
        let y = middle + moved.height
        let side: ChatOverlayLayout.Side = x < size.width / 2 ? .left : .right
        let height: ChatOverlayLayout.Height = y < size.height * 0.375 ? .top
            : y > size.height * 0.625 ? .bottom : .full
        return ChatOverlayLayout(side: side, height: height)
    }
}

/// Le chat suit le doigt pendant le glissé de sa poignée. `enabled` : chat
/// posé sur l'image ; ailleurs (colonne, portrait), jamais décalé, même si
/// un geste coupé net (rotation) a laissé un déplacement en route.
struct ChatMoveEffect: ViewModifier {
    @ObservedObject var move: ChatMove
    var enabled = true

    func body(content: Content) -> some View {
        content.offset(enabled ? move.offset : .zero)
    }
}

/// Poignée du haut du chat posé sur l'image. Discrète au repos, comme celle
/// de la largeur ; une bande de 72 × 26 pt reçoit le geste. Repère global :
/// le chat bouge sous le doigt (mesuré dans son propre repère, le
/// déplacement retomberait à chaque image).
struct ChatMoveHandle: View {
    @ObservedObject var move: ChatMove
    /// Place du chat au départ, taille du lecteur et largeur du chat : de quoi
    /// trouver la place la plus proche au lâcher.
    let layout: ChatOverlayLayout
    let size: CGSize
    let chatWidth: CGFloat
    /// Nouvelle place, appelée dans l'animation de la pose.
    let onDrop: (ChatOverlayLayout) -> Void

    /// Vrai pendant le geste, faux dès qu'il s'arrête — même interrompu
    /// (Centre de contrôle, appel), cas où onEnded n'arrive jamais.
    @GestureState private var active = false

    var body: some View {
        Capsule()
            .fill(Color.white.opacity(move.moving ? 0.95 : 0.35))
            .frame(width: move.moving ? 44 : 36, height: move.moving ? 5 : 4)
            .frame(width: 72, height: 26)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .updating($active) { _, active, _ in active = true }
                    .onChanged { value in
                        // Au doigt, sans animation : même si le chat finissait
                        // encore de se poser, il suit aussitôt.
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { move.offset = value.translation }
                    }
                    .onEnded { value in
                        let target = ChatMove.target(from: layout, moved: value.translation,
                                                     size: size, chatWidth: chatWidth)
                        withAnimation(ChatMove.snap) {
                            onDrop(target)
                            move.offset = .zero
                        }
                    }
            )
            // Geste interrompu : pas d'onEnded, le chat reprend sa place.
            .onChange(of: active) { active in
                guard !active, move.moving else { return }
                withAnimation(ChatMove.snap) { move.offset = .zero }
            }
            // Poignée retirée en plein geste (rotation, chat replié) : ni
            // onEnded ni fin du geste, rien ne doit rester décalé.
            .onDisappear {
                if move.moving { move.offset = .zero }
            }
            .animation(.easeOut(duration: 0.15), value: move.moving)
            .accessibilityHidden(true)
    }
}

/// Pendant le glissé, la place où le chat va se poser, en filigrane. Posé
/// en haut à gauche du lecteur, de sa taille.
struct ChatSlotPreview: View {
    @ObservedObject var move: ChatMove
    let layout: ChatOverlayLayout
    let size: CGSize
    let chatWidth: CGFloat

    var body: some View {
        if move.moving {
            let target = ChatMove.target(from: layout, moved: move.offset, size: size, chatWidth: chatWidth)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.tPrimary.opacity(0.16))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.tPrimary.opacity(0.85), lineWidth: 2))
                .frame(width: chatWidth, height: target.half == nil ? size.height : size.height / 2)
                .offset(x: target.side == .left ? 0 : size.width - chatWidth,
                        y: target.half == .bottom ? size.height / 2 : 0)
                .animation(.easeOut(duration: 0.12), value: target.raw)
                .allowsHitTesting(false)
        }
    }
}
