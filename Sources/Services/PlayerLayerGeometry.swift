import AVFoundation
import CoreVideo
import QuartzCore

/// Size the surface from the frame actually on screen. HLS decoder/format
/// changes during a GAP must not reshape the last clean frame still displayed.
final class PlayerLayerGeometry {
    private let layer: AVPlayerLayer
    private var player: AVPlayer?
    private var observer: Any?
    private var itemObserver: NSKeyValueObservation?
    private weak var item: AVPlayerItem?
    private var output: AVPlayerItemVideoOutput?
    private var displaySize: CGSize?
    private var bounds = CGRect.zero
    private var fill = false

    init(layer: AVPlayerLayer) { self.layer = layer }

    deinit { stopObserving() }

    func setPlayer(_ player: AVPlayer) {
        guard self.player !== player else { return }
        stopObserving()
        self.player = player
        layer.player = player
        observeItem(player.currentItem)
        itemObserver = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.observeItem(self.player?.currentItem)
                self.refresh()
            }
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                  queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func layout(in bounds: CGRect, fill: Bool) {
        self.bounds = bounds
        self.fill = fill
        refresh()
    }

    func stopObserving() {
        if let observer, let player { player.removeTimeObserver(observer) }
        observer = nil
        itemObserver = nil
        if let item, let output { item.remove(output) }
        item = nil
        output = nil
        displaySize = nil
        player = nil
    }

    private func observeItem(_ item: AVPlayerItem?) {
        guard self.item !== item else { return }
        if let old = self.item, let output { old.remove(output) }
        self.item = item
        displaySize = nil
        output = item.map { item in
            // Keep the decoder's native pixel format; only inspect dimensions.
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
            item.add(output)
            return output
        }
    }

    private func refresh() {
        observeItem(player?.currentItem)
        if let player, let output,
           output.hasNewPixelBuffer(forItemTime: player.currentTime()),
           let buffer = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) {
            let size = CVImageBufferGetDisplaySize(buffer)
            if size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 {
                displaySize = size
            }
        }
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let size = displaySize {
            let x = bounds.width / size.width, y = bounds.height / size.height
            let scale = fill ? max(x, y) : min(x, y)
            let width = size.width * scale, height = size.height * scale
            layer.frame = CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                                 width: width, height: height)
            // The frame above already preserves the displayed image's aspect.
            // Avoid AVPlayer applying newly announced ad geometry to it again.
            layer.videoGravity = .resize
        } else {
            layer.frame = bounds
            layer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        }
        CATransaction.commit()
    }
}
