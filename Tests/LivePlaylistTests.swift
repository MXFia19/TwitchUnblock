import Foundation

@main
enum LivePlaylistTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError(message) }
    }

    static func main() {
        let base = URL(string: "https://cdn.example/live/index.m3u8?token=private")!
        let clock = ISO8601DateFormatter().date(from: "2026-11-06T12:00:00Z")!
        let header = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:100\n"
        let ad = "#EXT-X-DATERANGE:ID=\"break-1\",CLASS=\"twitch-stitched-ad\",START-DATE=\"2026-11-06T12:00:02Z\",DURATION=4"
        let media = """
        #EXT-X-PROGRAM-DATE-TIME:2026-11-06T12:00:00Z
        #EXT-X-MAP:URI="init-live.mp4"
        #EXTINF:2,live
        live-100.mp4
        #EXT-X-DISCONTINUITY
        #EXT-X-MAP:URI="init-ad.mp4"
        #EXTINF:2,
        ad-101.mp4
        #EXTINF:2,
        ad-102.mp4
        #EXT-X-DISCONTINUITY
        #EXT-X-MAP:URI="init-live-2.mp4"
        #EXTINF:2,live
        live-103.mp4
        #EXT-X-TWITCH-PREFETCH:future.mp4
        """
        let mixed = header + ad + "\n" + media
        let playlist = TwitchAdPlaylist(mixed)
        expect(playlist.segments.map(\.ad) == [false, true, true, false], "Classify the midroll with extrapolated dates across discontinuities")
        expect(playlist.adWait(window: 4) == 2, "Wait until the startup window is clean")
        let output = LivePlaylistRewriter.rewrite(mixed, base: base, lowLatency: true)
        expect(output.contains("#EXT-X-GAP\nhttps://cdn.example/live/ad-101.mp4"), "First ad is a gap")
        expect(output.contains("#EXT-X-GAP\nhttps://cdn.example/live/ad-102.mp4"), "Second ad is a gap")
        expect(!output.contains("#EXT-X-GAP\nhttps://cdn.example/live/live-103.mp4"), "Resume exactly at the end-exclusive ad boundary")
        expect(output.contains("#EXT-X-MEDIA-SEQUENCE:100"), "Keep sequence numbers")
        expect(output.components(separatedBy: "#EXT-X-DISCONTINUITY").count == 3, "Keep both decoder resets")
        expect(output.contains("#EXT-X-MAP:URI=\"https://cdn.example/live/init-live-2.mp4\""), "Restore the clean fMP4 init map")
        expect(output.contains("#EXT-X-VERSION:8"), "GAP requires HLS version 8")
        expect(output.contains("#EXT-X-TARGETDURATION:2"), "Low-latency target remains available")
        expect(!output.contains("TWITCH-PREFETCH"), "Do not expose unfiltered future segments")
        expect(TwitchAdPlaylist(output).segments.map(\.duration) == [2, 2, 2, 2], "Preserve total timeline duration")
        expect(TwitchAdPlaylist(output).filteringAds() == output, "Filtering is idempotent")
        let buffered = LivePlaylistRewriter.rewrite(mixed, base: base, lowLatency: false)
        expect(buffered.contains("#EXT-X-TARGETDURATION:6"), "Disabling low latency preserves the original target")
        expect(buffered.contains("#EXT-X-GAP"), "Disabling low latency still filters ads")

        let idOnly = mixed.replacingOccurrences(of: "ID=\"break-1\",CLASS=\"twitch-stitched-ad\"", with: "ID=\"stitched-ad-1\"")
        expect(TwitchAdPlaylist(idOnly).segments.map(\.ad) == playlist.segments.map(\.ad), "Recognize ID-only ads")
        let overlay = mixed.replacingOccurrences(of: "twitch-stitched-ad", with: "twitch-maf-ad")
        expect(!TwitchAdPlaylist(overlay).filteringAds().contains("#EXT-X-GAP"), "Overlay ads must not remove live video")
        let titled = header + "#EXTINF:2,Amazon advertisement\nad.ts\n#EXTINF:2,live\nlive.ts\n"
        expect(TwitchAdPlaylist(titled).segments.map(\.ad) == [true, false], "EXTINF titles work even without dates")
        expect(TwitchAdPlaylist(titled).adWait(window: 4) > 0, "Undated ads must not authorize a switch back")
        expect(!TwitchAdPlaylist(header + "#EXTINF:2,live\nAmazon-live.ts\n").segments[0].ad, "A URL alone is not an ad marker")

        let pre = header + """
        #EXT-X-DATERANGE:ID="stitched-ad-preroll",START-DATE="2026-11-06T12:00:00Z",DURATION=30
        #EXT-X-PROGRAM-DATE-TIME:2026-11-06T12:00:00Z
        #EXTINF:2,
        pre-100.ts
        #EXTINF:2,
        pre-101.ts
        """
        let preroll = TwitchAdPlaylist(pre)
        expect(preroll.segments.allSatisfy(\.ad), "Classify an all-ad preroll")
        expect(preroll.filteringAds().components(separatedBy: "#EXTINF:").count == 3, "Never return an empty preroll playlist")
        expect(!preroll.filteringAds().contains("#EXT-X-ENDLIST"), "Keep polling through the break")
        expect(preroll.waitingBreak(after: nil)?.id == "stitched-ad-preroll", "Countdown can start before AVPlayer has a date")
        expect(preroll.adWait(window: 4) == 30, "Preroll wait includes startup window")
        let clean = header.replacingOccurrences(of: ":100", with: ":115") + """
        #EXT-X-DISCONTINUITY-SEQUENCE:1
        #EXT-X-PROGRAM-DATE-TIME:2026-11-06T12:00:30Z
        #EXTINF:2,live
        live-115.ts
        #EXTINF:2,live
        live-116.ts
        """
        expect(!TwitchAdPlaylist(clean).filteringAds().contains("#EXT-X-GAP"), "A clean refresh resumes without stale ad state")
        expect(TwitchAdPlaylist(clean).waitingBreak(after: nil) == nil, "Clear the preroll countdown on clean content")
        expect(TwitchAdPlaylist(clean).adWait(window: 4) == 0, "Clean playlist permits fallback return")

        let during = header + ad + "\n" + media.components(separatedBy: "#EXT-X-MAP:URI=\"init-live-2.mp4\"")[0]
        expect(TwitchAdPlaylist(during).waitingBreak(after: clock.addingTimeInterval(-10)) == nil, "Do not announce ads ahead of buffered live video")
        expect(TwitchAdPlaylist(during).waitingBreak(after: clock.addingTimeInterval(1.9)) != nil, "Detect a gap at the last clean frame")
        expect(TwitchAdPlaylist(during).waitingBreak(after: nil) == nil, "Do not discard available live content during startup")
        let sliding = pre.replacingOccurrences(of: "#EXT-X-PROGRAM-DATE-TIME:2026-11-06T12:00:00Z", with: "#EXT-X-PROGRAM-DATE-TIME:2026-11-06T12:00:20Z")
        expect(TwitchAdPlaylist(sliding).waitingBreak(after: clock)?.id == "stitched-ad-preroll", "Countdown survives the sliding window while the playback clock is stalled")
        let pod = pre.replacingOccurrences(of: "DURATION=30", with: "DURATION=2") + "\n#EXT-X-DATERANGE:ID=\"stitched-ad-next\",START-DATE=\"2026-11-06T12:00:02Z\",DURATION=28"
        expect(TwitchAdPlaylist(pod).waitingBreak(after: nil)?.end == clock.addingTimeInterval(30), "Count contiguous ads as one break")
        let refreshed = clean + "\n#EXT-X-DATERANGE:ID=\"stitched-ad-preroll\",START-DATE=\"2026-11-06T12:00:00Z\",DURATION=30"
        expect(!TwitchAdPlaylist(refreshed).segments.contains(where: \.ad), "Expired metadata does not filter new content")
        expect(TwitchAdPlaylist(refreshed).adWait(window: 4) == 0, "An expired break with a clean startup window permits return")

        let lateRange = header + media + "\n" + ad
        expect(TwitchAdPlaylist(lateRange).segments.map(\.ad) == playlist.segments.map(\.ad), "Ranges may follow their segments")
        let splitRange = mixed.replacingOccurrences(of: ",DURATION=4", with: "") + "\n#EXT-X-DATERANGE:ID=\"break-1\",END-DATE=\"2026-11-06T12:00:06Z\""
        expect(TwitchAdPlaylist(splitRange).segments.map(\.ad) == playlist.segments.map(\.ad), "Merge same-ID range updates")
        let fractional = mixed.replacingOccurrences(of: "12:00:02Z", with: "12:00:02.500Z").replacingOccurrences(of: "DURATION=4", with: "DURATION=3.5")
        expect(TwitchAdPlaylist(fractional).segments.map(\.ad) == playlist.segments.map(\.ad), "Suppress segments overlapping fractional boundaries")
        let lateDate = header + ad + "\n#EXTINF:2,live\na.ts\n#EXT-X-PROGRAM-DATE-TIME:2026-11-06T12:00:02Z\n#EXTINF:2,\nb.ts"
        expect(TwitchAdPlaylist(lateDate).segments.first?.start == clock, "Backfill dates before the first PDT")
        let noVersion = mixed.replacingOccurrences(of: "#EXT-X-VERSION:3\n", with: "")
        expect(TwitchAdPlaylist(noVersion).filteringAds().hasPrefix("#EXTM3U\n#EXT-X-VERSION:8"), "Add missing version")
        expect(TwitchAdPlaylist(mixed.replacingOccurrences(of: "VERSION:3", with: "VERSION:9")).filteringAds().contains("VERSION:9"), "Never downgrade HLS version")
        let keyed = mixed.replacingOccurrences(of: "#EXTINF:2,", with: "#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXT-X-BYTERANGE:1024@0\n#EXTINF:2,")
        let keyedOutput = LivePlaylistRewriter.rewrite(keyed, base: base, lowLatency: false)
        expect(keyedOutput.contains("URI=\"https://cdn.example/live/key\""), "Keep key URLs on the CDN")
        expect(keyedOutput.components(separatedBy: "#EXT-X-BYTERANGE:1024@0").count == 5, "Keep byte ranges")

        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Audio",URI="audio/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=1000000,AUDIO="audio"
        video/index.m3u8
        """
        let masterOutput = LivePlaylistRewriter.rewrite(master, base: base, lowLatency: false)
        expect(masterOutput.contains("URI=\"tulivebuffered://cdn.example/live/audio/index.m3u8\""), "Alternate audio cannot bypass filtering")
        expect(masterOutput.contains("tulivebuffered://cdn.example/live/video/index.m3u8"), "Child video inherits buffering mode")
        expect(!masterOutput.contains("#EXT-X-GAP"), "Master playlists contain no media gaps")
        // Variants of a master (Auto quality): found back in https, as the loader will read them.
        let children = LivePlaylistRewriter.wrappedChildren(in: masterOutput).map { $0.absoluteString }
        expect(children.contains("https://cdn.example/live/audio/index.m3u8"), "Alternate audio is a child of its master")
        expect(children.contains("https://cdn.example/live/video/index.m3u8"), "Variants are children of their master")
        expect(LivePlaylistRewriter.wrappedChildren(in: output).isEmpty, "Media playlists have no children")
        for lowLatency in [false, true] {
            let wrapped = LivePlaylistRewriter.wrap(base.absoluteString, lowLatency: lowLatency)
            expect(LivePlaylistRewriter.unwrap(URL(string: wrapped)!) == base, "AirPlay unwrap preserves signed URL")
            expect(LivePlaylistRewriter.wrap(wrapped, lowLatency: lowLatency) == wrapped, "Wrapping is idempotent")
        }
        expect(LivePlaylistRewriter.wrap("file:///tmp/video.mp4", lowLatency: true) == "file:///tmp/video.mp4", "Local files are untouched")
        expect(TwitchAdPlaylist.attribute(ad + ",X-TV-TWITCH-AD-POD-FILLED-DURATION=90", "DURATION") == "4", "Duration does not match a vendor attribute suffix")
        expect(TwitchAdPlaylist(mixed.replacingOccurrences(of: "DURATION=4", with: "DURATION=999999")).breaks[0].end.timeIntervalSince(clock) == 202, "Bound malformed long ranges")
        for value in ["nan", "inf", "-3", "bad"] {
            let invalid = TwitchAdPlaylist(mixed.replacingOccurrences(of: "DURATION=4", with: "DURATION=\(value)"))
            expect(invalid.breaks.allSatisfy { $0.end.timeIntervalSince($0.start).isFinite }, "Malformed dates cannot produce an infinite countdown")
        }
        let planned = mixed.replacingOccurrences(of: "DURATION=4", with: "PLANNED-DURATION=4")
        expect(TwitchAdPlaylist(planned).segments.map(\.ad) == playlist.segments.map(\.ad), "Use planned duration when the actual end isn't known yet")
        let titleDates = header + "#EXT-X-PROGRAM-DATE-TIME:2026-11-06T12:00:00Z\n#EXTINF:2,Amazon\nad.ts\n"
        expect(TwitchAdPlaylist(titleDates).adWait(window: 4) == 4, "Dated title markers participate in fallback checks")

        let quoted = "#EXT-X-DATERANGE:ID=\"stitched-ad-test\",X-NOTE=\"advertiser,DURATION=180,other\",CLASS=\"twitch-stitched-ad\",START-DATE=\"2026-11-06T12:00:00Z\",DURATION=2"
        let quotedMedia = header + quoted + "\n#EXT-X-PROGRAM-DATE-TIME:2026-11-06T12:00:00Z\n#EXTINF:2,\nad.ts\n#EXTINF:2,live\nlive.ts\n"
        expect(TwitchAdPlaylist.attribute(quoted, "DURATION") == "2", "Ignore attribute names inside quoted client values")
        expect(TwitchAdPlaylist.attribute(quoted, "X-NOTE") == "advertiser,DURATION=180,other", "Preserve commas inside quoted values")
        expect(TwitchAdPlaylist(quotedMedia).segments.map(\.ad) == [true, false], "Quoted text cannot extend a break over clean video")
        expect(!TwitchAdPlaylist(quotedMedia).filteringAds().contains("#EXT-X-GAP\nlive.ts"), "Do not gap clean media after a quoted attribute")
        expect(TwitchAdPlaylist.attribute("#EXT-X-DATERANGE:X-NOTE=\"x,CLASS=twitch-stitched-ad\",ID=\"overlay\"", "CLASS") == nil, "A class inside a quoted value is not an ad marker")
        expect(TwitchAdPlaylist.attribute("#EXT-X-DATERANGE:X-NOTE=\"unterminated,DURATION=180", "DURATION") == nil, "Reject unterminated quoted attributes")

        let nextRange = "#EXT-X-DATERANGE:ID=\"stitched-ad-a\",CLASS=\"twitch-stitched-ad\",START-DATE=\"2026-11-06T12:00:00Z\",END-ON-NEXT=YES"
        let followingRange = "#EXT-X-DATERANGE:ID=\"stitched-ad-b\",CLASS=\"twitch-stitched-ad\",START-DATE=\"2026-11-06T12:00:02Z\",DURATION=2"
        let afterRange = "#EXT-X-PROGRAM-DATE-TIME:2026-11-06T12:00:04Z\n#EXTINF:2,live\nlive.ts\n"
        let ended = TwitchAdPlaylist(header + nextRange + "\n" + followingRange + "\n" + afterRange)
        expect(ended.breaks.first?.end == clock.addingTimeInterval(2), "END-ON-NEXT ends at the following same-class range")
        expect(!ended.segments[0].ad, "Clean video after both ranges must resume")
        expect(ended.adWait(window: 2) == 0, "An ended range does not delay fallback return")
        let reversedRanges = TwitchAdPlaylist(header + followingRange + "\n" + nextRange + ",PLANNED-DURATION=100\n" + afterRange)
        expect(reversedRanges.breaks == ended.breaks, "Following range wins over planned length regardless of tag order")
        let unrelatedRange = "#EXT-X-DATERANGE:ID=\"overlay\",CLASS=\"twitch-maf-ad\",START-DATE=\"2026-11-06T12:00:01Z\",DURATION=0"
        let laterRange = "#EXT-X-DATERANGE:ID=\"stitched-ad-c\",CLASS=\"twitch-stitched-ad\",START-DATE=\"2026-11-06T12:00:10Z\",DURATION=2"
        let unordered = TwitchAdPlaylist(header + nextRange + "\n" + laterRange + "\n" + unrelatedRange + "\n" + followingRange + "\n" + afterRange)
        expect(unordered.breaks.first?.end == clock.addingTimeInterval(2), "Choose the earliest later same-class range, ignoring other classes")
        expect(TwitchAdPlaylist(header + nextRange + "\n" + afterRange).breaks.first?.end == clock.addingTimeInterval(200), "An as-yet unknown following range retains the bounded fallback")
        expect(TwitchAdPlaylist(header + nextRange + ",DURATION=50\n" + afterRange).breaks.isEmpty, "Ignore invalid END-ON-NEXT with an explicit duration")

        let titleHistory = TwitchAdPlaylist(header + "#EXT-X-PROGRAM-DATE-TIME:2026-11-06T12:00:00Z\n" +
            (0..<10).map { "#EXTINF:2,Amazon\nad-\($0).ts\n" }.joined()).breaks
        let titleWindow = TwitchAdPlaylist(header + "#EXT-X-PROGRAM-DATE-TIME:2026-11-06T12:00:20Z\n#EXTINF:2,Amazon\nad-10.ts\n#EXTINF:2,Amazon\nad-11.ts\n")
        let heldBreak = titleWindow.waitingBreak(after: clock, knownBreaks: titleHistory)
        expect(heldBreak?.start == clock, "Retain the original title-only break start after it leaves the window")
        expect(heldBreak?.end == clock.addingTimeInterval(24), "Extend the retained break to the latest ad edge")
        expect(titleWindow.waitingBreak(after: clock.addingTimeInterval(-10), knownBreaks: titleHistory) == nil, "History must not announce a future break over older buffered content")
        expect(TwitchAdPlaylist(clean).waitingBreak(after: clock, knownBreaks: titleHistory) == nil, "Clean content clears waiting even with retained ad history")
        let separatedWindow = TwitchAdPlaylist(header + "#EXT-X-PROGRAM-DATE-TIME:2026-11-06T12:00:40Z\n#EXTINF:2,Amazon\nlater-ad.ts\n")
        expect(separatedWindow.waitingBreak(after: clock, knownBreaks: titleHistory) == nil, "Never bridge an unobserved gap between separate breaks")
        print("Passed \(checks) live playlist checks")
    }
}
