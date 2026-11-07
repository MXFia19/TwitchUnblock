import Foundation

/// A stitched break, in the broadcast's program-date-time clock.
struct AdBreak: Equatable {
    let id: String
    let start: Date
    let end: Date
}

/// Twitch-specific classification, independent of AVPlayer. Recognizes the same
/// markers as Streamlink's Twitch plugin (class, ID prefix and EXTINF title).
/// Overlay ads such as twitch-maf-ad are deliberately not treated as media ads.
struct TwitchAdPlaylist {
    static let adClass = "twitch-stitched-ad"
    static let maxAdLength: TimeInterval = 200

    struct Segment {
        let line: Int
        let duration: TimeInterval
        var start: Date?
        let title: String
        var ad = false
        var end: Date? { start?.addingTimeInterval(duration) }
    }

    let lines: [String]
    let segments: [Segment]
    let breaks: [AdBreak]

    static func isAd(className: String?, id: String?) -> Bool {
        className == adClass || (id?.hasPrefix("stitched-ad-") ?? false)
    }

    static func attribute(_ line: String, _ name: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        // A quoted client attribute can contain commas and text such as
        // DURATION=180. Only split at actual attribute boundaries.
        var quoted = false
        let fields = line[line.index(after: colon)...].split(omittingEmptySubsequences: false) { character in
            if character == "\"" { quoted.toggle() }
            return character == "," && !quoted
        }
        guard !quoted, let field = fields.first(where: { $0.hasPrefix(name + "=") }) else { return nil }
        var value = field.dropFirst(name.count + 1)
        if value.hasPrefix("\"") { value = value.dropFirst().dropLast() }
        return String(value)
    }

    init(_ text: String) {
        lines = text.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func date(_ value: String) -> Date? { precise.date(from: value) ?? plain.date(from: value) }
        func number(_ value: String?) -> Double? {
            guard let value, let n = Double(value), n.isFinite, n >= 0 else { return nil }
            return n
        }

        // Date-range updates may follow their segments, or split their start
        // and end across two tags with the same ID. Read all of them first.
        var attributes: [String: [String: String]] = [:]
        for line in lines where line.hasPrefix("#EXT-X-DATERANGE:") {
            guard let id = Self.attribute(line, "ID") else { continue }
            for key in ["CLASS", "START-DATE", "END-DATE", "DURATION", "PLANNED-DURATION", "END-ON-NEXT"] {
                if let value = Self.attribute(line, key) { attributes[id, default: [:]][key] = value }
            }
        }
        var ranges: [AdBreak] = []
        for (id, values) in attributes where Self.isAd(className: values["CLASS"], id: id) {
            guard let start = values["START-DATE"].flatMap(date) else { continue }
            var followingStart: Date?
            if values["END-ON-NEXT"] == "YES" {
                // RFC 8216: the earliest later range with the same CLASS
                // supplies the end, regardless of tag order or planned length.
                guard let className = values["CLASS"], values["DURATION"] == nil,
                      values["END-DATE"] == nil else { continue }
                followingStart = attributes.values.filter { $0["CLASS"] == className }
                    .compactMap { $0["START-DATE"].flatMap(date) }
                    .filter { $0 > start }.min()
            }
            let duration = number(values["DURATION"]) ?? number(values["PLANNED-DURATION"])
            let end = followingStart ?? values["END-DATE"].flatMap(date)
                ?? start.addingTimeInterval(duration ?? Self.maxAdLength)
            let capped = min(end, start.addingTimeInterval(Self.maxAdLength))
            if capped > start { ranges.append(AdBreak(id: id, start: start, end: capped)) }
        }

        var parsed: [Segment] = []
        var nextDate: Date?
        var duration: Double?
        var title = ""
        var epochStart = 0
        for (index, line) in lines.enumerated() {
            if line == "#EXT-X-DISCONTINUITY" {
                // Decoder timestamps reset; the program-date-time clock does
                // not. Keep extrapolating until an explicit date overrides it.
                epochStart = parsed.count
            } else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
                nextDate = date(String(line.dropFirst("#EXT-X-PROGRAM-DATE-TIME:".count)))
                // HLS permits the first timestamp to occur after earlier
                // segments. Extrapolate backwards, but never across a reset.
                if var cursor = nextDate {
                    for i in (epochStart..<parsed.count).reversed() {
                        if parsed[i].start != nil { break }
                        cursor = cursor.addingTimeInterval(-parsed[i].duration)
                        parsed[i].start = cursor
                    }
                }
            } else if line.hasPrefix("#EXTINF:") {
                let fields = line.dropFirst(8).split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                duration = number(fields.first.map(String.init))
                title = fields.count > 1 ? String(fields[1]) : ""
            } else if !line.isEmpty, !line.hasPrefix("#"), let length = duration {
                parsed.append(Segment(line: index, duration: length, start: nextDate, title: title))
                nextDate = nextDate?.addingTimeInterval(length)
                duration = nil
                title = ""
            }
        }
        for i in parsed.indices {
            let segment = parsed[i]
            let titledAd = segment.title.contains("Amazon")
            parsed[i].ad = titledAd || ranges.contains { range in
                guard let start = segment.start, let end = segment.end else { return false }
                return start < range.end && end > range.start
            }
            if titledAd, let start = segment.start, let end = segment.end {
                ranges.append(AdBreak(id: "tu-title-\(start.timeIntervalSince1970)", start: start, end: end))
            }
        }
        segments = parsed
        breaks = ranges.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// Keep duration, sequence numbers, encryption IVs, byte ranges and fMP4
    /// map/discontinuity transitions intact. GAP means unavailable media, not a
    /// shorter broadcast. It also gives an all-ad playlist a valid timeline.
    func filteringAds() -> String {
        let ads = Set(segments.filter(\.ad).map(\.line))
        guard !ads.isEmpty else { return lines.joined(separator: "\n") }
        var out: [String] = []
        var gap = false
        var hasVersion = false
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("#EXT-X-VERSION:") {
                hasVersion = true
                out.append("#EXT-X-VERSION:\(max(8, Int(line.dropFirst(15)) ?? 8))")
                continue
            }
            if line == "#EXT-X-GAP" { gap = true }
            if ads.contains(index), !gap { out.append("#EXT-X-GAP") }
            out.append(line)
            if !line.isEmpty, !line.hasPrefix("#") { gap = false }
        }
        if !hasVersion { out.insert("#EXT-X-VERSION:8", at: min(1, out.count)) }
        return out.joined(separator: "\n")
    }

    func adWait(window: TimeInterval) -> TimeInterval {
        guard let edge = segments.last?.end else {
            // A title still identifies an ad without timestamps. Never claim
            // that such a playlist is clean when deciding to switch back.
            return segments.contains(where: \.ad) ? Self.maxAdLength + window : 0
        }
        guard let end = breaks.map(\.end).max() else { return 0 }
        return max(0, end.addingTimeInterval(window).timeIntervalSince(edge))
    }

    /// While GAPs stall playback, currentDate can stay on the last clean frame
    /// (or be nil during preroll). Only report a break once the buffer has run
    /// out next to it; never interrupt clean content that is still buffered.
    func waitingBreak(after date: Date?, knownBreaks: [AdBreak] = []) -> AdBreak? {
        guard let last = segments.last, last.ad, let edge = last.end else { return nil }
        let tail = segments.reversed().prefix { $0.ad }
        guard let first = tail.last, let start = first.start else { return nil }
        var blocks: [AdBreak] = []
        // Title-only markers describe individual segments. The monitor keeps
        // earlier markers after they leave the window, so a held clean frame
        // can still be associated with the same continuous break.
        for next in (breaks + knownBreaks).sorted(by: { ($0.start, $0.id) < ($1.start, $1.id) }) {
            if let last = blocks.last, next.start <= last.end {
                blocks[blocks.count - 1] = AdBreak(id: last.id, start: last.start, end: max(last.end, next.end))
            } else {
                blocks.append(next)
            }
        }
        let brk = blocks.first { $0.start < edge && $0.end >= edge }
            ?? AdBreak(id: "tu-wait-\(start.timeIntervalSince1970)", start: start, end: edge)
        if let date {
            guard date >= brk.start.addingTimeInterval(-max(1, first.duration)), date <= edge else { return nil }
        } else if segments.contains(where: { !$0.ad }) {
            return nil
        }
        return brk
    }
}

/// URL routing and rewriting shared by the resource loader and fixture tests.
enum LivePlaylistRewriter {
    static let scheme = "tulive"
    static let bufferedScheme = "tulivebuffered"

    static func isWrapped(_ url: URL) -> Bool {
        url.scheme == scheme || url.scheme == bufferedScheme
    }

    static func wrap(_ link: String, lowLatency: Bool) -> String {
        guard let url = URL(string: link) else { return link }
        let plain = unwrap(url).absoluteString
        guard plain.hasPrefix("https://") else { return link }
        return (lowLatency ? scheme : bufferedScheme) + "://" + plain.dropFirst(8)
    }

    static func unwrap(_ url: URL) -> URL {
        guard isWrapped(url), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.scheme = "https"
        return parts.url ?? url
    }

    static func rewrite(_ text: String, base: URL, lowLatency: Bool) -> String {
        let playlist = TwitchAdPlaylist(text)
        let isMaster = text.contains("#EXT-X-STREAM-INF:") || text.contains("#EXT-X-MEDIA:")
        var out: [String] = []
        var nextIsVariant = false
        for line in playlist.filteringAds().components(separatedBy: "\n") {
            if line.hasPrefix("#EXT-X-TWITCH-PREFETCH") { continue }
            if line.hasPrefix("#EXT-X-STREAM-INF:") { nextIsVariant = true }
            if line.hasPrefix("#"),
               let r = line.range(of: #"(?<=[:,])URI="[^"]+""#, options: .regularExpression) {
                let value = String(line[r].dropFirst(5).dropLast())
                if let absolute = URL(string: value, relativeTo: base)?.absoluteURL.absoluteString {
                    // Alternate audio/video playlists must also be filtered.
                    // Keys and init segments must remain ordinary CDN URLs.
                    let child = line.hasPrefix("#EXT-X-MEDIA:") || line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:")
                    let uri = child ? wrap(absolute, lowLatency: lowLatency) : absolute
                    out.append(line.replacingCharacters(in: r, with: "URI=\"\(uri)\""))
                    continue
                }
            }
            if !line.isEmpty, !line.hasPrefix("#"),
               let absolute = URL(string: line, relativeTo: base)?.absoluteURL.absoluteString {
                out.append(nextIsVariant ? wrap(absolute, lowLatency: lowLatency) : absolute)
                nextIsVariant = false
            } else {
                out.append(line)
            }
        }
        if lowLatency, !isMaster, let longest = playlist.segments.map(\.duration).max(),
           longest > 0, longest < Double(Int.max) {
            let target = max(1, Int(longest.rounded()))
            out = out.map { $0.hasPrefix("#EXT-X-TARGETDURATION:") ? "#EXT-X-TARGETDURATION:\(target)" : $0 }
        }
        return out.joined(separator: "\n")
    }
}
