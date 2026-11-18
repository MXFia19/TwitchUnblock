import SwiftUI
import UIKit
import MediaPlayer
import AVFoundation

// ═══════════════════════════════════════════════════════════════════════════
//  Volume et luminosité au doigt, comme dans VLC : en paysage, dans le
//  lecteur de l'app, un glissé vertical sur le tiers droit de l'image règle
//  le volume du téléphone, sur le tiers gauche la luminosité de l'écran, avec
//  un petit indicateur au milieu de l'image. Le tiers du milieu garde le
//  glissé vers le bas qui réduit le lecteur.
//
//  Réglage « Volume et luminosité en glissant » (Réglages → Lecteur), coupé
//  d'office : sur les côtés de l'image, il prend la place de ce glissé vers
//  le bas. Rien en portrait (le glissé vers le bas y reste partout), ni sur
//  Apple TV, ni sur Mac (app iPhone sur Mac Apple Silicon, par PlayCover : la
//  luminosité n'y a pas de sens, et rien ne garantit que le volume passe par
//  MPVolumeView).
//
//  Le geste lui-même est celui du lecteur (ImmersivePlayer.panGesture) : il
//  passe après la barre de lecture, le pincement et l'image agrandie, et se
//  décide dès son départ, comme le glissé vers le bas.
// ═══════════════════════════════════════════════════════════════════════════

enum PlayerSwipe: Equatable {
    case volume, brightness

    /// Ni sur Mac (voir l'en-tête) : le réglage n'y est pas proposé.
    static var supported: Bool { !ProcessInfo.processInfo.isiOSAppOnMac }

    /// Sens d'un geste parti d'un côté de l'image : vertical (vrai), de côté
    /// (faux), pas encore décidé (nil, moins de 8 points). Un glissé de côté
    /// ne règle rien.
    static func direction(for t: CGSize) -> Bool? {
        let dx = abs(t.width), dy = abs(t.height)
        guard max(dx, dy) >= 8 else { return nil }
        return dy > dx
    }

    /// Ce que règle un geste parti de `point` (repère de l'écran) : tiers
    /// gauche de `area`, la luminosité ; tiers droit, le volume ; nil au
    /// milieu, ou sur une image trop petite.
    static func zone(at point: CGPoint, in area: CGRect) -> PlayerSwipe? {
        guard area.width >= 120, area.height >= 120 else { return nil }
        let third = area.width / 3
        if point.x < area.minX + third { return .brightness }
        if point.x > area.maxX - third { return .volume }
        return nil
    }

    /// Course du doigt pour aller de 0 à 100 % : les trois quarts de la
    /// hauteur de l'image, 200 points au moins.
    static func travel(for height: CGFloat) -> CGFloat { max(200, height * 0.75) }

    /// Symbole de l'indicateur, selon le niveau.
    func icon(for level: CGFloat) -> String {
        switch self {
        case .volume:
            if level < 0.005 { return "speaker.slash.fill" }
            return level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        case .brightness:
            return level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        }
    }
}

/// Glissé en cours : ce qu'il règle, et la valeur au départ.
struct PlayerSwipeAdjust {
    let kind: PlayerSwipe
    let start: CGFloat
}

/// Cadre de la boîte du lecteur dans l'écran, repère des côtés du geste.
/// Une classe gardée en @State et changée en place : le relever ne redessine
/// rien (il bouge à chaque image d'un glissé vers le bas).
final class PlayerSwipeArea {
    var frame: CGRect = .zero
}

/// Ce que montre l'indicateur. Observé par lui seul : le lecteur ne se
/// redessine pas à chaque point du geste.
final class PlayerSwipeLevel: ObservableObject {
    @Published private(set) var kind: PlayerSwipe = .volume
    @Published private(set) var level: CGFloat = 0

    func show(_ kind: PlayerSwipe, _ level: CGFloat) {
        if self.kind != kind { self.kind = kind }
        set(level)
    }

    /// Au centième près : l'indicateur ne change qu'à chaque pour cent.
    func set(_ value: CGFloat) {
        let rounded = (min(1, max(0, value)) * 100).rounded() / 100
        if rounded != level { level = rounded }
    }
}

/// Volume du téléphone, réglé par le curseur d'une MPVolumeView (le seul
/// moyen qu'offre iOS), posée invisible dans le lecteur (SystemVolumeHost).
/// Cachée au repos : les boutons de volume gardent l'indicateur d'iOS.
/// Montrée (presque transparente) le temps du geste : iOS ne pose pas alors
/// le sien par-dessus celui du lecteur. Fil principal seulement.
enum SystemVolume {
    fileprivate static weak var view: MPVolumeView?
    private static var hide: DispatchWorkItem?

    private static var slider: UISlider? {
        view?.subviews.lazy.compactMap { $0 as? UISlider }.first
    }

    /// Volume actuel, de 0 à 1.
    static var current: CGFloat { CGFloat(AVAudioSession.sharedInstance().outputVolume) }

    static func begin() {
        hide?.cancel()
        hide = nil
        view?.isHidden = false
    }

    static func set(_ value: CGFloat) {
        guard let slider else { return }
        let v = Float(min(1, max(0, value)))
        guard abs(slider.value - v) >= 0.005 else { return }
        slider.value = v
        slider.sendActions(for: .valueChanged)
    }

    /// Fin du geste : recachée une seconde plus tard, le temps que le dernier
    /// changement passe sans l'indicateur d'iOS.
    static func end() {
        hide?.cancel()
        let work = DispatchWorkItem { view?.isHidden = true }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}

/// MPVolumeView du lecteur (voir SystemVolume) : un point, presque
/// transparente, cachée hors du geste, sans toucher.
struct SystemVolumeHost: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        view.isHidden = true
        SystemVolume.view = view
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}
}

/// Luminosité de l'écran : celle d'iOS, comme le curseur du Centre de
/// contrôle (elle reste après le lecteur). Fil principal seulement.
enum ScreenBrightness {
    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first?.screen
    }

    static var current: CGFloat { screen?.brightness ?? 0.5 }

    static func set(_ value: CGFloat) {
        guard let screen else { return }
        let v = min(1, max(0, value))
        if abs(screen.brightness - v) >= 0.005 { screen.brightness = v }
    }
}

/// Indicateur du geste : ce qui est réglé, une barre et le pourcentage.
struct PlayerSwipeHUD: View {
    @ObservedObject var state: PlayerSwipeLevel
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.kind.icon(for: state.level))
                .font(.system(size: 15, weight: .bold))
                .frame(width: 24)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(Color.white)
                    .frame(width: 110 * state.level)
            }
            .frame(width: 110, height: 5)
            Text(Double(state.level).formatted(.percent.precision(.fractionLength(0))
                                                .locale(Locale(identifier: store.lang.rawValue))))
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .frame(minWidth: 42, alignment: .trailing)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Capsule().fill(Color.black.opacity(0.65)))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
