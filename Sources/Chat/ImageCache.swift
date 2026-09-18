import UIKit
import ImageIO
import CryptoKit

// MARK: – Image décodée (statique ou animée)
/// Une seule frame ⇒ statique. Plusieurs ⇒ emote animée (GIF / WebP animé / APNG).
final class CachedImage {
    let frames: [UIImage]
    let duration: TimeInterval     // durée totale de l'animation (0 si statique)
    let bytes: Int
    init(frames: [UIImage], duration: TimeInterval, bytes: Int) {
        self.frames = frames; self.duration = duration; self.bytes = bytes
    }
    var isAnimated: Bool { frames.count > 1 }
    var first: UIImage? { frames.first }
    /// Ratio largeur/hauteur, borné pour éviter les emotes délirantes.
    var aspect: CGFloat {
        guard let s = first?.size, s.height > 0 else { return 1 }
        return min(4, max(0.25, s.width / s.height))
    }
}

// MARK: – Cache d'images emotes / badges (mémoire + disque)
//
// Objectif : zéro temps de chargement quand le chat défile vite. Une emote déjà
// vue est lue **en mémoire de façon synchrone** (pas d'AsyncImage, pas de clignotement).
// Le disque évite de re-télécharger dans la session, et vit dans Caches/ (donc
// iOS peut le récupérer tout seul sous pression de stockage).
final class ImageCache {
    static let shared = ImageCache()

    private let memory = NSCache<NSString, CachedImage>()
    private let dir: URL
    private let fm = FileManager.default
    private let lock = NSLock()
    private var inFlight: [String: Task<CachedImage?, Never>] = [:]

    /// Nb max de frames gardées par emote (sous-échantillonnage au-delà).
    private let maxFrames = 90

    private init() {
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        dir = caches.appendingPathComponent("emote-cache", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        memory.totalCostLimit = 48 * 1024 * 1024   // ~48 Mo décodés en RAM
    }

    // MARK: Lecture rapide (synchrone, mémoire uniquement)
    func cached(_ url: String) -> CachedImage? { memory.object(forKey: url as NSString) }

    // MARK: Chargement (mémoire → disque → réseau)
    func image(for url: String) async -> CachedImage? {
        if let hit = cached(url) { return hit }

        // Dédoublonne les demandes concurrentes sur la même URL (chat qui spamme
        // la même emote ⇒ un seul téléchargement/décodage).
        lock.lock()
        if let running = inFlight[url] { lock.unlock(); return await running.value }
        let task = Task<CachedImage?, Never>.detached(priority: .userInitiated) { [weak self] in
            await self?.load(url) ?? nil
        }
        inFlight[url] = task
        lock.unlock()

        let result = await task.value
        lock.lock(); inFlight[url] = nil; lock.unlock()
        return result
    }

    private func load(_ url: String) async -> CachedImage? {
        let file = dir.appendingPathComponent(Self.key(url))

        // 1) Disque
        if let data = try? Data(contentsOf: file), let img = Self.decode(data, maxFrames: maxFrames) {
            memory.setObject(img, forKey: url as NSString, cost: img.bytes)
            return img
        }

        // 2) Réseau
        guard let u = URL(string: url),
              let (data, resp) = try? await URLSession.shared.data(from: u),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let img = Self.decode(data, maxFrames: maxFrames) else { return nil }

        try? data.write(to: file, options: .atomic)
        memory.setObject(img, forKey: url as NSString, cost: img.bytes)
        return img
    }

    // MARK: Décodage (gère GIF / WebP animé / APNG via ImageIO)
    private static func decode(_ data: Data, maxFrames: Int) -> CachedImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(src)

        if count <= 1 {
            guard let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            return CachedImage(frames: [UIImage(cgImage: cg)], duration: 0, bytes: max(1, data.count))
        }

        // Animée : on sous-échantillonne si l'emote a trop de frames.
        let step = max(1, Int(ceil(Double(count) / Double(maxFrames))))
        var frames: [UIImage] = []
        var total: TimeInterval = 0
        var i = 0
        while i < count {
            if let cg = CGImageSourceCreateImageAtIndex(src, i, nil) {
                frames.append(UIImage(cgImage: cg))
                total += delay(src, i) * Double(step)   // la frame gardée couvre `step` frames
            }
            i += step
        }
        guard !frames.isEmpty else { return nil }
        if frames.count == 1 { return CachedImage(frames: frames, duration: 0, bytes: max(1, data.count)) }
        if total <= 0 { total = Double(frames.count) * 0.1 }
        return CachedImage(frames: frames, duration: total, bytes: max(1, data.count))
    }

    private static func delay(_ src: CGImageSource, _ index: Int) -> TimeInterval {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any]
        else { return 0.1 }
        let candidates: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary,   kCGImagePropertyGIFUnclampedDelayTime,   kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyWebPDictionary,  kCGImagePropertyWebPUnclampedDelayTime,  kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyPNGDictionary,   kCGImagePropertyAPNGUnclampedDelayTime,  kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime)
        ]
        for (dict, unclamped, clamped) in candidates {
            guard let d = props[dict] as? [CFString: Any] else { continue }
            if let v = d[unclamped] as? Double, v > 0.001 { return v }
            if let v = d[clamped]   as? Double, v > 0.001 { return v }
        }
        return 0.1
    }

    private static func key(_ url: String) -> String {
        let digest = SHA256.hash(data: Data(url.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Entretien
    /// Taille occupée sur le disque (octets).
    func diskSize() -> Int64 {
        guard let items = try? fm.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        else { return 0 }
        return items.reduce(0) { acc, f in
            acc + Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func fileCount() -> Int {
        (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]))?.count ?? 0
    }

    /// Vide tout (mémoire + disque).
    func purge() {
        let freed = diskSize()
        memory.removeAllObjects()
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        logger.info("CACHE", "Cache images vidé", ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))
    }

    /// Vide seulement si l'utilisateur a activé la purge automatique (réglages).
    func purgeIfNeeded() {
        let auto = UserDefaults.standard.object(forKey: "cfg_purge_cache") as? Bool ?? true
        guard auto else { return }
        purge()
    }
}
