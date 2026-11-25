# Tests

Checks that need no Twitch account and no network. CI runs each one on its own when the code it covers changes; the full app builds (`build.yml`, `build-tvos.yml`) stay the compilation checks.

| Check | Run it | Workflow |
|---|---|---|
| VOD silence probe | `sh tools/test-vod-silence.sh` | `test-vod-silence.yml` |
| Live playlists (parser, ad filtering) | `sh tools/test-live-playlists.sh` | `test-live-playlists.yml` |
| Native playback (AVPlayer, macOS) | manual | `test-native-playback.yml`: see [NativePlayback](NativePlayback/README.md) |
| Playback geometry (iPhone simulator) | manual | `test-ios-playback.yml` |

Swift 5.9 or newer, on macOS.

## VOD silence probe

Compiles `Sources/Services/VodSilence.swift` with `VodSilenceTests.swift`:
- TS and fMP4 segments built in the test (silent 6-byte frames, sound, Twitch's 5-sample fMP4 fragments, partial reads, two-track fMP4);
- the 10/50/90 % segment choice around muted parts;
- 300 rounds of randomly damaged bytes (no crash, no endless loop).

The website's copy of the probe has its own checks: `node tools/silence-check.mjs` in the web repo.

## Live playlists

The fixtures exercise the production parser and rewriter. CI also typechecks the loader and monitor against the real AVFoundation and Combine on macOS. It runs when the parser, loader, monitor, their tests, the script or the workflow change.

<details>
<summary><b>How ads are filtered</b></summary>

The ad markers follow [Streamlink's Twitch plugin](https://github.com/streamlink/streamlink/blob/master/src/streamlink/plugins/twitch.py): `twitch-stitched-ad` classes, `stitched-ad-` IDs, and `Amazon` EXTINF titles. The Swift implementation uses HLS `EXT-X-GAP` instead of Streamlink's progressive output filtering ([Apple documents GAP handling](https://developer.apple.com/videos/play/wwdc2017/514/) for temporary segment unavailability). Sequence numbers, durations, byte ranges, keys and discontinuities stay intact; the next clean segment keeps its original initialization map. Twitch prefetch entries are removed before playback.

Filtering doesn't recover video Twitch replaced with ads: during a break the player may hold its last frame or buffer until clean media arrives. There's no Streamlink prefetch downloader, and no proxy switching beyond the existing higher-quality account fallback.

</details>

<details>
<summary><b>Device checks before a release</b></summary>

Parser fixtures can't prove AVPlayer's buffering, background, PiP or AirPlay behavior. Before a release, check:

- Start during an all-ad preroll, wait through a long midroll, and confirm the live video resumes. Check MPEG-TS and fMP4 streams, and watch the segment requests to confirm GAP-marked media isn't downloaded.
- Repeat with low latency on and off, audio only, the native and custom players, multi-live and Apple TV. A known multi-live preroll gets up to 220 seconds before its startup watchdog retries; stale or failed playlist requests get no grace.
- Pause, change quality or channel, and close during a break. No cancelled request should finish into the old player; a paused player must stay paused.
- Test the higher-quality account fallback and the return once the account playlist's startup window is clear. Buffered clean video must not trigger an early switch just because a future ad is announced.
- Enter AirPlay: the receiver uses the original CDN playlist, so local GAP filtering isn't available. This fallback is logged and the original signed URL is kept; the ad banner and muting still work locally.

</details>
