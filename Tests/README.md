# Live playlist checks

Run `sh tools/test-live-playlists.sh` with Swift 5.9 or newer. The fixtures compile
and exercise the production parser and rewriter without a Twitch account or
network access. CI additionally typechecks the loader and monitor against real
AVFoundation and Combine on macOS. The existing iOS/tvOS build workflows remain
the full app compilation checks.

The ad markers follow [Streamlink's Twitch plugin](https://github.com/streamlink/streamlink/blob/master/src/streamlink/plugins/twitch.py):
`twitch-stitched-ad` classes, `stitched-ad-` IDs, and `Amazon` EXTINF titles.
The Swift implementation uses HLS `EXT-X-GAP` instead of Streamlink's progressive
output filtering. [Apple documents GAP handling](https://developer.apple.com/videos/play/wwdc2017/514/)
for temporary segment unavailability. Sequence numbers, durations, byte ranges,
keys, and discontinuities stay intact; the next clean segment keeps its original
initialization map. Twitch prefetch entries are removed before playback.

The manual [native playback workflow](NativePlayback/README.md) additionally
checks decoded AVPlayer frames and segment requests for HTTPS controls, all-ad
preroll, and midroll recovery on macOS.

Device validation is still required: parser fixtures cannot prove AVPlayer's
buffering, background, PiP, or AirPlay behavior. Before release, check:

- Start during an all-ad preroll, wait through a long midroll, and confirm live
  video resumes. Check MPEG-TS and fMP4 streams and observe segment requests to
  confirm GAP-marked media is not downloaded.
- Repeat with low latency on/off, audio-only, native/custom players, multi-live,
  and Apple TV. A known multi-live preroll gets up to 220 seconds before its
  startup watchdog retries; stale or failed playlist requests do not get grace.
- Pause, change quality/channel, and close during a break. No cancelled request
  should finish into the old player; a paused player must stay paused.
- Test existing higher-quality account fallback and return after the account
  playlist's startup window is clear. Buffered clean video must not trigger an
  early switch just because a future ad is announced.
- Enter AirPlay: the receiver uses the original CDN playlist, so local GAP
  filtering is unavailable. This fallback is logged and the original signed URL
  is preserved. The metadata banner/muting behavior remains available locally.

Filtering does not recover video Twitch replaced with ads. During a break the
player may hold its last frame or buffer until clean media arrives. This change
does not add Streamlink's prefetch downloader or expand proxy switching beyond
the existing higher-quality account fallback.
