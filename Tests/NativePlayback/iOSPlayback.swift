import SwiftUI
import AVFoundation

@MainActor
final class PlaybackProbe: ObservableObject {
    let player = AVPlayer()
    @Published var remaining: Int?
    private var started = false
    private var layer: AVPlayerLayer?

    init() {
        let url = URL(string: "tulivebuffered://127.0.0.1:8765/midroll-ios.m3u8")!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(LivePlaylistLoader.shared, queue: LivePlaylistLoader.shared.queue)
        let item = AVPlayerItem(asset: asset)
        AdBreakMonitor.attach(to: item)
        player.replaceCurrentItem(with: item)
        player.isMuted = true
    }

    func attach(_ layer: AVPlayerLayer) {
        self.layer = layer
        guard !started else { return }
        started = true
        Task { await run() }
    }

    private func run() async {
        player.play()
        var checks = 0, heldChecks = 0, failures = 0
        var played = false, sawBreak = false
        var samples: [[String: Any]] = []
        for _ in 0..<80 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let item = player.currentItem, let layer else { break }
            let position = player.currentTime().seconds
            let brk = AdBreakMonitor.monitor(of: item)?.playbackBreak(on: player)
            remaining = brk.map { max(1, Int($0.brk.end.timeIntervalSince($0.clock).rounded(.up))) }
            if brk != nil { sawBreak = true }
            if layer.isReadyForDisplay, position > 0.5 {
                let size = CGSize(width: 160, height: 90)
                checks += 1
                if position >= 6 && position < 12 { heldChecks += 1 }
                let actual = layer.frame.width / layer.frame.height
                let expected = size.width / size.height
                if layer.videoGravity != .resize || !actual.isFinite || abs(actual - expected) > 0.001 { failures += 1 }
                samples.append(["time": position, "frameAspect": expected, "layerAspect": actual,
                                "ad": brk != nil])
            }
            if item.status == .failed { break }
            if position > 16 && player.timeControlStatus == .playing { played = true; break }
        }
        player.pause()
        var adRequests: [String] = []
        var statsOK = false
        if let (data, _) = try? await URLSession.shared.data(from: URL(string: "https://127.0.0.1:8765/stats")!),
           let stats = try? JSONSerialization.jsonObject(with: data) as? [String: [String]],
           let requests = stats["midroll-ios"] {
            adRequests = requests.filter { ["segment003.ts", "segment004.ts", "segment005.ts"].contains($0) }
            statsOK = !requests.isEmpty
        }
        let result: [String: Any] = ["ok": played && checks > 0 && heldChecks > 0 && failures == 0 && sawBreak && statsOK && adRequests.isEmpty,
                                    "played": played, "geometryChecks": checks, "heldChecks": heldChecks,
                                    "geometryFailures": failures, "sawBreak": sawBreak,
                                    "adRequests": adRequests, "samples": samples]
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("result.json")
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: path, options: .atomic)
        }
    }
}

struct ProbeView: View {
    @ObservedObject var model: PlaybackProbe
    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                PlayerLayerView(player: model.player, onLayer: { model.attach($0) })
                    .frame(width: geo.size.width, height: geo.size.width * 9 / 16)
                    .overlay(alignment: .top) {
                        if let seconds = model.remaining {
                            Text("Channel ad break: \(seconds)s")
                                .padding().background(Color.black.opacity(0.7))
                        }
                    }
                Spacer()
            }
        }
        .foregroundColor(.white)
        .background(Color.black)
    }
}

@main
class ProbeApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: ProbeView(model: PlaybackProbe()))
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
