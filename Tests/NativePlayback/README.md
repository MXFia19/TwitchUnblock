# Native playback regression

Manual GitHub Actions workflows that play synthetic streams through the production playlist parser, resource loader and ad monitor. No Twitch account, no live stream.

| Workflow | What it checks |
|---|---|
| `Native playback regression tests` (`test-native-playback.yml`) | AVPlayer on macOS with H.264/AAC MPEG-TS streams: the five cases below, and the video's proportions through ad gaps (the production `PlayerLayerGeometry` controller on a rendered `AVPlayerLayer`, with a viewport resize and fit/fill changes while the last clean frame is held) |
| `iOS playback geometry regression` (`test-ios-playback.yml`) | A small iPhone simulator app built with the exact `PlayerLayerUIView` and `PlayerLayerView` from `ImmersivePlayer.swift`: the ad banner, and the proportions before, during and after the gap, with a JSON report and a screenshot |

A pass needs the geometry controller to be active: falling back to AVPlayer's default sizing doesn't pass. The simulator run validates the guard on iOS, but can't reproduce every physical device or Twitch rendering failure.

## The five cases

- **Direct HTTPS control:** playback advances and video frames are decoded.
- **Wrapped control:** the same, through the production resource loader.
- **All-ad preroll:** a waiting indicator shows, then clean video is decoded.
- **Midroll:** frames are decoded before and after the break.
- **Title-only sliding midroll:** the ad is seen, and clean video is decoded before and after the break, while older segments leave the playlist window.

A separate deterministic check feeds playlist notifications into the production ad monitor, with a simulated waiting player and a held playback date: the indicator must survive twelve sliding-window refreshes and clear on clean content. It covers the held-clock branch even when native macOS playback moves its clock through gaps. Run the compiled check with `--held-clock-only` to try that branch without the HTTPS server.

## Rules

- The server's request logs must show **no marked ad segment fetched** in any ad case.
- Each case has its own URL and request history.
- Any failed preflight or playback assertion fails the workflow; an empty request log never counts as a success.

<details>
<summary><b>Test server and media</b></summary>

The fixture uses a real HTTPS server bound to `127.0.0.1:8765` (`server.py`). The workflow creates a one-day localhost certificate and trusts it only on its disposable hosted runner, then waits for HTTPS health checks before launching the test. The server skips reverse DNS on startup. **Don't install its temporary certificate on a personal machine** just to run this workflow.

This replaced the broken `fixture.invalid` URLProtocol interceptor, which the loader's URLSession didn't use; readiness checks also replaced a fixed one-second startup delay. Neither needs a networking exception in the app.

The media is a synthetic blue image and a sine tone, made with:

```sh
ffmpeg -f lavfi -i color=c=blue:s=160x90:r=10 \
  -f lavfi -i sine=frequency=440:sample_rate=48000 -t 60 \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 20 -sc_threshold 0 \
  -c:a aac -b:a 48k -f hls -hls_time 2 -hls_list_size 0 \
  -hls_segment_filename media/segment%03d.ts media/source.m3u8
```

Coverage is buffered MPEG-TS playback on macOS. Physical iOS and tvOS devices, fMP4, low-latency timing, AirPlay, background playback and live Twitch behavior remain device checks. Pure parser regressions also cover quoted attribute values, END-ON-NEXT boundaries and kept title-only history.

</details>
