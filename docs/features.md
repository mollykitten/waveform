# features

## the headline ones

- **keyboard first.** space plays, ⌘K finds anything, arrows seek, ⇧ + arrows skip. enter on a track page plays it. see [keyboard](keyboard.md)
- **gapless + crossfade 0-6 s.** two audio engines: the next track preloads on the idle `AudioPlayer` and swaps in on the last sample. crossfade is optional
- **media keys.** control center on macos via `audio_service`. pause from your headphones, now-playing on the lock screen. windows (smtc) and linux (mpris) aren't wired yet
- **your account.** you sign in on soundcloud's own page in a webview, the app never sees your password, only the session token, saved in the app's sandboxed support dir
- **last.fm.** off until you connect it. now-playing after 3 s, scrobble at 50 % played or 4 min
- **local stats.** top artists, genres and hours from your last 400 plays (`/me/play-history`), counted on your machine

## what works today

- **live soundcloud data** from the internal `api-v2`, no mocks in the shipping app
- **per-user login** through soundcloud's real sign-in page in an embedded webview. token goes to `getApplicationSupportDirectory()`
- **real hls playback** via [`just_audio`](https://pub.dev/packages/just_audio) (avplayer on macos). engine ops are serialized so volume, progress and play/pause never desync mid-transition. progressive fallback when hls fails. encrypted hls (`cbc-/ctr-encrypted-hls`, the go+ tracks) plays on macos through the `scdrm` decryption core if you supply your own widevine device profile, otherwise it's skipped with a notice
- **true shuffle with history**, previous goes back to what actually played, no repeats inside a cycle
- **perceptual volume** (cubic taper), so the slider isn't all in the bottom 5 %
- **real waveforms everywhere**: lists, player, feed and track page show the same soundcloud waveform, cached, with a procedural shape while it loads
- **screens:** home, feed, library (likes / playlists / albums / stations / following / history), search, track, artist, playlist, settings, stats
- **liked / reposted state** synced across rows, player and track page, optimistic +1 with revert if the api says no
- **soundcloud links open in the app**: copy a `soundcloud.com/…` link and a toast offers to open it, or paste it into ⌘K. `waveform://` is registered on macos
- **queue panel** with drag-reorder, virtualized likes list (fine with hundreds of tracks)
- **tiles / list** toggle in library and search, remembered
- **ambient cover backdrop**, hero transitions on covers, skeleton loaders
- **window title** follows the track: `Waveform · {artist} - {title}`
- **logs screen** at `/logs`, powered by [Talker](https://pub.dev/packages/talker_flutter)

![library likes in list view with listens, likes and duration columns](../screenshots/library.png)

what doesn't work: [limitations](limitations.md)
