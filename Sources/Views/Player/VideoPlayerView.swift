import SwiftUI
import AVKit
import AVFoundation

// État plein écran partagé : permet à ChatView de ne pas couper l'IRC/les points
// quand le lecteur passe en plein écran (ce qui déclenche un onDisappear transitoire).
enum PlayerFullscreen {
    static var isActive = false
}

// MARK: – AVPlayerViewController wrapper
struct NativeVideoPlayer: UIViewControllerRepresentable {
    let url: URL
    let savedTime: Double
    let onProgress: (Double) -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let player = AVPlayer(url: url)
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.showsPlaybackControls = true
        vc.delegate = context.coordinator
        context.coordinator.playerVC = vc
        context.coordinator.setupObserver(player: player, onProgress: onProgress)
        // Restore position
        if savedTime > 5 {
            player.seek(to: CMTime(seconds: savedTime, preferredTimescale: 600))
        }
        player.play()
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        let currentURL = (vc.player?.currentItem?.asset as? AVURLAsset)?.url
        if currentURL != url {
            // ✨ LA CORRECTION EST ICI : On force l'ancien lecteur à se mettre en pause 
            // avant de le remplacer par la nouvelle qualité !
            vc.player?.pause()
            
            let player = AVPlayer(url: url)
            vc.player = player
            context.coordinator.setupObserver(player: player, onProgress: onProgress)
            if savedTime > 5 {
                player.seek(to: CMTime(seconds: savedTime, preferredTimescale: 600))
            }
            player.play()
        }
    }

    // Force l'arrêt de la vidéo quand la vue est détruite
    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        vc.player?.pause()
        vc.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        weak var playerVC: AVPlayerViewController?
        private var timeObserver: Any?
        private var playerRef: AVPlayer?

        // MARK: Plein écran — maintient PlayerFullscreen.isActive à jour
        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            PlayerFullscreen.isActive = true
        }
        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            coordinator.animate(alongsideTransition: nil) { _ in
                PlayerFullscreen.isActive = false
            }
        }

        override init() {
            super.init()
            // Coupe instantanément le son si on reçoit le signal "ForceStopVideo" depuis la croix
            NotificationCenter.default.addObserver(forName: NSNotification.Name("ForceStopVideo"), object: nil, queue: .main) { [weak self] _ in
                self?.playerVC?.player?.pause()
                self?.playerVC?.player = nil
            }
        }

        func setupObserver(player: AVPlayer, onProgress: @escaping (Double) -> Void) {
            if let existing = timeObserver { playerRef?.removeTimeObserver(existing) }
            playerRef = player
            // 1 s : assez fin pour synchroniser le chat des VODs.
            let interval = CMTime(seconds: 1, preferredTimescale: 600)
            timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
                onProgress(time.seconds)
            }
        }

        deinit {
            if let obs = timeObserver { playerRef?.removeTimeObserver(obs) }
            NotificationCenter.default.removeObserver(self)
        }
    }
}

// MARK: – Full Video Player View
struct VideoPlayerView: View {
    let qualityLinks: QualityLinks
    let vodId: String?
    /// Mode compact (chat ouvert) : masque la barre Source / le lien pour laisser
    /// un maximum de place au chat. Seul le lecteur reste visible.
    var compact: Bool = false
    /// Position de lecture remontee au parent (utilisee par le chat des VODs).
    var onTime: (Double) -> Void = { _ in }
    // Actions affichees a cote du bouton Source (nil = bouton masque).
    var onChat: (() -> Void)? = nil
    var onRewind: (() -> Void)? = nil
    var onBackToLive: (() -> Void)? = nil

    @EnvironmentObject private var store: AppStore
    @State private var selectedQuality: String = ""
    @State private var showQualityPicker = false
    @State private var currentTime: Double = 0
    @State private var lastPersisted: Double = -99

    private var qualities: [String] { sortQualities(Array(qualityLinks.keys)) }
    private var currentURL: URL? { qualityLinks[selectedQuality].flatMap(URL.init) }

    var body: some View {
        VStack(spacing: 0) {

            // ── Player ──────────────────────────────────────────────
            if let url = currentURL {
                nativePlayer(url: url)
            }

            // En mode compact (chat ouvert) on n'affiche que le lecteur.
            if !compact {
            // ── Options bar ─────────────────────────────────────────
            HStack(spacing: 8) {
                // Qualité : bouton compact, il laisse la place aux actions.
                Button { showQualityPicker.toggle() } label: {
                    Text("🎬 \(qualityLabel(selectedQuality))")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(Color.tPrimary)
                        .cornerRadius(8)
                }

                if let rewind = onRewind {
                    Button(action: rewind) {
                        HStack(spacing: 4) {
                            Image(systemName: "gobackward")
                            Text(store.t("rewind")).font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(.tPrimary)
                        .lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 10)
                        .background(Color.tPrimary.opacity(0.15))
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.tPrimary, lineWidth: 1))
                    }
                }

                if let backLive = onBackToLive {
                    Button(action: backLive) {
                        HStack(spacing: 4) {
                            Circle().fill(Color.white).frame(width: 6, height: 6)
                            Text(store.t("back_to_live")).font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 10)
                        .background(Color.tLive)
                        .cornerRadius(8)
                    }
                }

                Spacer(minLength: 0)

                if let chat = onChat {
                    Button(action: chat) {
                        HStack(spacing: 4) {
                            Image(systemName: "bubble.left.fill")
                            Text("Chat").font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(Color.tPrimary)
                        .cornerRadius(8)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .background(Color.tCard)

            // ── Quality picker ──────────────────────────────────────
            if showQualityPicker {
                VStack(spacing: 0) {
                    ForEach(qualities, id: \.self) { q in
                        Button {
                            currentTime = 0
                            selectedQuality = q
                            showQualityPicker = false
                        } label: {
                            HStack {
                                Text(q == selectedQuality ? "✓  " : "    ")
                                    .foregroundColor(q == selectedQuality ? .tPrimary : .clear)
                                Text(qualityLabel(q))
                                    .foregroundColor(q == selectedQuality ? .tPrimary : .tMuted)
                                    .fontWeight(q == selectedQuality ? .bold : .semibold)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        Divider().background(Color.tBorder)
                    }
                }
                .background(Color.tSurface)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.tBorder, lineWidth: 1))
                .padding(.horizontal, 12)
            }

            // ── URL bar ─────────────────────────────────────────────
            if let rawURL = qualityLinks[selectedQuality] {
                Text(rawURL)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.tPurple)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.tSurface)
                    .cornerRadius(8)
                    .padding([.horizontal, .bottom], 12)
            }
            } // fin if !compact
        }
        .background(Color.tCard)
        .cornerRadius(16)
        .onAppear {
            if selectedQuality.isEmpty { selectedQuality = qualities.first ?? "" }
        }
    }

    // Lecteur natif (AVPlayerViewController) avec PiP + reprise de position.
    @ViewBuilder
    private func nativePlayer(url: URL) -> some View {
        NativeVideoPlayer(
            url: url,
            savedTime: vodId.map { store.getVodProgress($0) } ?? 0
        ) { time in
            currentTime = time
            onTime(time)
            // Progression persistee au plus toutes les 5 s (l'observateur tourne a 1 s,
            // inutile d'ecrire dans UserDefaults a chaque tick).
            if let id = vodId, abs(time - lastPersisted) >= 5 {
                lastPersisted = time
                store.setVodProgress(id, time: time)
            }
        }
        .aspectRatio(16/9, contentMode: .fit)
        .background(Color.black)
    }

    private func qualityLabel(_ q: String) -> String {
        q.replacingOccurrences(of: "chunked", with: "Source")
         .replacingOccurrences(of: "source",  with: "Source")
    }
}
