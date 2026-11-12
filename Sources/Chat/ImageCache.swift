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

        // 2) Réseau (ou fichier gardé avec une VOD téléchargée : file://)
        guard let u = URL(string: url),
              let (data, resp) = try? await URLSession.shared.data(from: u),
              (resp as? HTTPURLResponse)?.statusCode == 200 || u.isFileURL,
              let img = Self.decode(data, maxFrames: maxFrames) else { return nil }

        if !u.isFileURL { try? data.write(to: file, options: .atomic) }
        memory.setObject(img, forKey: url as NSString, cost: img.bytes)
        return img
    }

    /// Côté le plus long au-delà duquel une image est réduite au décodage :
    /// les emotes (128 px au plus) n'y sont pas touchées ; un GIF de GIPHY
    /// (480 px et plus, des dizaines d'images) prenait sinon des dizaines de Mo.
    private static let maxSide = 256

    // MARK: Décodage (gère GIF / WebP animé / APNG via ImageIO)
    private static func decode(_ data: Data, maxFrames: Int) -> CachedImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let side = max((props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0,
                       (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0)
        let big = side > maxSide
        let thumb: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: maxSide]
        func frame(_ i: Int) -> CGImage? {
            big ? CGImageSourceCreateThumbnailAtIndex(src, i, thumb as CFDictionary)
                : CGImageSourceCreateImageAtIndex(src, i, nil)
        }

        // Coût en mémoire : les images décodées (largeur × hauteur × 4), pas le
        // fichier compressé — une emote 7TV animée de 150 Ko en pèse ~4,5 Mo, et
        // le plafond de 48 Mo laissait monter le cache à des centaines de Mo.
        func cost(_ cg: CGImage) -> Int { cg.bytesPerRow * cg.height }

        if count <= 1 {
            guard let cg = frame(0) else { return nil }
            return CachedImage(frames: [UIImage(cgImage: cg)], duration: 0, bytes: max(1, cost(cg)))
        }

        // Animée : on sous-échantillonne si l'emote a trop de frames (moins
        // pour une grande image, réduite elle aussi).
        // Au moins autant qu'avant, et toutes les frames tant que l'emote
        // décodée tient dans 4 Mo : une 56 px de 250 frames (3 Mo) en perdait
        // deux sur trois pour rien.
        let frameBytes = max(1, frame(0).map(cost) ?? 1)
        let cap = max(big ? min(maxFrames, 48) : maxFrames, 4 * 1024 * 1024 / frameBytes)
        let step = max(1, Int(ceil(Double(count) / Double(cap))))
        var kept: [UIImage] = []
        var delays: [Int] = []   // centièmes de seconde
        var bytes = 0
        var i = 0
        while i < count {
            if let cg = frame(i) {
                kept.append(UIImage(cgImage: cg))
                bytes += cost(cg)
                // La frame gardée couvre les frames qu'elle remplace.
                let span = (i..<min(i + step, count)).reduce(0) { $0 + delay(src, $1) }
                delays.append(max(1, Int((span * 100).rounded())))
            }
            i += step
        }
        guard !kept.isEmpty else { return nil }
        if kept.count == 1 { return CachedImage(frames: kept, duration: 0, bytes: max(1, bytes)) }
        let frames = zip(kept, repeats(delays)).flatMap { Array(repeating: $0, count: $1) }
        return CachedImage(frames: frames, duration: Double(delays.reduce(0, +)) / 100, bytes: max(1, bytes))
    }

    /// UIImageView joue ses images à cadence fixe, or les délais d'une emote
    /// varient (image tenue, puis rafale) : chaque frame est répétée selon
    /// son délai (centièmes), au pas de leur PGCD — grossi au besoin pour
    /// rester sous 600 entrées (des références, pas des copies).
    static func repeats(_ delays: [Int]) -> [Int] {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        var tick = max(1, delays.reduce(0, gcd))
        while delays.reduce(0, +) / tick > 600 { tick *= 2 }
        return delays.map { max(1, Int((Double($0) / Double(tick)).rounded())) }
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
            // 10 ms ou moins : 100 ms, comme les navigateurs et Chatterino
            // (sinon ces emotes défilaient dix fois trop vite).
            if let v = d[unclamped] as? Double, v > 0.001 { return v < 0.011 ? 0.1 : v }
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
