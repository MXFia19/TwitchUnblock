import Foundation
import AVFoundation
import AppKit

// AVPlayer may advance its clock over GAPs on macOS. Exercise the other
// supported state (a held last frame) deterministically against the real monitor.
final class HeldClockItem: AVPlayerItem {
    var heldDate: Date?
    override func currentDate() -> Date? { heldDate }
}

final class WaitingPlayer: AVPlayer {
    var heldItem: AVPlayerItem?
    override var currentItem: AVPlayerItem? { heldItem }
    override var timeControlStatus: AVPlayer.TimeControlStatus { .waitingToPlayAtSpecifiedRate }
}

@main
struct Playback {
    @MainActor
    static func heldClockRegression() -> Bool {
        let source = URL(string: "https://127.0.0.1:8765/held-clock.m3u8")!
        let wrapped = URL(string: LivePlaylistRewriter.wrap(source.absoluteString, lowLatency: false))!
        let item = HeldClockItem(asset: AVURLAsset(url: wrapped))
        let clock = Date()
        item.heldDate = clock
        AdBreakMonitor.attach(to: item)
        let player = WaitingPlayer()
        player.heldItem = item
        let monitor = AdBreakMonitor.monitor(of: item)!
        let formatter = ISO8601DateFormatter()
        var checks = 0
        for index in 0..<12 {
            let stamp = formatter.string(from: clock.addingTimeInterval(Double(index * 2)))
            let text = "#EXTM3U\n#EXT-X-PROGRAM-DATE-TIME:\(stamp)\n" +
                (index..<(index + 3)).map { "#EXTINF:2,Amazon\nad-\($0).ts\n" }.joined()
            NotificationCenter.default.post(name: LivePlaylistLoader.playlistNotification, object: source,
                                            userInfo: ["playlist": TwitchAdPlaylist(text)])
            guard monitor.waitingForAds, monitor.playbackBreak(on: player) != nil else {
                print("HELD-CLOCK FAIL at refresh \(index), after \(checks) successful checks")
                return false
            }
            checks += 1
        }
        let clean = "#EXTM3U\n#EXT-X-PROGRAM-DATE-TIME:\(formatter.string(from: clock.addingTimeInterval(28)))\n#EXTINF:2,live\nlive.ts\n"
        NotificationCenter.default.post(name: LivePlaylistLoader.playlistNotification, object: source,
                                        userInfo: ["playlist": TwitchAdPlaylist(clean)])
        let cleared = !monitor.waitingForAds && monitor.playbackBreak(on: player) == nil
        print("HELD-CLOCK checks=\(checks) clearedOnClean=\(cleared)")
        return cleared
    }

    @MainActor
    static func run(_ mode: String, wrapped: Bool) async -> Bool {
        let fixture = "\(mode)-\(wrapped ? "wrapped" : "direct")"
        let source = URL(string: "https://127.0.0.1:8765/\(fixture).m3u8")!
        let url = wrapped ? URL(string: LivePlaylistRewriter.wrap(source.absoluteString, lowLatency: false))!
            : source
        let asset = AVURLAsset(url: url)
        if wrapped { asset.resourceLoader.setDelegate(LivePlaylistLoader.shared, queue: LivePlaylistLoader.shared.queue) }
        let item = AVPlayerItem(asset: asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        AdBreakMonitor.attach(to: item)
        let player = AVPlayer(playerItem: item)
        let layer = AVPlayerLayer(player: player)
        layer.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        let geometry = PlayerLayerGeometry(layer: layer)
        geometry.setPlayer(player)
        geometry.layout(in: layer.frame, fill: false)
        defer { geometry.stopObserving() }
        let host = NSView(frame: layer.frame)
        host.wantsLayer = true
        host.layer?.addSublayer(layer)
        let window = NSWindow(contentRect: layer.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        player.isMuted = true
        player.play()
        var lastDecodedSize: CGSize?
        var geometryChecks = 0
        var geometryFailures = 0
        var heldGeometryChecks = 0
        var frames = 0
        var frameBeforeBreak = false
        var frameAfterBreak = false
        var played = false
        var sawBreak = false
        var failure: String?
        let hasMidroll = mode == "midroll" || mode == "title"
        let stopAt: Double = mode == "title" ? 26 : mode == "midroll" ? 16 : mode == "preroll" ? 12 : 2
        for tick in 0..<80 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let time = player.currentTime()
            let position = time.seconds
            if output.hasNewPixelBuffer(forItemTime: time),
               let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                lastDecodedSize = CVImageBufferGetDisplaySize(buffer)
                frames += 1
                if hasMidroll, position < 6 { frameBeforeBreak = true }
                if position > stopAt { frameAfterBreak = true }
            }
            let currentBreak = AdBreakMonitor.monitor(of: item)?.playbackBreak(on: player)
            if currentBreak != nil { sawBreak = true }
            if layer.isReadyForDisplay, let size = lastDecodedSize {
                let duringGap = mode == "midroll" && position >= 6 && position < 12
                let viewport = duringGap ? CGRect(x: 0, y: 0, width: 360, height: 640)
                                         : CGRect(x: 0, y: 0, width: 640, height: 360)
                geometry.layout(in: viewport, fill: duringGap && position >= 9)
                geometryChecks += 1
                if duringGap { heldGeometryChecks += 1 }
                if layer.videoGravity != .resize || abs(layer.frame.width / layer.frame.height - size.width / size.height) > 0.001 {
                    geometryFailures += 1
                }
            }
            if tick % 10 == 0 { print("\(mode) wrapped=\(wrapped) elapsed=\(Double(tick)/2) item=\(item.status.rawValue) control=\(player.timeControlStatus.rawValue) position=\(position) break=\(sawBreak)") }
            if item.status == .failed {
                failure = String(describing: item.error)
                print("FAIL \(mode): \(failure!) log=\(String(describing: item.errorLog()?.events))")
                break
            }
            if position.isFinite && position > stopAt && player.timeControlStatus == .playing && frameAfterBreak && frames >= 2 {
                played = true; break
            }
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        let (data, _) = try! await URLSession.shared.data(from: URL(string:"https://127.0.0.1:8765/stats")!)
        let stats = try! JSONSerialization.jsonObject(with: data) as! [String:[String]]
        let requests = stats[fixture] ?? []
        let forbidden: Set<String> = mode == "preroll" ? Set((0..<4).map { String(format:"segment%03d.ts",$0) })
            : mode == "title" ? Set((3..<11).map { String(format:"segment%03d.ts",$0) })
            : mode == "midroll" ? Set((3..<6).map { String(format:"segment%03d.ts",$0) }) : []
        let leaked = Set(requests).intersection(forbidden)
        print("RESULT \(mode) wrapped=\(wrapped) played=\(played) decodedFrames=\(frames) frameBeforeBreak=\(frameBeforeBreak) frameAfterBreak=\(frameAfterBreak) sawBreak=\(sawBreak) adRequests=\(leaked.sorted()) requests=\(requests)")
        print("GEOMETRY \(mode) checks=\(geometryChecks) failures=\(geometryFailures) heldChecks=\(heldGeometryChecks)")
        return played && failure == nil && leaked.isEmpty && !requests.isEmpty
            && geometryChecks > 0 && geometryFailures == 0
            && (mode != "midroll" || heldGeometryChecks > 0)
            && (!hasMidroll || frameBeforeBreak)
            && (mode != "preroll" || sawBreak)
            && (mode != "title" || sawBreak)
    }
    static func main() async {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let heldClock = await heldClockRegression()
        if CommandLine.arguments.contains("--held-clock-only") { exit(heldClock ? 0 : 1) }
        for path in ["control-preflight.m3u8", "preflight/segment000.ts"] {
            do {
                let url = URL(string: "https://127.0.0.1:8765/" + path)!
                let (data, response) = try await URLSession(configuration: .default).data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
                    print("PREFLIGHT invalid response \(response)"); exit(1)
                }
                print("PREFLIGHT \(path) OK bytes=\(data.count)")
            } catch { print("PREFLIGHT \(path) ERROR \(error)"); exit(1) }
        }
        let direct = await run("control", wrapped:false)
        let wrapped = await run("control", wrapped:true)
        let pre = await run("preroll", wrapped:true)
        let mid = await run("midroll", wrapped:true)
        let title = await run("title", wrapped:true)
        print("FINAL direct=\(direct) wrapped=\(wrapped) preroll=\(pre) midroll=\(mid) titleSliding=\(title) heldClock=\(heldClock)")
        exit(direct && wrapped && pre && mid && title && heldClock ? 0 : 1)
    }
}
