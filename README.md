<div align="center">

<img src="assets/icons/previews/Purple.png" width="112" alt="TwitchUnblock icon">

# TwitchUnblock

**Watch Twitch without a subscription, at full quality, with the real chat.**<br>
An open-source app for iPhone, iPad and Apple TV.

[![Version](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2FMXFia19%2FTwitchUnblock%2Fmaster%2Fapps.json&query=%24.apps%5B0%5D.version&label=version&color=9146ff)](https://github.com/MXFia19/TwitchUnblock/releases)
[![iOS 16+](https://img.shields.io/badge/iOS-16%2B-111111?logo=apple&logoColor=white)](#-install)
[![Discord](https://img.shields.io/badge/Discord-join%20the%20community-5865F2?logo=discord&logoColor=white)](https://discord.gg/cEsMRdxsVq)
[![License: MIT](https://img.shields.io/badge/license-MIT-2ea44f)](LICENSE)

<a href="https://altdirect.app/?url=https://raw.githubusercontent.com/MXFia19/TwitchUnblock/master/apps.json"><img src="https://altdirect.app/assets/png/AltSource_Blue.png" alt="Add AltSource" width="190"></a>
&nbsp;
<a href="https://github.com/MXFia19/TwitchUnblock/releases/latest/download/TwitchUnblock.ipa"><img src="https://altdirect.app/assets/png/Download_Blue.png" alt="Download .ipa" width="190"></a>

[Website](https://twitchunblock-web.pages.dev) · [Android](https://github.com/MXFia19/TwitchUnblock-Android) · [Full documentation](DOCUMENTATION.md) · [Discord](https://discord.gg/cEsMRdxsVq)

</div>

> [!NOTE]
> **Nothing to set up:** install it, sign in with Twitch if you want, and watch.
> **Vibe-coded project:** built with AI coding assistants, prompted, reviewed and
> tested by a human. Expect rough edges: bug reports on Discord help a lot.

## ✨ Features

#### 📺 Watching
- **No subscription needed:** every live and every VOD, at full quality.
- **Fewer ads:** the ad segments it recognizes are cut before playback. Subscribed or on Turbo? No ads at all, through your account.
- **Live sources in your order:** the Bulgaria relay (test), official Twitch, or your own source or proxy.
- **A real player:** picture in picture, a mini player, background audio, AirPlay, sleep timer, speed from 0.25× to 2×, double-tap ±10 s, pinch to zoom.
- **Rewind a live** (DVR), or stay close to the live edge with low latency.
- **Multi-live:** up to four lives and VODs side by side.
- **Offline downloads:** a whole VOD or just a part, with its chat.
- **Every broadcast:** unlisted and deleted ones, muted parts on the progress bar, chapters and clips.

#### 💬 Chat
- **The real Twitch chat:** read, send and reply, with Twitch, BTTV, FFZ and 7TV emotes, badges and recent messages.
- **Polls, predictions, hype trains, raids and pinned messages.** On VODs, the chat replays in sync.
- **Your layout:** resize it, pick one of three landscape layouts or drag it over the video, and set sizes and filters.

#### 🎁 With your Twitch account
- **Channel points:** your balance and rewards, with bonus chests claimed for you.
- **Drops:** they progress while you watch, you get a notification when one is ready, and you claim it in the app.
- **Followed channels and live notifications.** Your history and settings follow your account.

#### 🧭 Finding things
- **Home, Discover, categories, search and schedules.** Pin streamers, and hide channels, categories or tags.
- **Continue watching:** VODs resume where you stopped, and your progress follows your Twitch account.

#### 🎨 Make it yours
- **Themes:** 7 colours and 3 backgrounds, Liquid Glass on iOS 26, and tabs you can show, hide and reorder.
- **Six app icons**, and **7 languages:** English, French, Spanish, Russian, Italian, Japanese and Traditional Chinese.

<p align="center">
  <img src="assets/icons/previews/Default.png" width="52" alt="Default icon">
  <img src="assets/icons/previews/Purple.png" width="52" alt="Purple icon">
  <img src="assets/icons/previews/Night.png" width="52" alt="Night icon">
  <img src="assets/icons/previews/Light.png" width="52" alt="Light icon">
  <img src="assets/icons/previews/Neon.png" width="52" alt="Neon icon">
  <img src="assets/icons/previews/Contrast.png" width="52" alt="Contrast icon">
</p>

**Every feature, in detail:** [DOCUMENTATION.md](DOCUMENTATION.md#-features)

## 📲 Install

TwitchUnblock isn't on the App Store, so you sideload it.

| Device | How |
|---|---|
| **iPhone & iPad** | **Add AltSource** above (AltStore, SideStore, Feather, LiveContainer, StikStore, TrollApps), then install **TwitchUnblock**: it updates itself. Or **Download .ipa** for Sideloadly or TrollStore. |
| **Test builds** | **TU Test**, in the same source: the newest features, installed next to the normal app. |
| **Apple TV** (test) | ATVLoadly, or Xcode on a Mac: [steps and sources](DOCUMENTATION.md#-apple-tv-test). |
| **Mac** (M1 or newer) | Open the `.ipa` with [PlayCover](https://playcover.io). |
| **Anything else** | The [website](https://twitchunblock-web.pages.dev) works in any browser, and there is an [Android app](https://github.com/MXFia19/TwitchUnblock-Android). |

<details>
<summary>Source address, to add it by hand</summary>

```
https://raw.githubusercontent.com/MXFia19/TwitchUnblock/master/apps.json
```

</details>

## 🛠️ Build from source

```bash
git clone https://github.com/MXFia19/TwitchUnblock.git && cd TwitchUnblock
xcodegen generate && open TwitchUnblock.xcodeproj
```

You need macOS, Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
Signing, version numbers and the backend are explained in [DOCUMENTATION.md](DOCUMENTATION.md).

## 🙌 Contributors

[Domenico-lel](https://github.com/Domenico-lel) (Italian) · [kinboy56](https://github.com/kinboy56) (Japanese) ·
[trend0522](https://github.com/trend0522) (Traditional Chinese) · [dwojc6](https://github.com/dwojc6) (swipe-down on the player) ·
[ihavenoface](https://github.com/ihavenoface) (live ad filtering) · [everyone on GitHub](https://github.com/MXFia19/TwitchUnblock/graphs/contributors)

---

<sub>For educational and personal use. TwitchUnblock is not affiliated with, endorsed by or sponsored by Twitch Interactive, Inc.; all trademarks belong to their owners. Support your favourite creators whenever you can. Code under the [MIT license](LICENSE).</sub>
