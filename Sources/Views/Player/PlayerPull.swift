import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

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

    /// Sens du geste, décidé dès les premiers points : vers le bas, le lecteur
    /// suit aussitôt ; vers le haut ou de côté (8 points), rien ; entre les
    /// deux, pas encore décidé — un léger tremblement de côté au premier point
    /// ne fait plus perdre tout le glissé (nil : on attend le point suivant).
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

// ═══════════════════════════════════════════════════════════════════════════
//  Boutons du lecteur pendant un glissé.
//
//  Le glissé part dès le premier point, en geste simultané : commencé sur un
//  bouton du lecteur (croix, ⋯, réduire, minuteur, « Direct »…), il emporte
//  le bouton avec le doigt, qui est donc encore dessus au doigt levé — et le
//  bouton faisait son action : la croix fermait le lecteur au lieu de le
//  réduire. Tant qu'un glissé a vraiment déplacé le lecteur, et un court
//  instant après le doigt levé, les boutons du lecteur ne font rien.
//
//  Un toucher normal (le doigt tremble de quelques points au plus) n'est pas
//  concerné. Le double-tap ±10 s, le zoom et la barre de lecture ne passent
//  pas par cette garde. Fil principal seulement : gestes et boutons.
// ═══════════════════════════════════════════════════════════════════════════

extension PlayerPull {
    /// Déplacement du lecteur au-delà duquel le glissé compte.
    static let buttonSlop: CGFloat = 10
    /// Délai après la fin du glissé : le bouton peut recevoir son toucher
    /// juste après le geste.
    static let buttonDelay: TimeInterval = 0.35

    /// Glissé en cours qui a déplacé le lecteur de plus de `buttonSlop`.
    private static var pullMoved = false
    /// Fin du dernier glissé qui a déplacé le lecteur.
    private static var pullEndedAt = Date.distantPast

    /// Le glissé en cours déplace le lecteur de `y` points (à chaque
    /// `onPull`, et au doigt levé).
    static func noteMove(_ y: CGFloat) {
        if y > buttonSlop { pullMoved = true }
    }

    /// Fin du geste : doigt levé, geste interrompu, ou vue retirée en plein
    /// glissé (sinon la garde resterait levée). Sans effet si le lecteur n'a
    /// pas bougé.
    static func noteEnd() {
        guard pullMoved else { return }
        pullMoved = false
        pullEndedAt = Date()
    }

    /// Vrai pendant un glissé qui a déplacé le lecteur, et `buttonDelay` après.
    /// Le doigt levé, l'ordre entre la fin du glissé et l'action du bouton
    /// n'est pas garanti : l'un ou l'autre de ces deux cas couvre le bouton.
    static var blocksButtons: Bool {
        pullMoved || Date().timeIntervalSince(pullEndedAt) < buttonDelay
    }

    /// Action d'un bouton du lecteur : ignorée pendant un glissé et juste après.
    static func guarded(_ action: () -> Void) {
        guard !blocksButtons else { return }
        action()
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

/// Glissé vers le bas sur le bandeau ou l'image du lecteur natif : le lecteur
/// (vidéo et chat) suit le doigt. Geste simultané, à partir d'un point : il
/// n'attend pas que les touchers renoncent, et laisse au lecteur d'Apple ses
/// propres gestes. L'état du geste vit ici : suivre le doigt ne redessine pas
/// MainTabView.
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
                        let y = max(0, value.translation.height)
                        // Garde des boutons du bandeau et de l'image (voir plus haut).
                        PlayerPull.noteMove(y)
                        onPull(y)
                    }
                    .onEnded { value in
                        let shouldFinish = pulling == true
                        pulling = nil
                        if shouldFinish {
                            let y = max(0, value.translation.height)
                            PlayerPull.noteMove(y)
                            onPullEnd(y, value.predictedEndTranslation.height)
                        }
                        PlayerPull.noteEnd()
                    }
            )
            .onChange(of: active) { active in
                guard !active else { return }
                // Geste annulé (Centre de contrôle ouvert…) : pas d'onEnded, le
                // lecteur reprend sa place.
                if pulling == true { onPull(0) }
                pulling = nil
                PlayerPull.noteEnd()
            }
            // Vue retirée en plein glissé (rotation…) : ni onEnded ni fin du
            // geste, la garde des boutons ne doit pas rester levée.
            .onDisappear {
                if pulling != nil { PlayerPull.noteEnd() }
            }
    }
}

/// Bouton UIKit du lecteur (AirPlay) : son action ne passe pas par SwiftUI,
/// donc pas par `PlayerPull.guarded`. Au doigt levé, ce geste reconnaît — ce
/// qui annule le toucher du bouton (`cancelsTouchesInView`) — si la garde du
/// glissé est levée ; sinon il échoue aussitôt et le bouton reçoit son
/// toucher comme avant. Il n'empêche aucun autre geste, et aucun ne l'empêche.
final class PlayerPullTouchGuard: UIGestureRecognizer {
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        state = PlayerPull.blocksButtons ? .recognized : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Pincement sur l'image : le point entre les doigts.
//
//  Le zoom partait toujours du milieu de l'image : MagnificationGesture ne
//  donne que l'échelle, et MagnifyGesture (iOS 17 et après) seulement son
//  point de départ — rien pour suivre deux doigts qui se déplacent. Un geste
//  UIKit posé sur la fenêtre relève donc les doigts posés sur l'image, sans
//  jamais rien reconnaître : SwiftUI garde la main sur le pincement (image
//  bien touchée, rien par-dessus), le lecteur lit seulement où sont les
//  doigts (ImmersivePlayer, zoomGesture). Toutes les versions d'iOS.
// ═══════════════════════════════════════════════════════════════════════════

/// Doigts posés sur la surface vidéo, et pincement en cours. Une classe
/// gardée hors de l'état SwiftUI : rien n'est redessiné quand ces valeurs
/// changent, à chaque déplacement des doigts.
final class PinchFocus {
    /// Surface vidéo : repère des points rendus.
    fileprivate weak var anchor: UIView?
    fileprivate var touches: [UITouch] = []
    /// Départ du pincement en cours : point entre les doigts (nil s'ils
    /// n'ont pas été relevés), zoom et décalage de l'image.
    var start: (focus: CGPoint?, zoom: CGFloat, pan: CGSize)?
    /// Déplacement du glissé à un doigt en cours (zéro sans glissé) : un
    /// doigt resté posé après le pincement continue de déplacer l'image.
    var drag: CGSize = .zero

    /// Milieu des doigts posés sur la surface (deux au moins), dans son repère.
    var point: CGPoint? {
        guard let anchor else { return nil }
        let live = touches.filter { $0.phase != .ended && $0.phase != .cancelled }
        guard live.count >= 2 else { return nil }
        let points = live.map { $0.location(in: anchor) }
        let n = CGFloat(points.count)
        return CGPoint(x: points.reduce(0) { $0 + $1.x } / n,
                       y: points.reduce(0) { $0 + $1.y } / n)
    }
}

/// Repère de la surface vidéo : posé derrière elle, à sa taille, sans
/// recevoir aucun toucher. Il installe le relevé des doigts sur sa fenêtre
/// tant qu'il y est.
struct PinchFocusAnchor: UIViewRepresentable {
    let focus: PinchFocus

    func makeUIView(context: Context) -> PinchFocusView { PinchFocusView(focus: focus) }
    func updateUIView(_ uiView: PinchFocusView, context: Context) {}
}

final class PinchFocusView: UIView {
    private let recognizer: PinchFocusRecognizer

    init(focus: PinchFocus) {
        recognizer = PinchFocusRecognizer(target: nil, action: nil)
        super.init(frame: .zero)
        focus.anchor = self
        recognizer.focus = focus
        // Ne retient ni n'annule aucun toucher.
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesEnded = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { return nil }

    /// Sur la fenêtre où se trouve le lecteur, retiré avec lui.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        recognizer.view?.removeGestureRecognizer(recognizer)
        window?.addGestureRecognizer(recognizer)
    }
}

/// Relève les doigts posés sur la surface. Ne reconnaît jamais rien : il
/// n'empêche aucun geste, aucun ne l'empêche, et il ne retient ni n'annule
/// aucun toucher (comme PlayerPullTouchGuard).
private final class PinchFocusRecognizer: UIGestureRecognizer {
    var focus: PinchFocus?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let focus, let anchor = focus.anchor else { return }
        for touch in touches where anchor.bounds.contains(touch.location(in: anchor)) {
            focus.touches.append(touch)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        lifted(touches, event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        lifted(touches, event)
    }

    /// Doigts levés : oubliés. Plus aucun doigt sur l'écran : le relevé
    /// repart de zéro au prochain toucher.
    private func lifted(_ touches: Set<UITouch>, _ event: UIEvent) {
        focus?.touches.removeAll { touches.contains($0) }
        let down = event.allTouches?.contains { $0.phase != .ended && $0.phase != .cancelled } ?? false
        if !down { state = .failed }
    }

    override func reset() {
        super.reset()
        focus?.touches.removeAll()
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
