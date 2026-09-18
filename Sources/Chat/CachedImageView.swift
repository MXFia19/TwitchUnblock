import SwiftUI
import UIKit

// MARK: – Emote animée (UIImageView : SwiftUI.Image n'anime ni GIF ni WebP animé)
struct AnimatedImageView: UIViewRepresentable {
    let image: CachedImage

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFit
        v.clipsToBounds = true
        v.isUserInteractionEnabled = false
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        apply(v)
        return v
    }

    func updateUIView(_ v: UIImageView, context: Context) { apply(v) }

    static func dismantleUIView(_ v: UIImageView, coordinator: ()) {
        v.stopAnimating()
        v.animationImages = nil
    }

    private func apply(_ v: UIImageView) {
        // Vue recyclée sur la même emote → on relance juste l'animation.
        if v.animationImages?.count == image.frames.count {
            if !v.isAnimating { v.startAnimating() }
            return
        }
        v.animationImages     = image.frames
        v.animationDuration   = max(0.05, image.duration)
        v.animationRepeatCount = 0                 // boucle infinie
        v.image               = image.frames.first
        v.startAnimating()
    }
}

// MARK: – Emote / badge avec cache
struct CachedEmoteImage: View {
    let url: String
    let name: String
    let height: CGFloat
    /// Repli textuel si le chargement échoue (utile en chat, pas pour les badges).
    let showsNameFallback: Bool

    @State private var img: CachedImage?
    @State private var failed = false

    init(url: String, name: String, height: CGFloat = 24, showsNameFallback: Bool = true) {
        self.url = url
        self.name = name
        self.height = height
        self.showsNameFallback = showsNameFallback
        // Chemin rapide : déjà en mémoire ⇒ affiché dès la première frame,
        // sans passer par un état de chargement (c'est ça qui supprime la latence
        // et le clignotement quand le chat défile vite).
        _img = State(initialValue: ImageCache.shared.cached(url))
    }

    var body: some View {
        Group {
            if let img {
                if img.isAnimated {
                    AnimatedImageView(image: img)
                        .frame(width: height * img.aspect, height: height)
                } else if let ui = img.first {
                    Image(uiImage: ui)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFit()
                        .frame(width: height * img.aspect, height: height)
                }
            } else if failed, showsNameFallback, !name.isEmpty {
                Text(name).font(.system(size: 11)).foregroundColor(.tMuted)
            } else {
                Color.clear.frame(width: height, height: height)
            }
        }
        .task(id: url) {
            if img != nil { return }
            if let hit = ImageCache.shared.cached(url) { img = hit; return }
            if let loaded = await ImageCache.shared.image(for: url) { img = loaded }
            else { failed = true }
        }
    }
}
