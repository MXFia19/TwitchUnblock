import SwiftUI
#if canImport(VLCKitSPM)
import VLCKitSPM

// MARK: – Modèle VLC
final class VLCPlayerModel: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()
    @Published var isPlaying = true
    @Published var position: Float = 0      // 0..1 dans la fenêtre seekable
    @Published var timeText = "0:00"
    @Published var lengthText = ""

    let isLive: Bool
    private let onProgress: (Double) -> Void
    private var pendingSeek: Double
    private var didSeek = false

    init(url: URL, isLive: Bool, savedTime: Double, onProgress: @escaping (Double) -> Void) {
        self.isLive = isLive
        self.onProgress = onProgress
        self.pendingSeek = savedTime
        super.init()
        player.delegate = self
        player.media = VLCMedia(url: url)
        player.play()
    }

    func attach(_ view: UIView) { player.drawable = view }

    func load(url: URL) {
        didSeek = true                 // pas de restauration sur changement de qualité
        player.stop()
        player.media = VLCMedia(url: url)
        player.play()
    }

    func togglePlay() {
        if player.isPlaying { player.pause() } else { player.play() }
        isPlaying = player.isPlaying
    }
    func seek(position p: Float) { player.position = max(0, min(1, p)) }
    func jump(_ secs: Int32) {
        if secs < 0 { player.jumpBackward(-secs) } else { player.jumpForward(secs) }
    }
    func goLive() { player.position = 1.0 }

    // MARK: VLCMediaPlayerDelegate
    func mediaPlayerTimeChanged(_ notification: Notification) {
        isPlaying = player.isPlaying
        position  = player.position
        timeText  = player.time.stringValue ?? "0:00"
        if let len = player.media?.length.stringValue, !len.isEmpty { lengthText = len }

        // Restauration de la position VOD (une seule fois, après démarrage).
        if !didSeek, pendingSeek > 5, !isLive {
            didSeek = true
            player.time = VLCTime(int: Int32(pendingSeek * 1000))
        }
        if !isLive {
            let secs = Double(player.time.intValue) / 1000.0
            if secs > 0 { onProgress(secs) }
        }
    }
    func mediaPlayerStateChanged(_ notification: Notification) {
        isPlaying = player.isPlaying
    }

    func teardown() {
        player.stop()
        player.drawable = nil
        player.delegate = nil
    }
}

// MARK: – Surface de rendu VLC
struct VLCDrawableView: UIViewRepresentable {
    let model: VLCPlayerModel
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        model.attach(v)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: – Lecteur VLC
struct VLCVideoPlayer: View {
    let url: URL
    let isLive: Bool

    @EnvironmentObject private var store: AppStore
    @StateObject private var model: VLCPlayerModel
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>? = nil
    @State private var dragging = false
    @State private var dragValue: Float = 0
    @State private var seekFlash: String? = nil

    init(url: URL, isLive: Bool, savedTime: Double, onProgress: @escaping (Double) -> Void) {
        self.url = url; self.isLive = isLive
        _model = StateObject(wrappedValue: VLCPlayerModel(
            url: url, isLive: isLive, savedTime: savedTime, onProgress: onProgress))
    }

    var body: some View {
        ZStack {
            VLCDrawableView(model: model)

            HStack(spacing: 0) {
                seekZone(secs: -10, label: "−10s")
                seekZone(secs: 10,  label: "+10s")
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

            Button { model.togglePlay(); scheduleAutoHide() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28, weight: .black)).foregroundColor(.white)
                    .frame(width: 62, height: 62)
                    .background(Color.black.opacity(0.45)).clipShape(Circle())
            }

            VStack {
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
                        Circle().fill(model.position > 0.97 ? Color.tLive : Color.tMuted)
                            .frame(width: 7, height: 7)
                        Text(store.t("go_live"))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(model.position > 0.97 ? .white : .tMuted)
                    }
                }
            } else {
                Text(model.timeText)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(.white)
            }

            Slider(
                value: Binding(get: { dragging ? dragValue : model.position },
                               set: { dragValue = $0 }),
                in: 0...1,
                onEditingChanged: { editing in
                    if editing { dragValue = model.position }
                    dragging = editing
                    if !editing { model.seek(position: dragValue); scheduleAutoHide() }
                }
            )
            .tint(.tPrimary)

            if !isLive && !model.lengthText.isEmpty {
                Text(model.lengthText)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(.tMuted)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.black.opacity(0.45)).cornerRadius(10)
    }

    private func seekZone(secs: Int32, label: String) -> some View {
        Color.clear.contentShape(Rectangle())
            .onTapGesture(count: 2) {
                model.jump(secs)
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
}
#endif
