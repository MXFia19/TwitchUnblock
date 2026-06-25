import SwiftUI
import AVKit
import AVFoundation

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

    final class Coordinator {
        weak var playerVC: AVPlayerViewController?
        private var timeObserver: Any?
        private var playerRef: AVPlayer?

        init() {
            // Coupe instantanément le son si on reçoit le signal "ForceStopVideo" depuis la croix
            NotificationCenter.default.addObserver(forName: NSNotification.Name("ForceStopVideo"), object: nil, queue: .main) { [weak self] _ in
                self?.playerVC?.player?.pause()
                self?.playerVC?.player = nil
            }
        }

        func setupObserver(player: AVPlayer, onProgress: @escaping (Double) -> Void) {
            if let existing = timeObserver { playerRef?.removeTimeObserver(existing) }
            playerRef = player
            let interval = CMTime(seconds: 5, preferredTimescale: 600)
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

    @EnvironmentObject private var store: AppStore
    @State private var selectedQuality: String = ""
    @State private var showQualityPicker = false
    @State private var showExternalSheet  = false
    @State private var currentTime: Double = 0

    private var qualities: [String] { sortQualities(Array(qualityLinks.keys)) }
    private var currentURL: URL? { qualityLinks[selectedQuality].flatMap(URL.init) }

    var body: some View {
        VStack(spacing: 0) {

            // ── Player ──────────────────────────────────────────────
            if let url = currentURL {
                NativeVideoPlayer(
                    url: url,
                    savedTime: vodId.map { store.getVodProgress($0) } ?? 0
                ) { time in
                    currentTime = time
                    if let id = vodId { store.setVodProgress(id, time: time) }
                }
                .aspectRatio(16/9, contentMode: .fit)
                .background(Color.black)
            }

            // En mode compact (chat ouvert) on n'affiche que le lecteur.
            if !compact {
            // ── Options bar ─────────────────────────────────────────
            HStack(spacing: 8) {
                Button {
                    showQualityPicker.toggle()
                    showExternalSheet = false
                } label: {
                    Text("🎬 \(qualityLabel(selectedQuality))")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.tPrimary)
                        .cornerRadius(8)
                }

                Button {
                    showExternalSheet.toggle()
                    showQualityPicker = false
                } label: {
                    Text("📤")
                        .font(.system(size: 16))
                        .frame(width: 44, height: 38)
                        .background(Color.tSurface)
                        .cornerRadius(8)
                }
            }
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

            // ── External apps sheet ─────────────────────────────────
            if showExternalSheet, let rawURL = qualityLinks[selectedQuality] {
                VStack(spacing: 8) {
                    extButton("🟠 \(store.t("open_vlc"))", color: .tVLC) {
                        open(scheme: "vlc://\(rawURL)")
                    }
                    extButton("🔵 \(store.t("open_outplayer"))", color: .tOutplayer) {
                        open(scheme: "outplayer://\(rawURL)")
                    }
                    extButton("🔴 \(store.t("open_infuse"))", color: .tInfuse) {
                        let encoded = rawURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? rawURL
                        open(scheme: "infuse://x-callback-url/play?url=\(encoded)")
                    }
                    extButton("📋 \(store.t("btn_copy"))", color: .tSurface) {
                        UIPasteboard.general.string = rawURL
                        showExternalSheet = false
                    }
                    extButton("Fermer", color: Color(hex: "333333"), textColor: .tMuted) {
                        showExternalSheet = false
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
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

    @ViewBuilder
    private func extButton(_ label: String, color: Color, textColor: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(textColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(color)
                .cornerRadius(10)
        }
    }

    private func open(scheme: String) {
        guard let url = URL(string: scheme) else { return }
        UIApplication.shared.open(url)
        showExternalSheet = false
    }

    private func qualityLabel(_ q: String) -> String {
        q.replacingOccurrences(of: "chunked", with: "Source")
         .replacingOccurrences(of: "source",  with: "Source")
    }
}
