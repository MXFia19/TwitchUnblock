# 🟣 TwitchUnblock

**TwitchUnblock** is an open-source Twitch client that lets you watch VODs and
live streams without a subscription, with full quality access through your own
proxy server. Native iOS app built with SwiftUI, plus a browser version.

| | |
|---|---|
| **iOS** | SwiftUI, iOS 16+, sideloaded |
| **Web** | React + TypeScript — see [`web/`](web/) |
| **Backend** | Your own Cloudflare Worker |

---

## ✨ Features

### Watching

* 🚫 **No subscription required** — watch any VOD or live stream at full quality.
* 🎬 **Immersive player** — custom controls drawn over the picture, the way
  Twitch does it. Play/pause, scrubbing, quality, refresh, orientation. Apple's
  native player stays available as a fallback in Settings.
* ⏩ **Double-tap to skip ±10 s** — consecutive taps add up, so three taps read
  "+30 s" instead of three separate "+10 s".
* 📺 **Picture-in-Picture** — keep watching while you use other apps.
* ⚙️ **Quality selector** — every resolution the channel broadcasts, Source
  included.
* ⏪ **Rewind a live stream (DVR)** — when the channel archives its broadcasts,
  the progress bar covers the *whole* stream, not just the rewindable window.
  Scrub past that window and the recording takes over at that exact moment.
  A **Back to live** button brings you back.
* ⚡ **Low latency mode** — stays as close to the live edge as the connection
  allows.
* 🖥 **Fill the screen** — crops the video to remove the black bars in
  landscape. Cuts off the top and bottom: 16:9 in a phone screen can't do both.
* 🌙 **Sleep timer** — presets or a custom duration, with the countdown shown
  right in the player.

### Chat

* 💬 **Full live chat** — read and send, with replies.
* 😀 **Emotes** — Twitch, BetterTTV, FrankerFaceZ and 7TV, global and
  per-channel, animated.
* 🏅 **Badges** — global and channel-specific, resolved through Helix.
* 🕘 **Recent messages** — Twitch sends nothing from before you join, so the
  last messages are fetched from `recent-messages.robotty.de` (third party) and
  marked with a clock.
* ⌨️ **Autocomplete** — emotes and names suggested as you type.
* 🗑 **Deleted messages** — optionally kept struck through instead of vanishing.
* 🎨 **Username colour** — changed through Helix (needs a re-login after the
  permission was added).
* 👤 **Tap a message** — opens the person: their avatar, everything they wrote
  in this session, reply, mention, copy.
* 📌 **Pinned messages, polls, predictions, hype train** and **raids** — each
  one can be switched off.
* 🔥 **Watch streak** and a **follow / unfollow** button.
* 🎁 **Channel points** — balance, rewards, and automatic bonus chest claiming.
* ⏱ **Auto-sync chat delay** — offsets the chat by the measured stream latency
  so it lines up with the picture.
* 📼 **VOD chat** — replayed in sync with playback position.

### Chat layout

* 📐 **Resizable** — drag the divider between video and chat; the width is
  remembered.
* 🪟 **Three landscape layouts** — a column on the right, translucent over the
  picture, or folded away. The player's buttons shift with the chat's width so
  nothing is ever covered.
* 🔠 **Sizing** — font size, message spacing, badge and emote scale,
  timestamps, with a live preview.

### Finding things

* 🏠 **Home** — your followed channels that are live, top streams (France or
  worldwide).
* 🎮 **Categories** — browse by game, then the live channels in it.
* 🔍 **Search** — by streamer name, channel link, or VOD ID.
* 🕒 **History** — recently watched VODs and channels, each removable.
* 🔄 **Cloud sync** — watch progress and history saved to your own Worker, so
  you pick up where you left off on another device.

### The rest

* 🌍 **Three languages** — English (default), French, Spanish.
* 🔐 **Web session check** — the Twitch web session has no known expiry date;
  it's verified at launch, and you're told when it needs restoring instead of
  channel points silently going quiet.
* 📊 **Anonymous usage count** — a random install ID and the app version, at
  most once an hour. No Twitch account, no channels watched, no IP address.
  Switching it off erases the ID server-side. See
  [`Sources/Services/UsageService.swift`](Sources/Services/UsageService.swift).
* 🪵 **System logs** — everything the app does, visible in Settings.

---

## 📲 Installation

TwitchUnblock isn't on the App Store, so it has to be sideloaded.

### AltStore / SideStore / Feather (recommended)

Automatic nightly builds, straight from your sideloader:

1. Open AltStore, SideStore or Feather.
2. Go to **Sources**.
3. Add:
   ```
   https://raw.githubusercontent.com/MXFia19/TwitchUnblock/master/apps.json
   ```
4. Install **TwitchUnblock** from there.

### Manual

Download the latest `TwitchUnblock.ipa` from the
[Releases](https://github.com/MXFia19/TwitchUnblock/releases) page and install it
with Sideloadly, AltStore, or TrollStore if your device supports it.

---

## 🌐 Web version

A browser build lives in [`web/`](web/): player, chat, discovery and settings,
sharing the same Worker and the same Twitch application.

```bash
cd web
npm install
npm run dev
```

Channel points, polls and predictions are **not** in the web version and cannot
be: they need the `twitch.tv` session cookie, which no third-party site can
read. [`web/README.md`](web/README.md) covers hosting (no domain needed) and the
one header to add to the Worker.

---

## 🛠️ Building from source

**Requirements:** macOS, Xcode 16+, iOS 16.0 deployment target.

```bash
git clone https://github.com/MXFia19/TwitchUnblock.git
cd TwitchUnblock
open TwitchUnblock.xcodeproj
```

Pick your development team under *Signing & Capabilities*, then build the
`TwitchUnblock` scheme onto your device.

The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen): run `xcodegen` after adding
files. GitHub Actions builds and publishes nightly IPAs from `master`.

### Worker

The app talks to your own Cloudflare Worker for playlist resolution, cloud sync
and the usage count. Setup notes are in [`worker/`](worker/).

---

## ⚠️ Disclaimer

Made for educational and personal use. **TwitchUnblock is not affiliated with,
endorsed by, or sponsored by Twitch Interactive, Inc.** All trademarks and
company names belong to their respective owners.

Support your favourite creators whenever you can.

## 📜 License

MIT.

> No `LICENSE` file is committed yet — the terms above aren't enforceable
> without one. Drop a standard MIT text at the repository root to fix that.
