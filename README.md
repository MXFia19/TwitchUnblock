# 🟣 TwitchUnblock

**TwitchUnblock** is an open-source Twitch client that lets you watch VODs and
live streams without a subscription, at full quality. Native iOS app built with
SwiftUI — also available [in your browser](https://test2-fawn-eta.vercel.app).

**Install it and it works.** There is nothing to configure, no server to set up,
no key to paste. The backend is already hosted and shared by every install.

| | |
|---|---|
| **iOS** | SwiftUI, iOS 16+, sideloaded |
| **Web** | [test2-fawn-eta.vercel.app](https://test2-fawn-eta.vercel.app) — source in [TwitchUnblock-Web](https://github.com/MXFia19/TwitchUnblock-Web) |
| **Setup needed** | None — sign in with Twitch and watch |

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
* 📡 **AirPlay** — send the stream to an Apple TV or a compatible TV.
* 🧭 **VOD chapters** — game changes marked on the progress bar; tap the current
  chapter to jump to another.
* ✂️ **Clips** — a Clips tab on every channel (24 h, 7 days, 30 days, all time),
  played with the original chat replayed.

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
* 📌 **Pinned messages** — compact banner with badges, emotes, who pinned it and
  a countdown; collapse it to a chip.
* 📊 **Polls, predictions, hype train** — vote, see the countdown, the results
  and the winning outcome.
* 🚀 **Raids** — follow the streamer to the raided channel automatically;
  incoming raids shown with a link to the raider. Each of these can be switched off.
* 🔦 **Highlights & filters** — messages mentioning you or containing your words
  stand out; hide bots, `!commands`, muted words or someone in particular.
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
* 🔄 **Cloud sync** — watch progress and history follow your Twitch account, so
  you pick up where you left off on another device.
* 🔔 **Live notifications** — be told when a followed channel goes live
  (checked in the background, as often as iOS allows).

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

**No install? Use it in your browser: https://test2-fawn-eta.vercel.app**

The website has its own repository, [TwitchUnblock-Web](https://github.com/MXFia19/TwitchUnblock-Web),
and shares this app's backend (the Cloudflare Worker, which now lives there too).

What you get on the web:

* Top streams without logging in, followed channels once logged in
* Live and VOD player with quality picker, speed, ±10 s, picture in picture, mini player
* Native chat: Twitch, BTTV, FFZ and 7TV emotes, badges, chat history, pinned message, replies
* VOD chat replayed in sync with the video
* Resume VODs where you left off, history synced with your Twitch account
* French, English and Spanish

Channel points, polls and predictions are **not** in the web version and cannot
be: they need the `twitch.tv` session cookie, which no third-party site can
read. For those, use the app.

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

### Backend

Playlist resolution, cloud sync and the usage count go through a Cloudflare
Worker that this project hosts. Nothing to do if you are just building the app —
it points at the shared instance out of the box.

If you **fork** the project and want your own backend, the Worker code and
deployment notes are in [`worker/`](worker/); change `kAPIURL` in
[`Sources/Constants.swift`](Sources/Constants.swift) to point at it.

---

## ⚠️ Disclaimer

Made for educational and personal use. **TwitchUnblock is not affiliated with,
endorsed by, or sponsored by Twitch Interactive, Inc.** All trademarks and
company names belong to their respective owners.

Support your favourite creators whenever you can.

## 📜 License

MIT — see [`LICENSE`](LICENSE). Do what you want with the code, keep the
copyright notice, and don't hold anyone liable.

This covers the code in this repository, and nothing else: Twitch's
trademarks, its API terms of service and the content on it are not ours to
license.
