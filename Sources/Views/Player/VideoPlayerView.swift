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
    /// Latence mesurée du direct (nil si la playlist ne porte pas d'horodatage).
    var onLatency: (Double?) -> Void = { _ in }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let player = AVPlayer(url: url)
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.showsPlaybackControls = true
        vc.delegate = context.coordinator
        context.coordinator.playerVC = vc
        context.coordinator.setupObserver(player: player, onProgress: onProgress, onLatency: onLatency)
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
            context.coordinator.setupObserver(player: player, onProgress: onProgress, onLatency: onLatency)
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

        func setupObserver(player: AVPlayer,
                           onProgress: @escaping (Double) -> Void,
                           onLatency: @escaping (Double?) -> Void = { _ in }) {
            if let existing = timeObserver { playerRef?.removeTimeObserver(existing) }
            playerRef = player
            // 1 s : assez fin pour synchroniser le chat des VODs.
            let interval = CMTime(seconds: 1, preferredTimescale: 600)
            timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak player] time in
                onProgress(time.seconds)
                // Latence = écart entre l'heure réelle et l'horodatage du segment lu
                // (EXT-X-PROGRAM-DATE-TIME de la playlist HLS). nil si absent.
                if let date = player?.currentItem?.currentDate() {
                    onLatency(Date().timeIntervalSince(date))
                } else {
                    onLatency(nil)
                }
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
    /// Latence du direct remontee au parent (synchro auto du chat).
    var onLatency: (Double?) -> Void = { _ in }
    // Actions affichees a cote du bouton Source (nil = bouton masque).
    var onChat: (() -> Void)? = nil
    var onRewind: (() -> Void)? = nil
    var onBackToLive: (() -> Void)? = nil

    @EnvironmentObject private var store: AppStore
    @State private var selectedQuality: String = ""
    @State private var showQualityPicker = false
    @State private var currentTime: Double = 0
    @State private var lastPersisted: Double = -99
    @State private var latency: Double? = nil

    /// Un direct n'a pas d'identifiant de VOD : c'est ce qui distingue les deux modes.
    private var isLive: Bool { vodId == nil }

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
            // Tous les boutons partagent la même hauteur fixe : sinon une icône
            // SF Symbol (taille « body » par défaut) rend son bouton plus haut
            // que celui qui ne contient que du texte en 12 pt.
            HStack(spacing: 8) {
                // Qualité : bouton compact, il laisse la place aux actions.
                Button { showQualityPicker.toggle() } label: {
                    actionLabel(text: qualityLabel(selectedQuality), emoji: "🎬",
                                fg: .white, bg: Color.tPrimary)
                }

                if let rewind = onRewind {
                    Button(action: rewind) {
                        actionLabel(text: store.t("rewind"), icon: "gobackward",
                                    fg: .tPrimary, bg: Color.tPrimary.opacity(0.15),
                                    border: .tPrimary)
                    }
                }

                if let backLive = onBackToLive {
                    Button(action: backLive) {
                        actionLabel(text: store.t("back_to_live"), dot: true,
                                    fg: .white, bg: Color.tLive)
                    }
                }

                Spacer(minLength: 0)

                if let chat = onChat {
                    Button(action: chat) {
                        actionLabel(text: "Chat", icon: "bubble.left.fill",
                                    fg: .white, bg: Color.tPrimary)
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
                .padding(.bottom, 12)
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
            savedTime: vodId.map { store.getVodProgress($0) } ?? 0,
            onProgress: { time in
                currentTime = time
                onTime(time)
                // Progression persistee au plus toutes les 5 s (l'observateur tourne a 1 s,
                // inutile d'ecrire dans UserDefaults a chaque tick).
                if let id = vodId, abs(time - lastPersisted) >= 5 {
                    lastPersisted = time
                    store.setVodProgress(id, time: time)
                }
            },
            onLatency: { value in
                // Seul le direct a une latence exploitable.
                let measured = isLive ? value : nil
                if latency != measured { latency = measured }
                onLatency(measured)
            }
        )
        .aspectRatio(16/9, contentMode: .fit)
        .background(Color.black)
        .overlay(alignment: .topLeading) {
            if store.showLatency, isLive {
                latencyChip.padding(8)
            }
        }
    }

    // MARK: – Débogage : pastille de latence
    @ViewBuilder
    private var latencyChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform.path.ecg").font(.system(size: 9, weight: .bold))
            Text(latency.map { String(format: "%.1f s", max(0, $0)) } ?? "—")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
        }
        .foregroundColor(latencyColor)
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(Color.black.opacity(0.55))
        .cornerRadius(6)
    }

    /// Vert < 8 s (faible latence), jaune < 20 s, rouge au-delà.
    private var latencyColor: Color {
        guard let l = latency else { return .tMuted }
        if l < 8  { return .tSuccess }
        if l < 20 { return .tWarning }
        return .tDanger
    }

    // MARK: – Bouton de la barre d'actions (hauteur commune)
    @ViewBuilder
    private func actionLabel(text: String, emoji: String? = nil, icon: String? = nil,
                             dot: Bool = false, fg: Color, bg: Color,
                             border: Color? = nil) -> some View {
        HStack(spacing: 4) {
            if let emoji { Text(emoji).font(.system(size: 12)) }
            if let icon  { Image(systemName: icon).font(.system(size: 12, weight: .bold)) }
            if dot       { Circle().fill(fg).frame(width: 6, height: 6) }
            Text(text).font(.system(size: 12, weight: .bold))
        }
        .foregroundColor(fg)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(bg)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(border ?? .clear, lineWidth: border == nil ? 0 : 1)
        )
    }

    private func qualityLabel(_ q: String) -> String {
        q.replacingOccurrences(of: "chunked", with: "Source")
         .replacingOccurrences(of: "source",  with: "Source")
    }
}
