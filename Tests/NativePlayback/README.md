# Native playback regression

The manual `Native playback regression tests` GitHub Actions workflow compiles
`Playback.swift` with the production playlist parser, resource loader, and ad
monitor, then plays synthetic H.264/AAC MPEG-TS streams with AVPlayer on macOS.
No Twitch account or live Twitch stream is used.

The checks also attach the production `PlayerLayerGeometry` controller to a
rendered AVPlayerLayer. They compare its frame proportions with decoded video
through ad discontinuities, including a viewport resize and fit/fill changes
while the last clean frame is held. A passing result requires the geometry
controller to be active; merely falling back to AVPlayer's default sizing does
not pass.

The separate manual `iOS playback geometry regression` workflow builds a small
iPhone simulator app using the exact `PlayerLayerUIView` and `PlayerLayerView`
definitions extracted from `ImmersivePlayer.swift`. It shows the ad banner,
checks video proportions before/during/after the gap, and saves a JSON report
and screenshot. This validates the guard on iOS but does not guarantee that a
particular physical-device/Twitch rendering failure can be reproduced.

The five cases require:

- Direct HTTPS control: advancing playback and decoded video frames.
- Wrapped control: the same through the production resource loader.
- All-ad preroll: an observed waiting indicator, followed by decoded clean video.
- Midroll: decoded frames before and after the break.
- Title-only sliding midroll: observed ad indication and decoded clean video
  before and after the break, while older segments leave the playlist window.

A separate deterministic check feeds playlist notifications into the production
ad monitor with a simulated waiting player and held playback date. It requires
the indicator to survive twelve sliding-window refreshes and clear on clean
content. This covers the held-clock branch even when native macOS playback
advances its clock through GAPs. Run the compiled check with `--held-clock-only`
to exercise this branch without the HTTPS server.

Server request logs must show no marked ad segments fetched in any ad case.
Each case uses its own URL and request history. Any failed preflight or playback
assertion fails the workflow; an empty request log cannot count as success.

The fixture uses a real HTTPS server bound to `127.0.0.1:8765`. The workflow
creates a one-day localhost certificate and trusts it only on its disposable
hosted runner. It waits for HTTPS health checks before launching the test.
The server avoids reverse DNS on startup. Do not install its temporary trust
certificate on a personal machine simply to run this workflow.

This replaces the broken `fixture.invalid` URLProtocol interceptor, which the
loader's URLSession did not use. Readiness checks also replace a fixed one-second
startup delay. Neither change requires a production networking exception.

The media is a synthetic blue image and sine tone, generated with:

```sh
ffmpeg -f lavfi -i color=c=blue:s=160x90:r=10 \
  -f lavfi -i sine=frequency=440:sample_rate=48000 -t 60 \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 20 -sc_threshold 0 \
  -c:a aac -b:a 48k -f hls -hls_time 2 -hls_list_size 0 \
  -hls_segment_filename media/segment%03d.ts media/source.m3u8
```

Coverage is buffered MPEG-TS playback on macOS. Physical iOS/tvOS devices,
fMP4, low-latency timing, AirPlay, background playback, and live Twitch behavior
remain separate device checks. Pure parser regressions additionally cover
quoted attribute values, END-ON-NEXT boundaries, and retained title-only history.
