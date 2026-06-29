import SwiftUI
import AVKit
import AVFoundation

// MARK: – Surface vidéo (AVPlayerLayer)
final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var onLayer: ((AVPlayerLayer) -> Void)? = nil

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let v = PlayerLayerUIView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        onLayer?(v.playerLayer)
        return v
    }
    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }
}

// MARK: – Modèle (AVPlayer + état + PiP)
final class CustomPlayerModel: NSObject, ObservableObject {
    let player = AVPlayer()
    @Published var isPlaying = true
    @Published var position:  Double = 0   // temps courant (s)
    @Published var startTime: Double = 0   // début de la fenêtre seekable
    @Published var endTime:   Double = 0   // fin (live edge / durée VOD)
    @Published var pipActive = false

    let isLive: Bool
    private let onProgress: (Double) -> Void
    private var timeObs: Any?
    private var pip: AVPictureInPictureController?

    init(url: URL, isLive: Bool, savedTime: Double, onProgress: @escaping (Double) -> Void) {
        self.isLive = isLive
        self.onProgress = onProgress
        super.init()
        load(url: url, seek: savedTime)
        timeObs = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] t in self?.tick(t) }
    }

    func load(url: URL, seek: Double = 0) {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        if seek > 5 { player.seek(to: CMTime(seconds: seek, preferredTimescale: 600)) }
        player.play(); isPlaying = true
    }

    private func tick(_ t: CMTime) {
        guard let item = player.currentItem else { return }
        if let range = item.seekableTimeRanges.last?.timeRangeValue, range.duration.seconds > 0 {
            startTime = range.start.seconds
            endTime   = (range.start + range.duration).seconds
        } else if item.duration.seconds.isFinite {
            startTime = 0; endTime = item.duration.seconds
        }
        if t.seconds.isFinite { position = t.seconds }
        if !isLive { onProgress(position) }
    }

    var atLiveEdge: Bool { isLive && (endTime - position) < 8 }

    func togglePlay() {
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }
    func seek(to s: Double) {
        let clamped = max(startTime, min(endTime, s))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        position = clamped
    }
    func seekBy(_ delta: Double) { seek(to: position + delta) }
    func goLive() { seek(to: endTime); if !isPlaying { togglePlay() } }

    // PiP
    func attachPiP(layer: AVPlayerLayer) {
        guard pip == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let p = AVPictureInPictureController(playerLayer: layer)
        p.delegate = self
        pip = p
    }
    func togglePiP() {
        guard let pip = pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() }
        else { pip.startPictureInPicture() }
    }

    func teardown() {
        if let o = timeObs { player.removeTimeObserver(o); timeObs = nil }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
    deinit { if let o = timeObs { player.removeTimeObserver(o) } }
}

extension CustomPlayerModel: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        pipActive = true; PlayerFullscreen.isActive = true
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        pipActive = false; PlayerFullscreen.isActive = false
    }
}

// MARK: – Lecteur custom
struct CustomVideoPlayer: View {
    let url: URL
    let isLive: Bool
    let dvrEnabled: Bool

    @EnvironmentObject private var store: AppStore
    @StateObject private var model: CustomPlayerModel
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>? = nil
    @State private var dragging = false
    @State private var dragValue: Double = 0
    @State private var seekFlash: String? = nil

    init(url: URL, isLive: Bool, dvrEnabled: Bool, savedTime: Double,
         onProgress: @escaping (Double) -> Void) {
        self.url = url; self.isLive = isLive; self.dvrEnabled = dvrEnabled
        _model = StateObject(wrappedValue: CustomPlayerModel(
            url: url, isLive: isLive, savedTime: savedTime, onProgress: onProgress))
    }

    private var canScrub: Bool { !isLive || dvrEnabled }
    private var sliderRange: ClosedRange<Double> {
        let lo = model.startTime
        return lo...max(model.endTime, lo + 1)
    }

    var body: some View {
        ZStack {
            PlayerLayerView(player: model.player) { layer in model.attachPiP(layer: layer) }

            // Zones double-tap pour reculer / avancer de 10 s
            HStack(spacing: 0) {
                seekZone(seconds: -10, label: "−10s")
                seekZone(seconds: 10,  label: "+10s")
            }

            if let flash = seekFlash {
                Text(flash)
                    .font(.system(size: 22, weight: .black)).foregroundColor(.white)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(Color.black.opacity(0.55)).clipShape(Capsule())
                    .transition(.opacity)
            }

            if showControls { controls }
        }
        .aspectRatio(16/9, contentMode: .fit)
        .background(Color.black)
        .clipped()
        .onChange(of: url) { model.load(url: $0) }
        .onAppear { scheduleAutoHide() }
        .onDisappear { hideTask?.cancel(); model.teardown() }
    }

    @ViewBuilder private var controls: some View {
        ZStack {
            Color.black.opacity(0.25).contentShape(Rectangle()).onTapGesture { toggleControls() }

            // Play / Pause centré
            Button { model.togglePlay(); scheduleAutoHide() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28, weight: .black)).foregroundColor(.white)
                    .frame(width: 62, height: 62)
                    .background(Color.black.opacity(0.45)).clipShape(Circle())
            }

            VStack {
                HStack {
                    Spacer()
                    Button { model.togglePiP() } label: {
                        Image(systemName: "pip.enter")
                            .font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                            .frame(width: 34, height: 34)
                            .background(Color.black.opacity(0.45)).clipShape(Circle())
                    }
                }
                Spacer()
                bottomBar
            }
            .padding(10)
        }
        .transition(.opacity)
    }

    @ViewBuilder private var bottomBar: some View {
        HStack(spacing: 10) {
            if isLive {
                Button { model.goLive() } label: {
                    HStack(spacing: 5) {
                        Circle().fill(model.atLiveEdge ? Color.tLive : Color.tMuted)
                            .frame(width: 7, height: 7)
                        Text(store.t("go_live"))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(model.atLiveEdge ? .white : .tMuted)
                    }
                }
            } else {
                Text(timeStr(model.position))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(.white)
            }

            if canScrub {
                Slider(
                    value: Binding(get: { dragging ? dragValue : model.position },
                                   set: { dragValue = $0 }),
                    in: sliderRange,
                    onEditingChanged: { editing in
                        if editing { dragValue = model.position }   // évite le saut à 0
                        dragging = editing
                        if !editing { model.seek(to: dragValue); scheduleAutoHide() }
                    }
                )
                .tint(.tPrimary)
            } else {
                Spacer()
            }

            if !isLive {
                Text(timeStr(model.endTime))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(.tMuted)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.black.opacity(0.45)).cornerRadius(10)
    }

    private func seekZone(seconds: Double, label: String) -> some View {
        Color.clear.contentShape(Rectangle())
            .onTapGesture(count: 2) {
                model.seekBy(seconds)
                withAnimation { seekFlash = label }
                Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    withAnimation { seekFlash = nil }
                }
            }
            .onTapGesture { toggleControls() }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        if showControls { scheduleAutoHide() }
    }
    private func scheduleAutoHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if !dragging { withAnimation { showControls = false } }
        }
    }
    private func timeStr(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s); let h = t / 3600; let m = (t % 3600) / 60; let sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }
}
