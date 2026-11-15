import Foundation

// ═══════════════════════════════════════════════════════════════════════════
//  VOD sans son chez Twitch (même sonde que silence.js sur le site, et
//  VodSilence.kt sur Android).
//
//  Certaines chaînes n'enregistrent qu'une piste audio vide dans leurs VODs
//  (sans doute la piste VOD d'OBS, activée sans source) : du silence d'un
//  bout à l'autre, sur twitch.tv aussi, et rien à récupérer sur le CDN. Pour
//  le dire au lieu de laisser croire à une panne, on lit le début de trois
//  segments de « audio seul », à 10, 50 et 90 % de la VOD (à côté des
//  passages coupés, muets exprès), et on mesure leurs trames audio : le
//  silence encodé tient en 6 octets par trame, le son en 300 à 700
//  (160 kb/s). Le 160p et le 360p, à débit constant (128 et 170 octets par
//  trame, son ou pas), ne disent rien : « audio seul » d'abord, l'original
//  (chunked) s'il n'y en a pas. TS : trames ADTS ; fMP4 : tailles des
//  échantillons (boîte trun), « audio seul » seulement — l'original y mêle
//  image et son.
//  Toute lecture d'octet est bornée : un segment tronqué ou bizarre donne
//  « pas de verdict », jamais un plantage.
// ═══════════════════════════════════════════════════════════════════════════

enum VodSilence {
    enum Verdict: String { case silent, sound, unknown }

    /// Trame audio de cette taille ou moins : du silence (6 octets en AAC).
    static let silentFrameBytes = 12
    /// Trames à lire au moins pour juger un segment.
    static let minFrames = 40
    /// Début de segment lu : ~140 trames de son en TS « audio seul », toute
    /// la boîte moof en fMP4. L'original mêle l'image : il en faut bien plus.
    static let probeBytes = 64 * 1024
    static let sourceProbeBytes = 1024 * 1024
    private static let points: [Double] = [0.1, 0.5, 0.9]

    /// Playlists « audio seul » puis originale d'une VOD, d'après l'adresse
    /// d'une de ses qualités (…/<qualité>/index-dvr.m3u8, ou
    /// highlight-<id>.m3u8). Vide pour une autre adresse.
    static func targets(_ raw: String) -> [URL] {
        let pattern = #"^(https://[^?#]+/)[^/?#]+/((?:index-dvr|highlight-\d+)\.m3u8)(?:[?#].*)?$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let prefix = Range(m.range(at: 1), in: raw),
              let file = Range(m.range(at: 2), in: raw) else { return [] }
        return ["audio_only", "chunked"].compactMap { URL(string: "\(raw[prefix])\($0)/\(raw[file])") }
    }

    /// Segments à sonder : à 10, 50 et 90 % de la playlist, à côté des
    /// passages coupés s'il le faut. `fmp4` : playlist à EXT-X-MAP.
    static func segments(_ text: String, base: URL) -> (urls: [URL], fmp4: Bool) {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var segs: [String] = []
        for i in lines.indices where lines[i].hasPrefix("#EXTINF") {
            if i + 1 < lines.count, !lines[i + 1].isEmpty, !lines[i + 1].hasPrefix("#") { segs.append(lines[i + 1]) }
        }
        func plain(_ i: Int) -> Bool {
            i >= 0 && i < segs.count && segs[i].range(of: #"-(un)?muted\.(ts|mp4)"#, options: .regularExpression) == nil
        }
        var picked = Set<Int>()
        if !segs.isEmpty {
            for p in points {
                let at = Int(p * Double(segs.count - 1))
                for d in 0...5 {
                    if plain(at + d) { picked.insert(at + d); break }
                    if plain(at - d) { picked.insert(at - d); break }
                }
            }
        }
        let urls = picked.sorted().compactMap { URL(string: segs[$0], relativeTo: base)?.absoluteURL }
        return (urls, lines.contains { $0.hasPrefix("#EXT-X-MAP") })
    }

    /// Tailles des trames audio (en-tête ADTS ôté) d'un début de segment TS ;
    /// nil sans piste AAC lisible.
    static func tsAudioFrameSizes(_ b: [UInt8]) -> [Int]? {
        guard b.count >= 376, b[0] == 0x47 else { return nil }
        var pmt = -1, audio = -1, started = false
        var es: [UInt8] = []
        es.reserveCapacity(b.count / 2)
        var o = 0
        while o + 188 <= b.count {
            let packetEnd = o + 188
            defer { o = packetEnd }
            guard b[o] == 0x47 else { break }
            let pusi = b[o + 1] & 0x40 != 0
            let pid = Int(b[o + 1] & 0x1f) << 8 | Int(b[o + 2])
            let afc = (b[o + 3] >> 4) & 3
            var p = o + 4
            if afc & 2 != 0 { p += 1 + Int(b[o + 4]) }
            if afc & 1 == 0 || p >= packetEnd { continue }
            if pid == 0 && pusi {
                // Table des programmes : où lire la table du programme (PMT).
                let t = p + 1 + Int(b[p])
                guard t + 3 <= packetEnd else { continue }
                let end = min(packetEnd, t + 3 + (Int(b[t + 1] & 0x0f) << 8 | Int(b[t + 2])) - 4)
                var i = t + 8
                while i + 4 <= end {
                    if Int(b[i]) << 8 | Int(b[i + 1]) != 0 { pmt = Int(b[i + 2] & 0x1f) << 8 | Int(b[i + 3]); break }
                    i += 4
                }
            } else if pid == pmt && pusi && audio < 0 {
                // Pistes du programme : la première en AAC (type 0x0f).
                let t = p + 1 + Int(b[p])
                guard t + 12 <= packetEnd else { continue }
                let end = min(packetEnd, t + 3 + (Int(b[t + 1] & 0x0f) << 8 | Int(b[t + 2])) - 4)
                var i = t + 12 + (Int(b[t + 10] & 0x0f) << 8 | Int(b[t + 11]))
                while i + 5 <= end {
                    if b[i] == 0x0f { audio = Int(b[i + 1] & 0x1f) << 8 | Int(b[i + 2]); break }
                    i += 5 + (Int(b[i + 3] & 0x0f) << 8 | Int(b[i + 4]))
                }
            } else if pid == audio {
                if pusi {
                    if p + 9 <= packetEnd, b[p] == 0, b[p + 1] == 0, b[p + 2] == 1 {
                        let h = p + 9 + Int(b[p + 8])
                        if h < packetEnd { es.append(contentsOf: b[h..<packetEnd]) }
                        started = true
                    }
                } else if started {
                    es.append(contentsOf: b[p..<packetEnd])
                }
            }
        }
        guard audio >= 0 else { return nil }
        var sizes: [Int] = []
        var i = 0
        while i + 7 <= es.count {
            guard es[i] == 0xff, es[i + 1] & 0xf6 == 0xf0 else { i += 1; continue }
            let len = Int(es[i + 3] & 0x03) << 11 | Int(es[i + 4]) << 3 | Int(es[i + 5]) >> 5
            guard len >= 7 else { i += 1; continue }
            sizes.append(len - (es[i + 1] & 1 != 0 ? 7 : 9))
            i += len
        }
        return sizes
    }

    /// Tailles des échantillons d'un début de segment fMP4 à une seule piste
    /// (« audio seul ») : moof → traf → tfhd / trun, pour chaque fragment
    /// entier du morceau lu (Twitch en met des dizaines par segment, de 5
    /// échantillons chacun). nil si rien de lisible ou s'il y a plusieurs
    /// pistes.
    static func fmp4SampleSizes(_ b: [UInt8]) -> [Int]? {
        guard b.count >= 16 else { return nil }
        func u32(_ o: Int) -> Int { Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) }
        /// Boîtes entières de [start, end) : une boîte qui déborde (lecture
        /// partielle) arrête la liste.
        func boxes(_ start: Int, _ end: Int) -> [(type: String, body: Int, end: Int)] {
            var out: [(type: String, body: Int, end: Int)] = []
            var o = start
            while o + 8 <= end {
                var size = u32(o), hdr = 8
                if size == 1 {
                    guard o + 16 <= end, u32(o + 8) == 0 else { break }
                    size = u32(o + 12)
                    hdr = 16
                } else if size == 0 {
                    size = end - o
                }
                guard size >= hdr, o + size <= end else { break }
                out.append((type: String(decoding: b[(o + 4)..<(o + 8)], as: UTF8.self), body: o + hdr, end: o + size))
                o += size
            }
            return out
        }
        var sizes: [Int] = []
        for moof in boxes(0, b.count) where moof.type == "moof" {
            let trafs = boxes(moof.body, moof.end).filter { $0.type == "traf" }
            guard trafs.count == 1 else { return nil }
            var def = 0
            for x in boxes(trafs[0].body, trafs[0].end) where x.body + 8 <= x.end {
                let flags = u32(x.body) & 0xffffff
                if x.type == "tfhd" {
                    var q = x.body + 8
                    if flags & 0x01 != 0 { q += 8 }
                    if flags & 0x02 != 0 { q += 4 }
                    if flags & 0x08 != 0 { q += 4 }
                    if flags & 0x10 != 0, q + 4 <= x.end { def = u32(q) }
                } else if x.type == "trun" {
                    // Plafonné : une boîte abîmée annoncerait des milliards
                    // d'échantillons (taille par défaut, sans rien à lire).
                    let count = min(u32(x.body + 4), 100_000)
                    var q = x.body + 8
                    if flags & 0x01 != 0 { q += 4 }
                    if flags & 0x04 != 0 { q += 4 }
                    var n = 0
                    while n < count {
                        if flags & 0x100 != 0 { q += 4 }
                        if flags & 0x200 != 0 {
                            guard q + 4 <= x.end else { break }
                            sizes.append(u32(q))
                            q += 4
                        } else {
                            sizes.append(def)
                        }
                        if flags & 0x400 != 0 { q += 4 }
                        if flags & 0x800 != 0 { q += 4 }
                        n += 1
                    }
                }
            }
        }
        return sizes.isEmpty ? nil : sizes
    }

    /// true : segment muet ; false : du son ; nil : illisible ou trop court.
    static func verdict(_ bytes: [UInt8], fmp4: Bool) -> Bool? {
        guard let sizes = fmp4 ? fmp4SampleSizes(bytes) : tsAudioFrameSizes(bytes),
              sizes.count >= minFrames else { return nil }
        return Double(sizes.filter { $0 <= silentFrameBytes }.count) >= Double(sizes.count) * 0.9
    }

    /// Les `n` premiers octets (Range) ; si le serveur l'ignore, la suite
    /// n'est pas lue.
    private static func head(_ url: URL, _ n: Int) async -> [UInt8]? {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("bytes=0-\(n - 1)", forHTTPHeaderField: "Range")
        guard let (stream, response) = try? await URLSession.shared.bytes(for: req),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        defer { stream.task.cancel() }
        var out: [UInt8] = []
        out.reserveCapacity(n)
        do {
            for try await byte in stream {
                out.append(byte)
                if out.count >= n { break }
            }
        } catch {
            return out.isEmpty ? nil : out
        }
        return out
    }

    /// `.silent` (piste audio vide chez Twitch), `.sound`, ou `.unknown`
    /// (rien de lisible). `links` : les qualités de la VOD (adresses du CDN).
    static func probe(links: [String: String]) async -> Verdict {
        guard let raw = links.values.sorted().first(where: { !targets($0).isEmpty }) else { return .unknown }
        for target in targets(raw) {
            let source = target.path.contains("/chunked/")
            guard let (data, response) = try? await URLSession.shared.data(from: target),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8) else { continue }
            let (urls, fmp4) = segments(text, base: target)
            if urls.isEmpty || (source && fmp4) { continue }
            var silent = 0
            for u in urls {
                guard let bytes = await head(u, source ? sourceProbeBytes : probeBytes) else { continue }
                switch verdict(bytes, fmp4: fmp4) {
                case .some(false): return .sound
                case .some(true): silent += 1
                case .none: break
                }
            }
            if silent > 0 && silent >= min(2, urls.count) { return .silent }
        }
        return .unknown
    }
}
