import Foundation

// Sonde « VOD sans son chez Twitch » (Sources/Services/VodSilence.swift),
// sans réseau : segments TS et fMP4 fabriqués ici, comme dans
// tools/silence-check.mjs du site. Lancer : sh tools/test-vod-silence.sh.
@main
enum VodSilenceTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError(message) }
    }

    // MARK: Fabrication de segments

    /// Paquets TS de 188 octets (bourrage par le champ d'adaptation).
    static func packets(_ pid: Int, _ payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var rest = payload[...]
        var first = true
        while first || !rest.isEmpty {
            var p = [UInt8](repeating: 0, count: 188)
            p[0] = 0x47
            p[1] = (first ? 0x40 : 0) | UInt8((pid >> 8) & 0x1f)
            p[2] = UInt8(pid & 0xff)
            if rest.count >= 184 {
                p[3] = 0x10
                p.replaceSubrange(4..<188, with: rest.prefix(184))
                rest = rest.dropFirst(184)
            } else {
                let stuff = 184 - rest.count
                p[3] = 0x30
                p[4] = UInt8(stuff - 1)
                if stuff > 1 {
                    p[5] = 0
                    for i in 6..<(4 + stuff) { p[i] = 0xff }
                }
                p.replaceSubrange((4 + stuff)..<188, with: rest)
                rest = []
            }
            out += p
            first = false
        }
        return out
    }

    static func adts(_ size: Int) -> [UInt8] {
        let len = size + 7
        var f = [UInt8](repeating: 0, count: len)
        f[0] = 0xff; f[1] = 0xf1; f[2] = 0x4c
        f[3] = 0x80 | UInt8((len >> 11) & 3)
        f[4] = UInt8((len >> 3) & 0xff)
        f[5] = UInt8(((len & 7) << 5) | 0x1f)
        f[6] = 0xfc
        return f
    }

    /// Segment TS : PAT, PMT (AAC en 256, H.264 en 257 si `video`), puis les
    /// trames audio par PES de 8 trames.
    static func tsSegment(_ frames: [Int], video: Bool = false, audioType: UInt8 = 0x0f) -> [UInt8] {
        let pat: [UInt8] = [0, 0x00, 0xb0, 0x0d, 0, 1, 0xc1, 0, 0, 0, 1, 0xf0, 0x00, 0, 0, 0, 0]
        var es: [UInt8] = [audioType, 0xe1, 0x00, 0xf0, 0x00]
        if video { es += [0x1b, 0xe1, 0x01, 0xf0, 0x00] }
        var pmt: [UInt8] = [0, 0x02, 0xb0, UInt8(9 + es.count + 4), 0, 1, 0xc1, 0, 0, 0xe1, 0x00, 0xf0, 0x00]
        pmt += es
        pmt += [0, 0, 0, 0]
        let audioHeader: [UInt8] = [0, 0, 1, 0xc0, 0, 0, 0x80, 0x80, 5, 0x21, 0, 1, 0, 1]
        var videoPes: [UInt8] = [0, 0, 1, 0xe0, 0, 0, 0x80, 0, 0]
        videoPes += [UInt8](repeating: 0, count: 900)
        var out = packets(0, pat)
        out += packets(0x1000, pmt)
        var i = 0
        while i < frames.count {
            var pes = audioHeader
            for size in frames[i..<min(i + 8, frames.count)] { pes += adts(size) }
            out += packets(256, pes)
            if video { out += packets(257, videoPes) }
            i += 8
        }
        return out
    }

    static func u32(_ n: Int) -> [UInt8] {
        [UInt8((n >> 24) & 0xff), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)]
    }

    static func box(_ type: String, _ body: [UInt8]...) -> [UInt8] {
        let inner = body.flatMap { $0 }
        return u32(inner.count + 8) + Array(type.utf8) + inner
    }

    static func trunBody(_ sizes: [Int]) -> [UInt8] {
        u32(0x301) + u32(sizes.count) + u32(0) + sizes.flatMap { u32(1024) + u32($0) }
    }

    /// Début de segment fMP4 : styp, moof (une traf par piste), en-tête de mdat.
    static func fmp4Segment(_ tracks: [[Int]], defaultSize: Int = 0) -> [UInt8] {
        var trafs: [UInt8] = []
        for (t, sizes) in tracks.enumerated() {
            let tfhd = defaultSize > 0 ? box("tfhd", u32(0x10), u32(t + 1), u32(defaultSize)) : box("tfhd", u32(0), u32(t + 1))
            let trun = defaultSize > 0 ? box("trun", u32(0x001), u32(sizes.count), u32(0)) : box("trun", trunBody(sizes))
            trafs += box("traf", tfhd, trun)
        }
        return box("styp", Array("msdh".utf8)) + box("moof", box("mfhd", u32(0), u32(1)), trafs) + u32(1_000_000) + Array("mdat".utf8)
    }

    /// Segment fMP4 comme ceux de Twitch : un emsg, puis des fragments (moof +
    /// mdat) de `per` échantillons chacun.
    static func fmp4Fragments(_ sizes: [Int], per: Int = 5) -> [UInt8] {
        var out = box("emsg", [UInt8](repeating: 0, count: 404))
        var i = 0
        while i < sizes.count {
            let part = Array(sizes[i..<min(i + per, sizes.count)])
            out += box("moof", box("mfhd", u32(0), u32(i / per + 1)),
                       box("traf", box("tfhd", u32(0x20000), u32(1)), box("tfdt", u32(0), u32(i * 1024)), box("trun", trunBody(part))))
            out += box("mdat", [UInt8](repeating: 0, count: part.reduce(0, +)))
            i += per
        }
        return out
    }

    // MARK: Vérifications

    static func main() {
        let root = "https://d2vi6trrdongqn.cloudfront.net/abc_login_1_2"
        expect(VodSilence.targets("\(root)/720p60/index-dvr.m3u8").map(\.absoluteString)
               == ["\(root)/audio_only/index-dvr.m3u8", "\(root)/chunked/index-dvr.m3u8"], "cibles d'une archive")
        expect(VodSilence.targets("\(root)/chunked/highlight-123.m3u8?x=1").map(\.absoluteString)
               == ["\(root)/audio_only/highlight-123.m3u8", "\(root)/chunked/highlight-123.m3u8"], "cibles d'un highlight")
        expect(VodSilence.targets("https://usher.ttvnw.net/vod/2928522226.m3u8?sig=1").isEmpty, "liste maîtresse ignorée")
        expect(VodSilence.targets("").isEmpty, "adresse vide")

        var lines = ["#EXTM3U", "#EXT-X-TARGETDURATION:10"]
        for i in 0..<100 { lines += ["#EXTINF:10.000,", i == 49 || i == 50 ? "\(i)-muted.ts" : "\(i).ts"] }
        let base = URL(string: "https://cdn.example/f/audio_only/index-dvr.m3u8")!
        let picked = VodSilence.segments(lines.joined(separator: "\n"), base: base)
        expect(!picked.fmp4, "playlist TS")
        expect(picked.urls.map(\.absoluteString) == ["https://cdn.example/f/audio_only/9.ts",
                                                     "https://cdn.example/f/audio_only/48.ts",
                                                     "https://cdn.example/f/audio_only/89.ts"],
               "10, 50 et 90 %, à côté des passages coupés : \(picked.urls)")
        let fm = VodSilence.segments("#EXTM3U\n#EXT-X-MAP:URI=\"init-0.mp4\"\n#EXTINF:10.000,\n0.mp4\n#EXT-X-ENDLIST", base: base)
        expect(fm.fmp4 && fm.urls.map(\.absoluteString) == ["https://cdn.example/f/audio_only/0.mp4"], "playlist fMP4")
        expect(VodSilence.segments("#EXTINF:10,\n0-muted.ts\n#EXTINF:10,\n1-unmuted.ts", base: base).urls.isEmpty, "rien que des passages coupés")
        expect(VodSilence.segments("", base: base).urls.isEmpty, "playlist vide")

        let silent = [Int](repeating: 6, count: 469)
        let sound = (0..<469).map { 315 + ($0 * 37) % 380 }
        expect(VodSilence.tsAudioFrameSizes(tsSegment([6, 6, 23])) == [6, 6, 23], "tailles des trames ADTS")
        expect(VodSilence.verdict(tsSegment(silent), fmp4: false) == true, "TS muet")
        expect(VodSilence.verdict(tsSegment(sound), fmp4: false) == false, "TS avec du son")
        expect(VodSilence.verdict(tsSegment(Array(silent.prefix(120)), video: true), fmp4: false) == true, "original muet")
        expect(VodSilence.verdict(tsSegment(Array(sound.prefix(120)), video: true), fmp4: false) == false, "original avec du son")
        expect(VodSilence.verdict(tsSegment(silent.enumerated().map { $0.offset % 20 == 0 ? 23 : $0.element }), fmp4: false) == true,
               "quelques trames plus grosses dans le silence")
        expect(VodSilence.verdict(tsSegment(Array(silent.prefix(20))), fmp4: false) == nil, "trop court")
        expect(VodSilence.verdict(tsSegment(silent, audioType: 0x81), fmp4: false) == nil, "pas d'AAC")
        expect(VodSilence.verdict([UInt8](repeating: 0, count: 4096), fmp4: false) == nil, "pas du TS")
        expect(VodSilence.verdict(Array(tsSegment(sound).prefix(64 * 1024 + 77)), fmp4: false) == false, "TS lu en partie")

        expect(VodSilence.fmp4SampleSizes(fmp4Segment([[6, 7, 23]])) == [6, 7, 23], "tailles des échantillons")
        expect(VodSilence.verdict(fmp4Segment([silent]), fmp4: true) == true, "fMP4 muet")
        expect(VodSilence.verdict(fmp4Segment([sound]), fmp4: true) == false, "fMP4 avec du son")
        expect(VodSilence.verdict(fmp4Segment([silent], defaultSize: 6), fmp4: true) == true, "taille par défaut (tfhd)")
        expect(VodSilence.fmp4SampleSizes(fmp4Segment([silent, sound])) == nil, "deux pistes : pas de verdict")
        expect(VodSilence.fmp4SampleSizes(Array(fmp4Segment([silent]).prefix(200))) == nil, "moof coupée")
        let frags = fmp4Fragments(sound)
        expect(VodSilence.verdict(Array(frags.prefix(64 * 1024)), fmp4: true) == false, "fragments de Twitch avec du son")
        expect(VodSilence.verdict(Array(fmp4Fragments(silent).prefix(64 * 1024)), fmp4: true) == true, "fragments de Twitch muets")
        let n = VodSilence.fmp4SampleSizes(Array(frags.prefix(64 * 1024)))?.count ?? 0
        expect(n >= 40 && n % 5 == 0 && n < sound.count, "fragment coupé laissé de côté (\(n))")

        // Octets abîmés au hasard : jamais de plantage ni de boucle sans fin.
        var seed: UInt64 = 42
        func next() -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(truncatingIfNeeded: seed >> 17) & 0x7fff_ffff
        }
        let sources = [tsSegment(silent), tsSegment(Array(sound.prefix(120)), video: true), fmp4Fragments(silent), fmp4Segment([sound])]
        let hugeTrun = u32(28) + Array("trun".utf8) + u32(0x001) + u32(0xffff_ffff) + u32(0)
        for round in 0..<300 {
            var junk = sources[round % sources.count]
            for _ in 0..<40 { junk[next() % junk.count] = UInt8(next() & 0xff) }
            if round % 7 == 0 { junk.replaceSubrange(0..<hugeTrun.count, with: hugeTrun) }
            for fmp4 in [false, true] {
                let v = VodSilence.verdict(junk, fmp4: fmp4)
                expect(v == true || v == false || v == nil, "verdict sur des octets abîmés")
            }
        }

        print("VodSilence : \(checks) vérifications passées")
    }
}
