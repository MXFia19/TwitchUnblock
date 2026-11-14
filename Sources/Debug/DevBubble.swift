import UIKit
import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Bulle flottante de « TU Dev » (voir DevTools) : posée dans une fenêtre à
//  part, au-dessus de toute l'app, sur tous les écrans. Un toucher ouvre
//  l'inspecteur, un glissé la déplace (elle se colle au bord le plus proche).
//  Hors de la bulle, les touchers passent à l'app.
// ═══════════════════════════════════════════════════════════════════════════

@MainActor final class DevBubble {
    static let shared = DevBubble()
    private var window: DevWindow?

    func attach() {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let w = DevWindow(windowScene: scene)
        w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        w.backgroundColor = .clear
        w.rootViewController = DevRootController()
        w.isHidden = false
        window = w
    }
}

/// Ne répond qu'à la bulle, ou partout quand l'inspecteur est ouvert.
final class DevWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let root = rootViewController as? DevRootController else { return nil }
        if root.presentedViewController != nil { return super.hitTest(point, with: event) }
        let p = root.bubble.convert(point, from: self)
        return root.bubble.point(inside: p, with: event) ? root.bubble : nil
    }
}

final class DevRootController: UIViewController, UIAdaptivePresentationControllerDelegate {
    let bubble = DevBubbleView()
    private var placed = false
    /// Fenêtre de l'app, rendue « clé » à la fermeture de l'inspecteur (son
    /// champ de recherche a besoin du clavier, donc de notre fenêtre).
    private weak var previousKey: UIWindow?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.addSubview(bubble)
        bubble.onTap = { [weak self] in self?.openInspector() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let area = view.bounds.inset(by: view.safeAreaInsets)
        guard area.width > 0 else { return }
        if !placed {
            placed = true
            bubble.frame = CGRect(x: area.maxX - 52, y: area.minY + 140, width: 46, height: 46)
        } else {
            // Rotation : la bulle reste à l'écran.
            bubble.keep(in: area, animated: false)
        }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

    private func openInspector() {
        guard presentedViewController == nil else { return }
        previousKey = view.window?.windowScene?.windows.first { $0.isKeyWindow && $0 !== view.window }
        view.window?.makeKey()
        let host = UIHostingController(rootView: DevInspectorView(onClose: { [weak self] in self?.closeInspector() }))
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        host.presentationController?.delegate = self
        present(host, animated: true)
    }

    private func closeInspector() {
        dismiss(animated: true) { [weak self] in self?.restoreKey() }
    }

    /// Feuille baissée d'un glissé.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        restoreKey()
    }

    private func restoreKey() {
        previousKey?.makeKey()
        previousKey = nil
    }
}

final class DevBubbleView: UIView {
    var onTap: () -> Void = {}
    private let icon = UIImageView(image: UIImage(systemName: "network"))
    private let badge = UILabel()
    private var timer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.57, green: 0.27, blue: 1, alpha: 0.92)
        layer.cornerRadius = 23
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        addSubview(icon)
        badge.font = .systemFont(ofSize: 10, weight: .bold)
        badge.textColor = .white
        badge.textAlignment = .center
        badge.backgroundColor = .systemRed
        badge.layer.cornerRadius = 8
        badge.layer.masksToBounds = true
        badge.isHidden = true
        addSubview(badge)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged(_:))))
        // Pastille : requêtes en erreur de la dernière minute.
        timer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(refresh),
                                     userInfo: nil, repeats: true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = bounds.insetBy(dx: 12, dy: 12)
        badge.frame = CGRect(x: bounds.maxX - 15, y: -4, width: 20, height: 16)
    }

    @objc private func refresh() {
        let since = Date().addingTimeInterval(-60)
        let failed = NetLog.shared.snapshot.reversed().prefix { $0.started > since }.filter(\.failed).count
        badge.isHidden = failed == 0
        badge.text = failed > 99 ? "99+" : "\(failed)"
    }

    @objc private func tapped() { onTap() }

    @objc private func dragged(_ g: UIPanGestureRecognizer) {
        guard let parent = superview else { return }
        let t = g.translation(in: parent)
        center = CGPoint(x: center.x + t.x, y: center.y + t.y)
        g.setTranslation(.zero, in: parent)
        if g.state == .ended || g.state == .cancelled {
            keep(in: parent.bounds.inset(by: parent.safeAreaInsets), animated: true)
        }
    }

    /// Dans la zone sûre, collée au bord gauche ou droit le plus proche.
    func keep(in area: CGRect, animated: Bool) {
        guard area.width > bounds.width else { return }
        var c = center
        c.x = c.x < area.midX ? area.minX + bounds.width / 2 + 4 : area.maxX - bounds.width / 2 - 4
        c.y = min(max(c.y, area.minY + bounds.height / 2), area.maxY - bounds.height / 2)
        if animated {
            UIView.animate(withDuration: 0.2) { self.center = c }
        } else {
            center = c
        }
    }
}
