# 🟣 TwitchUnblock

[![Discord](https://img.shields.io/badge/Discord-Join%20the%20community-5865F2?logo=discord&logoColor=white)](https://discord.gg/cEsMRdxsVq)
[![Version](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2FMXFia19%2FTwitchUnblock%2Fmaster%2Fapps.json&query=%24.apps%5B0%5D.version&label=version&color=9146ff)](https://github.com/MXFia19/TwitchUnblock/releases)

> 💬 **Join the Discord — https://discord.gg/cEsMRdxsVq** — news, help, bug reports and ideas.

**TwitchUnblock** is an open-source Twitch client that lets you watch VODs and
live streams without a subscription, at full quality. Native iOS app built with
SwiftUI — also available [in your browser](https://twitchunblock.vercel.app).

> 🤖 **Vibe-coded project.** TwitchUnblock is built with AI coding assistants
> (prompted, reviewed and tested by a human). Expect rough edges: bug reports
> on Discord help a lot.

**Install it and it works.** There is nothing to configure, no server to set up,
no key to paste. The backend is already hosted and shared by every install.

| | |
|---|---|
| **iOS** | SwiftUI, iOS 16+, sideloaded |
| **Web** | [twitchunblock.vercel.app](https://twitchunblock.vercel.app) — source in [TwitchUnblock-Web](https://github.com/MXFia19/TwitchUnblock-Web) |
| **Setup needed** | None — sign in with Twitch and watch |

---

## 📲 Installation

TwitchUnblock isn't on the App Store, so it has to be sideloaded.

<h3 align="center">
<a href="https://altdirect.app/?url=https://raw.githubusercontent.com/MXFia19/TwitchUnblock/master/apps.json" target="_blank"><img src="https://altdirect.app/assets/png/AltSource_Blue.png" alt="Add AltSource" width="200"></a>
&nbsp;
<a href="https://github.com/MXFia19/TwitchUnblock/releases/latest/download/TwitchUnblock.ipa" target="_blank"><img src="https://altdirect.app/assets/png/Download_Blue.png" alt="Download .ipa" width="200"></a>
</h3>

**Add AltSource** opens the source in AltStore, SideStore, Feather, LiveContainer,
StikStore or TrollApps (automatic nightly builds): install **TwitchUnblock** from
it. It also lists **TU Test**, the test builds (newest features, may be
unstable), installed next to the normal app. **Download .ipa** gets the latest
build, for Sideloadly or TrollStore. Source address, to add it by hand:

```
https://raw.githubusercontent.com/MXFia19/TwitchUnblock/master/apps.json
```

**Apple TV**: see [Apple TV (test)](#-apple-tv-test) below. **No install**: the
[web version](https://twitchunblock.vercel.app) runs in any browser.

---

## ✨ Features

### Watching

* 🚫 **No subscription required** — watch any VOD or live stream at full quality.
* 🎬 **Immersive player** — custom controls drawn over the picture, the way
  Twitch does it. Play/pause, scrubbing, quality, refresh, a speaker button to
  mute the stream, orientation. On iPhone the app stays in portrait;
  landscape is for the player opened full size and multi-live, and closing
  or shrinking the player in landscape brings the app back to portrait. Apple's
  native player stays available as a fallback in Settings. Changing quality
  keeps your place, in Apple's player too (a live you rewound keeps its delay);
  a VOD you had finished starts over from the beginning; when the stream drops for good, the
  player says so with **Retry** instead of freezing (a live first reloads
  itself twice, unless you had paused it). When the connection comes back
  after a drop, a player stopped on **Retry** (or on a loading error) and
  failed multi-live tiles start again on their own, once, two seconds later.
* 📱 **Home indicator out of the way** — in landscape, with the player full
  size (app's or Apple's) or in multi-live, the bar at the bottom of the
  screen fades after a few seconds, like in video apps; touch the screen to
  bring it back.
* 🐢 **Playback speed** — 0.25× to 2× on VODs and clips, from the ⋯ menu (or
  Apple's own speed menu in the native player and on Apple TV). The VOD speed
  is remembered from one VOD to the next, shown next to the timer, and synced
  with the website through the backup file; clips start at 1×, live streams
  always play at normal speed. Catching up with a live recording drops back to
  1× near its edge (Apple's player too, whose menu used to keep showing 2×),
  and the chosen speed comes back once you rewind away from the edge. A speed
  the player can't keep (AirPlay, slow motion refused, or measured lower than
  asked once applied again) is announced and shown as it really plays, for
  the current video only.
* 🧪 **Experimental 2.25×, 2.5× and 3×** — in the ⋯ menu of the app's player,
  marked with a test tube, for the current video only. Twitch publishes no
  I-frame playlists, so iOS only guarantees up to 2×: as soon as playback
  can't keep up (speed refused or measured lower, stall), it goes back to 2×.
* ⏩ **Double-tap to skip ±10 s** — consecutive taps add up, so three taps read
  "+30 s" instead of three separate "+10 s". On a live there's nothing to skip
  ahead to: in landscape, double-tap shows or hides the chat instead, and once
  you fall behind (pause, network drop) a red **Live** button with the delay
  brings you back to the edge. Double-tapping works with the controls shown
  too. With **Show latency** on (Settings → Player), tapping the delay brings
  you back to live as well, without reloading the stream.
* 📺 **Picture-in-Picture** — keep watching while you use other apps, or the
  rest of the app with the player reduced. Closing the player, opening another
  video or switching to chat only ends it, along with its chat connection and
  lock screen activity.
  Starting it shrinks the player into the mini player, so you can browse the app right away (no more black full-size player to close).
  The PiP window's expand button brings the player back full size on the same video, without reloading (with the app's player, tapping the mini player does too).
* 🪟 **PiP when leaving the player** — optional, off by default (Settings → Player): swiping a live or VOD down, or the back arrow, opens it in Picture-in-Picture instead of the mini player while it plays (app's player; Apple's player keeps the mini player).
* 🔒 **Lock Screen and Dynamic Island** — the live or VOD you're watching
  (channel, title, playback) as a Live Activity; turn it off in Settings →
  Player → Live Activity if you don't need it. When iOS refuses it because the
  installer rewrote the app's Info.plist (missing `NSSupportsLiveActivities`),
  the app stops asking until its next launch: one line in the log instead of
  one per video.
* 🏷️ **Full title** — tap the title at the top of the player (often cut off)
  to read it in full, with the category, viewers, uptime and a shortcut to the
  channel. Closing a channel page opened from the full-size player (name,
  title or chat) brings the player back full size instead of the mini player.
* 🎵 **Leaves your music alone** — opening the app no longer stops music
  playing in another app: the sound switches over only when a video starts,
  and goes back to that app when you close the player (not when the sleep
  timer stops it).
* 📞 **Picks up after a call** — a call, Siri, an alarm or another app's
  sound pauses the video; once it's over, playback resumes on its own: VODs,
  clips, downloads and a live's recording (DVR) where they left off, live
  streams back at the live edge. A live you had rewound in the app's player
  picks up where you were only while the stream still holds that moment: it
  keeps just its last 30 seconds, so after a short interruption like Siri,
  not a call. When another app's audio stops without telling iOS, the video
  resumes as soon as you come back to the app, provided nothing else is
  playing and you're not on a call; otherwise it waits for you to press play
  (in multi-live, a **Play** button on each tile that stopped). A video you
  paused stays paused, and unplugging headphones pauses without resuming.
  Multi-live and Apple TV too, their live streams always back at the edge.
* ⚙️ **Quality selector and preferred quality** — every resolution the channel
  broadcasts, Source included, sorted by height then frame rate. Pick a
  preferred quality once (Settings → Player: Source, 1080p, 720p, 480p, 360p,
  160p or audio only): lives, VODs and clips start in it, or in the closest
  one below when the channel doesn't have it. The real height of each quality
  is read from the playlist, so “720p” also finds a channel whose Source is
  720p60. Picking a quality in the player replaces the preference (as on the
  website); backups carry it under the website's name (`qualityPref`).
* 🛡 **Live sources, in the order you pick** — lives come from sources that
  avoid most ads (Luminous Asia, an Albania proxy based on TTV.LOL, Luminous
  Europe) or official Twitch (with ads), tried one after the other until one
  answers, without waiting a minute on one that stays silent: the loading
  screen says which one is being tried, and the player can be minimized or
  closed while it loads.
  Reorder them in Settings → Player; picking a source from the player's ⋯
  menu (which also ticks the source in use) moves it to the top, or tries it
  again.
  Channels that stream with multiple encodes (Enhanced Broadcasting) keep each
  quality's own name on every source. No source escapes the channel's own ad
  breaks: Twitch stitches them into the stream itself. When Twitch's own API
  doesn't answer (filtered network), the sources are still tried; when none of
  them answers, the player says so — not "offline" — with **Retry**.
* ⭐ **Ad-free with your sub** — subscribed to the channel (or Turbo, when the
  channel allows it)? With the web session connected, the live goes through
  your Twitch account and Twitch serves it without ad breaks, just like on
  Twitch (Settings → Player → Watch ad-free with my sub, on by default; Twitch
  then sees your account watching). Never used on a channel where your account
  would get ads (except for Higher qualities, below, with the ad-free source
  taking over during Twitch's ad breaks); if your account's stream doesn't
  answer, the usual sources take over. Picking a source in the ⋯ menu skips
  your account for that channel until the app restarts.
* 💎 **Higher qualities (if the channel offers them)** — off by default
  (Settings → Player, under Watch ad-free with my sub). Channels on Enhanced
  Broadcasting can send 1440p and above, sometimes in HEVC or AV1; the app
  then tells Twitch which codecs the device decodes (`supported_codecs`: H.264
  always, HEVC and AV1 only when decoded in hardware) and the extra qualities
  show up in the quality picker. Twitch only serves them to a signed-in
  account (an anonymous playback token stops at 1080p), so 1440p goes through
  your account (web session); the mirrors, official Twitch without an account
  and the TwitchUnblock server stay as they are. With a sub or Turbo, nothing
  else changes: the whole stream is ad-free through your account. Without
  them, the app asks for your account's playlist alongside the usual ad-free
  source and only plays through your account when it goes above 1080p and
  your starting quality is above 1080p too (Source by default) — otherwise the
  usual source plays, exactly as before. Twitch puts its ads in your account's
  stream, so during each Twitch ad break (the `twitch-stitched-ad` tags the
  player already reads) the player switches by itself to the usual source in
  1080p without ads (“Twitch ad break: 1080p without ads”), the way it
  switches qualities: no reload, chat and Live Activity stay. When the break
  is over (its announced length plus a margin, and once your account's
  playlist is back to the stream for the last few seconds, which also covers
  an ad announced later), it goes back to your account in 1440p. A pre-roll at
  the start of your account's stream is caught before playback: the stream
  opens on the ad-free source and moves to your account when the ad ends.
  A quality you picked yourself is kept (1080p during the break if yours is
  higher). Ads again right after two returns, an account stream that stops
  working or no longer answers: the app stays on the ad-free source and skips
  your account on that channel until it restarts. If the ad-free source fails
  during a break, the player goes back to your account at once (the ad muted
  and explained, as on the other sources) and reloads the usual source for
  the next break. The source shows as “Your account (higher quality)” in the
  ⋯ menu; picking a source there leaves your account for that channel, as
  with a sub.
* 📢 **Channel ad breaks explained** — during an ad break (or the pre-roll
  when a stream opens), Twitch replaces the stream with its purple
  “Commercial break in progress” screen or a real ad. The player now says so,
  with a countdown to the stream's return, and mutes the sound meanwhile
  (restored at the end). Works in the app's player, Apple's player, each
  multi-live tile and on Apple TV (banner and countdown only: tvOS's player
  has no button to turn the sound back on).
* ⏪ **Rewind a live stream (DVR)** — when the channel archives its broadcasts,
  the progress bar covers the *whole* stream, not just the rewindable window.
  Scrub past that window and the recording takes over at that exact moment.
  A **Back to live** button brings you back, and so does dragging to the very
  end of the bar.
* ⚡ **Low latency mode** — stays as close to the live edge as the connection
  allows, but never under 4 seconds behind (closer, playback stalls): the
  target follows how long Twitch takes to publish each segment, and skipping
  ahead or **Live** stop there too. It never changes the playback speed
  (speeding up could pull the sound out of sync): the player only makes a
  small jump when it really falls behind, and never undoes a rewind. Turned
  off, the proxies (Luminous, TTV.LOL) serve the regular stream too, like
  official Twitch.
* 🖥 **Fill the screen** — crops the video to remove the black bars in
  landscape. Cuts off the top and bottom: 16:9 in a phone screen can't do both.
  Otherwise the picture never goes under the Dynamic Island or the notch in
  landscape, even when the chat takes a column next to it.
* 🌙 **Sleep timer** — presets or a custom duration, with the countdown shown
  right in the player. It stops multi-live too. The screen only stays awake
  while a video plays on screen: paused, minimized or in audio only, it
  sleeps as usual (the sound goes on).
* 📡 **AirPlay** — send the stream to an Apple TV or a compatible TV.
* 🎧 **Spatial audio (AirPods)** — turn it off in the app, head tracking
  included (Settings → Player). iOS doesn't let apps pick "Fixed" or "Head
  Tracked": that choice stays in Control Center.
* 🧭 **VOD chapters** — game changes marked on the progress bar; tap the current
  chapter to jump to another.
* 🔇 **Muted parts** — passages Twitch muted for copyrighted music show in orange
  on the progress bar, with a notice and a **Skip** button. For a day or two
  after a stream, Twitch's CDN still serves the original sound: the app puts it
  back automatically (Settings → Player; not over AirPlay). On VODs in the newer
  MP4 format, Twitch often still serves muted parts with their sound: the app
  plays and downloads them as they are instead of swapping in the silent
  version. Muted parts that Twitch lists under a name its CDN refuses are
  fixed on the device when the backend can’t do it, and a VOD that stops on one
  starts again at the same place on its own; **Skip** works even then.
* 🗂 **Unlisted & deleted broadcasts** — streams whose VOD is hidden or was
  deleted show up among the channel's VODs as "Unlisted VOD", rebuilt from
  Twitch's CDN as long as it still has them (stream IDs from `vodvod.top`,
  third party).
* ✂️ **Clips** — a Clips tab on every channel (24 h, 7 days, 30 days, all time),
  played with the original chat replayed.
* 📤 **Share & clip the moment** — **Share** in the player's ⋯ menu opens iOS's
  share sheet with the VOD (or the rewound live) at the current time
  (`twitch.tv/videos/<id>?t=1h2m3s`), the channel during a live, or the clip's
  link. **Create a clip** (same menu, during a live) clips the moment on screen
  with your Twitch account, through the web session as for channel points
  (connect it from there if it isn't); the clip's link comes back with **Copy**
  and **Share**. A channel that refuses clips, a stream that has ended or
  Twitch saying no is told plainly (details in the log).
* 📥 **Offline downloads** — download a whole VOD or just a part of it (from one
  time to another, from where you are, the next 10 minutes) in the quality you
  pick (your preferred quality is suggested first), then watch it without a connection from the My VODs tab. With the app
  open, the app downloads the segments itself (four at a time, any error shown
  under the download); when you leave it, what's left goes to iOS's background
  downloads, in batches, and keeps going even with the app closed (resumed if
  you swipe it away). Parts muted for copyrighted music keep their original sound when
  Twitch still has it (a day or two after the stream; on VODs in the MP4
  format, whenever Twitch serves them with their sound). The chat can be kept
  too and is replayed offline, emotes included. Export a download as a single
  file (Files, AirDrop, VLC). Before it starts, the sheet shows the estimated
  size (the quality's bitrate × the length) and the free space, and refuses
  with a clear message when there isn't enough room. **Download on Wi-Fi
  only** (Settings → Player, or right in the sheet; off by default) keeps
  downloads off cellular data: they wait for Wi-Fi, then resume on their own.
  Pause, resume (▶), retry (⟳) and delete from the list.
* 🧩 **Multi-live** — up to four videos side by side, lives and VODs mixed,
  on iPad as on iPhone: long-press a live or VOD card (a channel's VODs and
  highlights, My VODs), or use the player's ⋯ menu, to add it — a “+” then
  shows on every live card — and tap **Watch** in the bar at the bottom. Tap
  a video to hear it, open any of them in the player (a VOD resumes where its
  tile was), add a channel by name or link, or a VOD by link or ID. A VOD
  tile resumes where you left off; the one you hear has play/pause, ±10 s
  and a seek bar, the others a thin progress line, and “Watch again” at the
  end. Its progress is saved and synced, and it joins your VOD history.
  Side by side in landscape, stacked in portrait; the ⇄ button on a tile
  swaps its place with another video (with three, the first one is the big
  one). On iPad (or a large iPhone
  in landscape), the chat of the video you hear shows on the right (the
  replayed chat for a VOD) — a button in the mosaic and Settings → Player
  turn it on or off. Each tile plays 1080p alone, 720p with two, 480p
  beyond — or your preferred quality when it is lower.
* 🔊 **Several sounds in multi-live** — tapping a tile still makes it the
  only one you hear; tap the speaker on other tiles to hear them too, and
  long-press it for that tile's volume (100 %, 75 %, 50 %, 25 %).

### Chat

* 💬 **Full live chat** — read and send, with replies. Emotes and badges get
  3.5 s to load before the chat connects (each request gives up after 10 s),
  so a slow or blocked service no longer leaves it on “Connecting…”; after
  three failed attempts in a row, a line in the chat says so and points to
  **Reconnect chat**.
* 🚫 **Banned from a chat? Still readable** — when Twitch refuses your account
  in a channel's chat (banned), the chat keeps going read-only without your
  account, with a banner in place of the message box and a **Retry with my
  account** button for when you're unbanned (remembered until the app
  closes). A timeout only adds a line saying for how long.
* 😀 **Emotes** — Twitch, BetterTTV, FrankerFaceZ and 7TV, global and
  per-channel, animated (FrankerFaceZ included); GIFs sent with Twitch's GIF
  keyboard show in the chat on their own line. BetterTTV's live connection
  adds the personal emotes of BTTV Pro users (once BTTV announces them, i.e.
  when they open the chat) and the emotes added to the channel during the
  stream. The emote picker is translated; long-press an emote there to open
  its card or copy its name. Its channel tab also lists the channel's own
  Twitch emotes (follower, then sub tiers; one public Twitch request per
  channel and session), so channels with only Twitch sub emotes get a tab too.
  Sub emotes your account doesn't have (from the chat's `emote-sets`) are
  greyed out with a lock: tapping one opens its card instead of adding it.
* 🔎 **Tap an emote or a badge** — a card with the image in large, its exact
  name and source (Twitch, BTTV, FFZ, 7TV, personal), copy it or add it to your
  message. BetterTTV, FFZ and 7TV emotes show their scope (global or channel),
  author, original name (7TV), whether they overlay the previous emote (7TV
  zero-width) or are modifiers, and a link to their page. Twitch emotes show
  their type (global, Tier 1/2/3 sub, channel points), the channel they belong
  to (live or not, with "See channel") and a preview of that channel's other
  sub emotes of the same tier — one public Twitch request, no account needed.
  A badge shows its title ("3-Month Subscriber"…) in high resolution. In the
  live chat, the multistream, the pinned message, a message thread and the
  VOD and clip chat; VoiceOver can open it too.
* 🙅 **Hide an emote** — long-press it in the chat, or **Hide this emote** on
  its card: it then shows as the typed word, from any source (Twitch, BTTV,
  FFZ, 7TV), in the live, VOD and multi-live chat. Settings → Chat → Hidden
  emotes lists them (up to 200) to show them again; the list follows your
  account, shared with the website (`hiddenEmotes`).
* 🏅 **Badges** — global and channel-specific, resolved through Helix.
* 🕘 **Recent messages** — Twitch sends nothing from before you join, so the
  last messages are fetched from `recent-messages.robotty.de` (third party) and
  marked with a clock.
* ⌨️ **Autocomplete** — emotes and names suggested as you type. The iOS
  keyboard’s predicted words and autocorrect are on (Settings → Chat →
  Keyboard suggestions, to turn off if iOS corrects your emotes). Swipe the
  chat down or tap it to hide the keyboard without sending; reducing the
  player hides it too.
* 🗑 **Deleted messages** — optionally kept struck through instead of vanishing.
* 🎨 **Username colour** — changed through Helix (needs a re-login after the
  permission was added).
* 👤 **Tap a message** — opens the person's card: avatar, name and badges, when
  the account was created and, when Twitch tells, since when they follow the
  channel; **Mention** (adds `@name` to your message), **Hide** (as in the chat
  settings) and **Channel** (opens their page); then their recent messages in
  this chat, with the reply thread below. Reply and copy too.
* 📌 **Pinned messages** — compact banner with badges, emotes, who pinned it and
  a countdown; collapse it to a chip. Shown in landscape too, along with polls,
  predictions and raids; there, **Hide** under them folds them all into one
  line of icons (with the poll or prediction countdown) — tap it to bring them
  back. The choice is remembered (Settings → Chat → Customization).
* 🎁 **Drops card** — when the channel runs a drops campaign, a card at the top
  of the chat shows the reward, the watch time it takes, the end date and a
  link to the details, like in the Twitch app; dismissed, it stays away for
  that campaign (Settings → Chat → Customization → Channel drops).
* 🎟 **Special Events** — Twitch's own reward campaigns (category Special
  Events, e.g. "1 Month of Apple TV") hide on their own, the channel's drops
  stay (Settings → General → Customize the app → Chat · banners).
* 📊 **Polls, predictions, hype train** — vote, bet channel points on a
  prediction, see the countdown, the results and the winning outcome. Each
  outcome shows, like the Twitch app, the points bet on it, its return ratio
  (1:1.7), how many people bet and the biggest bet; your bet shows what it
  would win. Once
  betting is closed, a prediction folds down to its title and your bet, and a
  finished poll to its winning choice; tap to see the bars. The hype train is
  shown from the moment it is incoming, like on Twitch: its checkmarks, how many
  more supports it needs and a countdown, then its departure, the time left on
  each level and a bar with the progress of the current level, and a short
  "level complete" / "Hype Train complete" message — no Twitch account needed
  (the time left also shows in the folded icon row). Each banner has a × that tucks it
  into a single chip above the chat (in portrait, landscape and multi-live) —
  tap the chip to bring them back; a new poll or prediction still shows up.
* 🚀 **Raids** — follow the streamer to the raided channel automatically;
  incoming raids shown with a link to the raider. Each of these can be switched off.
* 🔦 **Highlights & filters** — messages mentioning you or containing your words
  stand out; hide bots, `!commands`, muted words or someone in particular.
* 🤖 **Bot commands** — a channel's Nightbot, StreamElements, Fossabot and
  Moobot commands without typing `!commands`: from the chat's ⋯ menu, or from
  the channel page, live or offline (tap one to copy it).
* 🔥 **Watch streak** and a **follow / unfollow** button. Unfollowing, from the
  player or a channel page, asks for confirmation first; from the player, the
  same dialog can hide the button (Settings → Chat → Customization → Follow
  button above the chat).
* 🎁 **Channel points** — balance, rewards, and automatic bonus chest claiming.
  Raids are joined with your Twitch web session, like on twitch.tv, so the raid
  bonus is earned too (main player; the raid banner shows it).
  Settings → Channel points tracks, like drops, the time watched and the points
  earned by watching (passive points, streaks, chests; not prediction
  winnings): right now, in total and per channel, on this device.
* ⏱ **Chat synced with the video** (Settings → Chat, on by default) — live
  messages arrive almost instantly while the picture is seconds behind, so
  each one waits until the video catches up: your delay behind live as the
  other viewers see it (from the stream's timestamps, so it doesn't drift
  each time the playlist reloads), minus about 2 s for their reaction time,
  60 s at most. The delay follows the player on its own: it grows when the
  video stalls or falls behind, and shrinks when you jump back to live
  (**Live**, the seek bar, catching up) — waiting messages then come out in
  order over a few seconds instead of all at once. Your own messages, the
  app's notices and the banners (pinned, polls, predictions, raids) are never
  delayed, and moderation also applies to waiting messages. Main player's
  live only: not VODs (their chat already follows playback), rewinds through
  the recording, multi-live or chat only. A ⏱ −6 s badge above the chat (in
  portrait) shows the delay — tap it for real-time chat (or to sync again),
  long-press it to nudge it by ±1 s (also in Settings).
* 📼 **VOD chat** — replayed in sync with playback position.

### Drops

* 🎁 **Drops page** (Settings → Drops) — your campaigns in progress with their
  progress bars, every open campaign (all games) with its rewards, a **Claim**
  button and automatic claiming, a step-by-step guide, and a live status that
  tells you whether the stream you're watching counts.
* 📈 **Progress while you watch** — since October 2026, Twitch only counts drops
  when your own account loads the stream. During a live with drops, the app does
  that with small requests, without downloading the video a second time (not
  needed when the live already plays through your account, ad-free with your
  sub).
* 🔔 **Notifications** — told when a drop is ready to claim, or when the app
  has claimed it for you (Settings → Drops → Notify me). With the app open it's
  a banner inside the app, even if notifications aren't allowed.
* Needs the Twitch web session, like channel points. Game accounts must be
  linked: Twitch no longer grants rewards without it.

### Chat layout

* 📐 **Resizable** — drag the small handle between video and chat (no line
  across the picture); the width is remembered.
* 🪟 **Three landscape layouts** — a column on the right, translucent over the
  picture, or folded away. The player's buttons shift with the chat's width so
  nothing is ever covered.
* 🔠 **Sizing** — font size, message spacing, badge and emote scale,
  timestamps, with a live preview. The time shows in 12 h or 24 h: Auto
  follows the device, or pick one (Settings → Chat; the log follows it too).
* 🙈 **Hide the message box** (Settings → Chat → Show the message box, on by
  default) — for those who only read: the room goes to the messages, in
  portrait, landscape and multi-live; channel points and the chat's ⋯ menu
  stay as small buttons at the bottom right of the chat.
* 🔕 **Hide the chat's bell, chat mode and crown** (Settings → General →
  Customize the app → Chat · banners) — the notification bell stays on the
  channel page, and channel points move to the chat's ⋯ menu (also there in
  landscape, where the crown never shows).

### Finding things

* 🎞️ **Discover** — a tab with one live per screen to swipe up through, like
  Twitch's feed: top streams in your top language (hidden channels and
  categories left out), each playing a muted preview (360p, 160p on mobile
  data) through the usual live sources. The speaker button turns the sound
  on (it stays on from one page to the next until you leave the tab). **Clips**
  shows the most viewed clips of the last 24 hours from those channels, on a
  loop. Name, title, tags, category, viewers, **Follow**, share, and hide the
  channel or its category; tap the video for the full player (sound, chat), or
  the name or picture for the channel's page. Previews stop as soon as a player
  or multi-live opens, and come back when it closes. Settings → General →
  **Customize the app** hides it.
* 🏠 **Home** — your followed channels that are live (up to 300 at once), top
  streams (France or worldwide; without an account, **Load more** adds 30 at a
  time).
* ▶️ **Continue watching** — at the top of Home, the VODs you started (more
  than 30 s watched, not finished), latest first (up to 10), with their
  progress; a tap resumes where you stopped, as from My VODs. Hide it in
  Settings → General → Customize the app.
* ✋ **Continue watching menu** — long-press a video there: **Resume**, or
  **Remove from the list** (its resume point is forgotten; it stays in My VODs).
* 📜 **Long lists without an account** — a channel's VODs and clips, the
  categories and the live channels in a category keep loading past the first
  100 without logging in (the next pages are asked the way Twitch's Android
  app does). If Twitch ever refuses, your Twitch account takes over for
  categories, lives and clips, or a short note says so.
* 📍 **Pinned streamers** — long-press a followed channel (live or offline) →
  **Pin to the top of Following**: pinned ones come first, with a small pin.
  Their live streams are sorted by viewers among themselves (or in the order
  you pinned them: Settings → General → Customize → **Pinned sorted by
  viewers**).
* 🙈 **Hide channels and categories** — long-press a stream in Top or in a
  category → **Hide this channel** or **Hide the "…" category** (or
  long-press a category card). They leave Top, the category grid and category
  pages; Top tops itself up so it doesn't get shorter. What you follow or pin
  is never hidden, search still finds the channels and categories themselves
  (with **Hidden · Show again**) but leaves out their live streams and VODs,
  and Settings → General lists them to show them again. Kept on the
  device and in the backup file (same format as the website).
* 🎮 **Categories** — browse by game, then the live channels in it, filtered
  by language if you like (all, or a single one — kept for every category).
  Search puts the exact match first ("valorant" → VALORANT), with sharp box
  art. A category you follow on Twitch shows as followed on its page, and
  unfollowing it there removes it from your Twitch account (web session).
  Errors and empty lists have **Retry** / pull to refresh.
* 🗂️ **Followed categories your way** — Settings → General → Customize the app → Followed categories: **Compact** covers (3 per row on iPhone, more on a wider screen) and the order (most watched first, as before, or A → Z).
* 🏷 **Stream tags** — language, DropsEnabled… under each live stream, like on
  Twitch.
* 🔍 **Search** — type anything and the results come in tabs, like Twitch's
  results page: **Channels** (live ones first, with viewers or followers),
  **Categories**, **Live** (streams whose title, tags, category or name
  match) and **VODs** (with their channel), each tab with its count. Live
  streams and VODs from hidden channels or categories are left out (unless
  you follow them); channels and categories you searched for still show,
  marked hidden. A category opens its live channels, and **‹ Results for
  "…"** brings you back from a channel without searching again. A channel
  link (or `@name`), a VOD link or ID (a `?t=` link starts at that time) or
  a clip link still opens directly. The last 10 searches are kept on the
  device under the field, each removable, or **Clear** them all (also
  cleared with the history in Settings). On a channel, the VOD keyword
  filter can also look through older VODs (**Search older VODs**).
* 🗓 **Schedule** — a channel with a streaming schedule gets a **Schedule**
  tab: its next streams in your device's day and time, with length, title,
  category, **Every week** for recurring ones and **Canceled** ones struck
  through, plus its vacation if it announced one. When it's offline, its page
  says **Next stream: Tuesday · 8:00 PM** (or "On vacation until …") right
  under its name. Read with your Twitch account if you're signed in, or
  publicly without one; a channel without a schedule shows nothing more.
* ℹ️ **About** — a channel's description, followers, social links and panels.
* 🕒 **History** — recently watched VODs and channels, each removable.
* 🔄 **Cloud sync** — watch progress and history follow your Twitch account, so
  you pick up where you left off on another device. Every send reads the backup
  first and merges, so what the website or another device added is kept (and
  nothing is sent until a read has worked). What's on this device is never
  dropped because the backup lacks it — an old website tab or another device
  can send an outdated list — so a VOD watched here never vanishes because of
  them. A VOD or channel removed here while signed in, or a history cleared
  while signed in, is removed from the backup right away and this device
  won't bring it back; the website or another device that still has it can
  send it again, and a removal made there isn't followed here. Removing or
  clearing while signed out only changes what this device shows. A resume
  point moved back here (VOD restarted) stays put on this device once it's
  past the first 30 seconds. Each account keeps its own history: switching
  accounts never mixes them, the previous account's history and resume points
  are set aside on the device as they were when it signed out (unsent changes
  included) and come back when it signs in again (up to 5 accounts, more
  while one still has unsent changes), and what you watch while signed out
  goes to the next account that signs in.
* ⚙️ **Synced settings** — signed in, your settings follow your Twitch account
  on the website and your other devices (Settings → Twitch Account → **Sync my
  settings**, on by default): the chat settings shared with the website
  (timestamps, 12/24 h, deleted messages, bots, commands, hidden words and
  people, highlighted words), the top streams language, the VOD speed, pinned
  channels, hidden channels and categories, and the app's own customization
  (tabs, home, player buttons, chat banners, channel points chests, raids,
  ad-free with your sub, chat autocomplete and keyboard suggestions). Not
  synced, because they depend on the device: the app language, quality and
  mobile data, notifications and the Live Activity, downloads, the chat's
  sizes and landscape layout, fill screen, low latency, the chat synced with
  the video, the player type, the
  image cache and the home list layout. One document per account on the
  Worker (`/api/sync/prefs`), apart from the history backup — the 1.5.0 app
  and the Android app never touch it — in four parts, each with its own
  date: the latest change wins part by part, and pinned or hidden lists
  changed on both sides are merged (something removed on one side stays
  removed). Changes leave a few seconds after the last one, or when the app
  goes to the background; the account's settings are read at the history's
  pace (at most every 10 minutes). A device that never changed anything for
  the account first takes what the account has, adding its own lists
  (pinned, hidden, hidden chat words and people); one still on default
  values never sends them. Off, nothing is sent or applied on this device.
* 💾 **Backup & restore** — Settings → General → Backup: **Export** saves your
  channels (followed, pinned, hidden), followed categories, every setting
  (language, qualities, chat, player, appearance, notifications, downloads),
  the customization and Continue watching to a file — never your Twitch
  sign-ins, tokens or install ID. **Import** asks **Everything** or **Channels
  only**, adds without removing anything, then lists what it restored
  (unknown or invalid settings are skipped). Handy to move between the app
  and TU Test; older backups and the website's still import.
* ⬆️ **Update check** — the app tells you when a new version is out on the
  source, with a shortcut to Feather / SideStore / AltStore.
* 🔢 **Build number** — Settings → About shows the version and its build
  (“Version 1.6.0 (build 352)”); a tap copies them, for a bug report.
* 🩹 **Botched installs spotted** — when an install tool puts an old build under
  the latest version's number, the update alert explains it (old build N
  installed as X: delete the app and reinstall it from GitHub, after exporting
  a backup) and its button downloads the right IPA.
* 🔔 **Live notifications** — be told when a followed channel goes live
  (checked in the background, as often as iOS allows). For instant ones, even
  with the app closed, turn on **ntfy** (Settings → Features in testing): the
  app creates a secret topic, you add it in the free
  [ntfy](https://apps.apple.com/app/ntfy/id1625396347) app, and the backend
  posts there within a minute or two of a stream starting — tapping it opens
  the stream in TwitchUnblock. ntfy.sh counts free messages per address and
  turns away the backend's shared Cloudflare addresses, so they leave from the
  project's own server (the video relay); **Test** tells you when ntfy.sh is
  refusing messages for now (sending limit reached). **Notified channels**
  (same place) picks which followed channels notify you, for both. The app's
  own notifications show the stream's thumbnail, are grouped per channel, and
  have **Watch** and **Stop notifying for this channel** (press and hold). A
  **bell** on a channel's page and next to **Follow** above the chat turns that
  channel's notifications on or off (shown when live notifications are on and
  you follow the channel).

### Look & feel

* 🧩 **Customize the app** (Settings → General) — show, hide and reorder the
  tabs (and pick the one the app opens on), Home's live tabs and cards
  (Followed / Top / Offline, announcements, sign-in and web session cards,
  Continue watching, the Categories view), a channel page's tabs (VODs,
  Highlights, Playlists, Clips, Schedule, About — the page opens on the first
  one shown), the player's bottom bar buttons (mute, PiP, reload,
  chat layout, rotation, and optionally sleep timer, multi-live and rewind;
  AirPlay too) and the chat banners (pinned message, drops, polls,
  predictions, hype train, raids, watch streak, Follow button). Drag ≡ to
  reorder; **Restore the default layout** puts everything back. Kept in the
  backup file.
* 🎨 **Themes** — 7 accent colours and 3 backgrounds (dark, OLED black, slate),
  in Settings → General → Appearance.
* 📐 **Large screens** — on the iPhone Duo's inner display and on iPad, grids
  of lives, VODs, clips and categories show more, smaller tiles instead of two
  giant ones: the number of columns follows the available width (2 on any
  iPhone, 3 in portrait and 4 in landscape on the iPhone Duo's inner display,
  up to 5 on iPad), live through rotation, folding and Split View. Each grid
  keeps its proportions (16:9 previews, 3:4 box art).
* 🔠 **Text size** — the app follows iOS's text size (Display & Brightness →
  Text Size, or Accessibility → Larger Text), as soon as you change it, up to
  Accessibility 2: Home, Discover, search, channel pages, settings and chat
  messages (on top of the chat's own size). At the accessibility sizes, cards
  get twice as wide (one column on iPhone) and list rows put the details under the thumbnail; the
  player's controls over the video and the badges on thumbnails keep their size.
* 🖼️ **App icons** — six to pick from in Settings → General → Appearance
  (Classic, Purple, Night, Light, Contrast, Neon); the default one has dark
  and tinted versions, and “Contrast” stays the sharpest with iOS 26's clear
  and tinted icons. Drawn by `assets/icons/make_icons.py`; the alternate ones
  ship as separate PNG files (added by `buildipa.sh`), which is what works
  for apps installed with Feather. If the app was signed with a certificate's
  generic identifier (`TEAMID.*`, what Feather 2.9 and KSign 1.6 do with the
  generic profile of a purchased certificate), iOS refuses to change the icon:
  the app reads its own signature and says so. Feather's next version adds a
  **Merge Entitlements** option that fixes the signature.
  When the installing tool doesn't allow it (LiveContainer, GBox…), iOS's refusal is remembered and the picker gives way to a line saying why (it comes back with another version or signature).
* 🫧 **Liquid Glass** — optional on iOS 26: a floating tab bar and glass buttons
  over the picture.
* ⬆️ **Back to the top** — tap the tab you're already on to scroll Home (any
  live tab), Search or My VODs back to the top, or Discover back to its first
  page.
* 👈 **Swipe back** — swipe from the left edge to go back, as in iOS apps: in Settings (the page follows your finger), from a category's live channels and from a channel opened from search results.

### The rest

* 🧰 **Your own Worker** — Settings → Other → Expert settings: if the official
  Workers go down (or the project disappears), give the address of your own
  (deployed from the [website's repository](https://github.com/MXFia19/TwitchUnblock-Web),
  on Cloudflare or with Docker). It's checked, then tried first for lives,
  VODs and playlists; a failed check says why (no answer, quota reached, not a
  TwitchUnblock Worker). iOS only allows `http://` on your local network: a
  Docker Worker on a server needs HTTPS in front of it (Caddy, Cloudflare
  Tunnel). **Send everything through this Worker** also moves
  history backups, feedback, announcements and polls, ntfy notifications and the usage
  count there (your Twitch token is then sent to it — only for a Worker you
  host yourself).
* 🔒 **Chat restrictions said upfront** — above the message box, the room's
  modes (followers only and for how long, subscribers only, emotes only, slow
  mode, verified account…); the channel's chat rules to accept before your
  first message, like on Twitch; and when Twitch refuses a message, it's
  removed and the reason shown in your language instead of looking sent;
  banned from the chat, it switches to read-only (see above).
* 🌍 **Seven languages** — English (default), French, Spanish, Russian,
  Italian, Japanese and Traditional Chinese (Taiwan), on the iPhone and the
  Apple TV. The Russian translation was made with AI; the Italian one was
  contributed by Domenico-lel, the Japanese one by kinboy56 and the
  Traditional Chinese one by trend0522 (both made with AI), newer texts
  translated with AI. For these four, the iPhone app says so next to the
  language picker, with a button to report a mistake.
  On the iPhone, Settings → General → **App language** opens the list on its own page, like iOS's settings.
* 🐞 **Bug reports & ideas** — a form in the header, in Settings and in the
  player menu, screenshots included. **My reports** shows where each one stands
  (received, seen, accepted, in progress, done, declined) and the developer's reply,
  and lets you answer back; a badge flags new replies, and open conversations
  refresh on their own. A reply (or a new status) also shows up as a banner
  inside the app — notifications allowed or not; replies are checked every
  minute while the app is open — and as a notification while the app is in the
  background (without permission, the banner waits until you come back); tap it
  to open **My reports**. A report that's done or declined, with the developer
  having the last word, is no longer checked (opening it still looks once);
  answering it brings it back.
* 👥 **Switch account** — sign in with another Twitch account from Settings.
  After logging out, the next sign-in asks which account to use instead of
  quietly reusing the previous one.
* 🔐 **Web session check** — the Twitch web session has no known expiry date;
  it's verified at launch and at sign-in, and you're told when it needs
  restoring instead of channel points silently going quiet (restoring asks
  you to sign in again rather than reusing the dead session). It must also be
  the app's account: another account is refused at sign-in (and disconnected
  if found later), so points, drops and predictions never go to the wrong
  account — when the session changes, drop progress stops or carries on with
  the new one, and a live playing through your account (ad-free with your sub)
  reloads with the new session or without one.
* 📊 **Usage count** — logged in, your Twitch account (counted once across the
  app and the website); logged out, a random install ID. Plus the app version,
  the app language, iPhone or iPad, the iOS version and how many lives and
  VODs were started (which source served a live, failures — counters only),
  at most once an hour. No channels watched, no IP address. Switching it off
  erases it server-side. Public numbers: [/stats](https://twitchunblock.vercel.app/stats). See
  [`Sources/Services/UsageService.swift`](Sources/Services/UsageService.swift).
* 🪵 **System logs** — everything the app does, visible in Settings, in the
  app's language (written in French, translated when shown: numbers and names
  stay as they are). Share them as text or export them as a `.txt` file
  (Files, AirDrop, Mail…).
  Categories (PLAYER, NETWORK…), settings changes and details built on the fly are translated too; only iOS's own error messages stay in iOS's language.

---

## 📺 Apple TV (test)

A first Apple TV app lives in `TV/` (target `TwitchUnblockTV`, tvOS 16+),
built on its own by `.github/workflows/build-tvos.yml` and published as an
unsigned `tv-test-N` pre-release:

* Followed channels (sign in with a code or a QR code on twitch.tv/activate):
  the live ones, then the offline ones (most recently live first) to open
  their videos; top streams, categories, search, a channel's VODs. The
  Following list refreshes on its own (back on the tab or in the app, every
  2 minutes while it's shown, and when you come back down from the tab bar),
  so ended lives don't linger.
* **Continue watching** in Following (at the top by default), with or
  without an account: the VODs started on this Apple TV (more than 30 s, not
  finished), last watched first (up to 10), with their progress; Select or
  Play resumes where you stopped.
* Account → Settings → **“Continue watching” row**: above the live channels,
  below them, or hidden; when the row is shown, a **Live** title heads the
  live channels, which looked like part of it.
* Press and hold the center button on a Continue watching video: **Resume**,
  or **Remove from list** (its progress on this Apple TV is forgotten).
* The remote's **Play** button starts the focused live or VOD, like Select; on
  an offline channel (Following, Search) it opens the channel and plays its
  latest broadcast (or its live, if it just started).
* tvOS's native player, with Quality, **Chat** and, for lives, Source in its
  bar: the chat (read-only, no account needed) sits on the picture — live, or
  a VOD's chat replayed in sync — with Twitch, BTTV, FFZ and 7TV emotes. The
  Chat menu shows or hides it and places it on the left or the right, full
  height or in the top or bottom half (any of the four corners); shown or
  hidden and its place are remembered for the channel being watched (a
  streamer who already shows their chat on screen doesn’t need ours), and
  Account sets the defaults.
* **View channel** in the player's bar opens the channel's page, with its
  videos, clips and collections; a video started there plays on top of it,
  and Menu goes back.
* A channel's page has **Videos, Clips and Collections** tabs, like the
  iPhone: the most viewed clips over 24 h, 7 days, 30 days or all time, and
  each collection's videos on a row. A clip plays in the TV player, with its
  broadcast's chat replayed at that moment. The tabs always take the focus,
  so Menu goes back to the list even on an offline channel without videos
  (the focus used to stay on the tab bar, and Menu quit the app).
* During a channel's ad break on a live, the same banner as on the iPhone
  says what the purple screen is, with a countdown to the stream's return.
* Usage count, like the iPhone (Account → Share my usage): a random install ID,
  or your Twitch account when signed in, the version, the language and how many
  lives and VODs started (which source, failures), at most once an hour; never
  the channels. It waits until the backend counts the Apple TV on its own.
* Account's settings move one row at a time with the remote, land on the
  ticked option, and always lead back up to the tab bar.
* Account → **About** shows the app's version and build number (“Version
  0.1.N (build N)”), to check an update or report a problem.
* A preferred quality (Account → Settings), same rule as the iPhone: the
  closest one below when the channel doesn't have it; picking a quality in the
  player's bar replaces it.
* Hide a channel or a category from Top and Categories: press and hold the
  center button on a card; Account lists them to show them again (kept on
  this Apple TV).
* Cards that grow when focused stay above their neighbours; the app has its
  own layered icon and Top Shelf banners (`TV/make_tv_icons.py`, drawn from
  the iPhone app's logo).

Installing it needs a tool that can sideload on tvOS, or a Mac with Xcode and
the Apple TV paired with it (AltStore, SideStore and Feather don't handle
tvOS). **ATVLoadly** (or any tool that reads AltStore sources) can update it
on its own from a source rewritten by each build with its release notes
(`Changelog: Apple TV: …` lines of the commits that touch the TV). Test
builds, from the test branch:

```
https://raw.githubusercontent.com/MXFia19/TwitchUnblock/test-17d298/apps-tv.json
```

Releases built with the iPhone app (`master`, `tv-N`), from the next release
on:

```
https://raw.githubusercontent.com/MXFia19/TwitchUnblock/master/apps-tv-stable.json
```

Its GitHub releases can't be used for that: they also hold the iPhone IPAs.

---

## 🌐 Web version

**No install? Use it in your browser: https://twitchunblock.vercel.app**

No sideloading? Add the website to your Home Screen: it opens like an app
and gets live notifications (iOS 16.4+).

The website has its own repository, [TwitchUnblock-Web](https://github.com/MXFia19/TwitchUnblock-Web),
and shares this app's backend (the Cloudflare Worker, which now lives there too).

What you get on the web:

* Top streams without logging in, followed channels once logged in
* Ad-free lives from the source you pick (settings, or the player's ⚙ menu),
  a few seconds behind live
* Live and VOD player with quality picker, speed, ±10 s, picture in picture, mini player
* Native chat: Twitch, BTTV, FFZ and 7TV emotes, badges, chat history, pinned message, replies
* VOD chat replayed in sync with the video
* Stream tags, clips, categories, Twitch-style links (`/xqc`, `/videos/…`)
* Resume VODs where you left off, history synced with your Twitch account
* English, French, Spanish and Russian

Channel points, drops and betting on predictions are **not** in the web version
and cannot be: they need the `twitch.tv` session cookie, which no third-party
site can read. For those, use the app.

---

## 🛠️ Building from source

**Requirements:** macOS, Xcode 16+, iOS 16.0 deployment target, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
The CI builds the iPhone app with Xcode 27.1 (iOS 27.1 SDK): an app linked
against an older SDK stays in a phone-sized black frame on the iPhone Duo's
inner display. Build with Xcode 27.1 or later to get the same result.

```bash
git clone https://github.com/MXFia19/TwitchUnblock.git
cd TwitchUnblock
xcodegen generate
open TwitchUnblock.xcodeproj
```

The Xcode project isn't in the repository: it is generated from
[`project.yml`](project.yml) (run `xcodegen generate` again after adding files).
Signing is turned off in `project.yml` because CI builds unsigned IPAs: to run
the app on your device, pick your development team under *Signing &
Capabilities* (and a bundle identifier of your own). The app icons are
assembled by CI (step “Create App Icon Folder” in
[`build.yml`](.github/workflows/build.yml)): a local build has none unless you
run that step. GitHub Actions builds and publishes nightly IPAs from `master`.

### Versioning

Versions look like `1.1.4`. The first two numbers come from the
[`VERSION`](VERSION) file; the last one counts the builds since that file last
changed, and starts again at 0 when you bump it (edit `VERSION` to `1.2` for a
new series). The internal build number (`CFBundleVersion`) is the CI run number:
it only ever goes up, and it is what the app compares to detect an update.

### Backend

Playlist resolution, cloud sync and the usage count go through a Cloudflare
Worker that this project hosts. Nothing to do if you are just building the app —
it points at the shared instance out of the box.

If you **fork** the project and want your own backend, the Worker code and
deployment notes are in [`worker/`](worker/); change `kAPIURL` in
[`Sources/Constants.swift`](Sources/Constants.swift) to point at it.

---

## 🙌 Contributors

Thanks to the people who improved the app (also credited in the app, under
Settings → About):

* [Domenico-lel](https://github.com/Domenico-lel) — Italian translation
* [kinboy56](https://github.com/kinboy56) — Japanese translation
* [trend0522](https://github.com/trend0522) — Traditional Chinese translation
* [dwojc6](https://github.com/dwojc6) — more responsive swipe-down on the player

All contributors on GitHub:
https://github.com/MXFia19/TwitchUnblock/graphs/contributors

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
