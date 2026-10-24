<p align="center">
  <img src="assets/brand/icon-256.png" alt="waveform app icon: five bars, three orange, two grey" width="128" />
</p>

<h1 align="center">waveform</h1>

<p align="center">a keyboard-first soundcloud client for desktop<br/>flutter, macos / windows / linux</p>

<p align="center">
  <a href="https://github.com/mollykitten/waveform/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/mollykitten/waveform/actions/workflows/ci.yml/badge.svg?branch=main" /></a>
  <img alt="Flutter" src="https://img.shields.io/badge/Flutter-3.41-02569B?logo=flutter&logoColor=white" />
  <img alt="Platforms" src="https://img.shields.io/badge/Platform-macOS%20%7C%20Windows%20%7C%20Linux-lightgrey" />
  <img alt="Version" src="https://img.shields.io/badge/version-0.3.0-FF5500" />
  <a href="https://t.me/waveformsc"><img alt="Telegram" src="https://img.shields.io/badge/Telegram-waveform-26A5E4?logo=telegram&logoColor=white" /></a>
</p>

<p align="center">
  <img src="screenshots/track-page.png" alt="waveform track page with ambient cover backdrop, waveform and timecoded comments" width="100%" />
</p>

web soundcloud is fine, tabs are not

desktop clients for it either don't exist or they're electron wrapped around the website. so i made a real native one, closer to canonical soundcloud than other unofficial clients but darker and quieter, and you can run it for hours without touching the trackpad

> **v0.3.0:** likes and reposts finally stick
>
> soundcloud's datadome anti-bot was 403-ing every write because a plain http client doesn't look like a browser. writes now go through the app's own invisible webview with a real browser fingerprint lol
>
> also full soundcloud-web keyboard parity (press `H` in the app) and crossfade fixes, no more silent or non-overlapping transitions. daily-driver loop works on macos, windows and linux build too but i test them less. the api is unofficial so rough edges stay. everything else in [`CHANGELOG.md`](CHANGELOG.md)

## what you get

- **keyboard first.** space plays, ⌘K finds anything, arrows seek, ⇧ + arrows skip. enter on a track page plays it
- **gapless + crossfade 0-6 s.** two audio engines: the next track preloads on the idle `AudioPlayer` and swaps in on the last sample. crossfade is optional
- **media keys.** control center on macos, SMTC on windows, MPRIS on linux, via `audio_service`. pause from your headphones, now-playing on the lock screen
- **your account.** you sign in on soundcloud's own page in a webview, the app never sees your password, only the session token, saved in the app's sandboxed support dir
- **last.fm.** off until you connect it. now-playing after 3 s, scrobble at 50 % played or 4 min
- **local stats.** top artists, genres and hours from your last 400 plays (`/me/play-history`), counted on your machine

## keyboard flow

the whole app is one big `Shortcuts` + `Actions` graph. the loop i use every day:

```
⌘K        open the palette
type      live soundcloud results, debounced 250 ms
↑ / ↓     move through results
↵         open the track / playlist / artist
↵         on a track page: play it, related tracks become the queue
space     pause / resume
→ / ←     seek 5 s
⇧ → / ←   next / previous track
⇧ ↑ / ↓   volume
esc       close the palette
```

<p align="center">
  <img src="screenshots/omnibox.png" alt="⌘K palette over the blurred app with live soundcloud results" width="100%" />
</p>

### all shortcuts

| key | does |
|---|---|
| `space` | play / pause |
| `→` `←` | seek 5 s |
| `⇧` `→` `←` | next / previous track |
| `⇧` `↑` `↓` | volume |
| `M` | mute |
| `L` | like what's playing |
| `⇧` `L` | repeat |
| `R` | repost what's playing |
| `⇧` `S` | shuffle |
| `0` … `9` | jump to 0-90 % |
| `P` | go to the playing track |
| `S` | search |
| `Q` | queue |
| `H` | shortcut cheat sheet |
| `G` then `L` `S` `C` `P` `H` | likes / feed / library / profile / history |
| `⌘K` or `⌘F` | palette |
| `⌘L` | library / likes |
| `⌘,` | settings |
| `⌘` `⇧` `L` | logs |
| `⌘` `⇧` `C` | copy link to the current page or track |
| `↵` on `/track/:id` | play this page's track |

⌘ on macos, ctrl on windows and linux. single-key shortcuts go quiet while a text field or the palette has focus

in the palette you can also type action words: `settings`, `logs`, `likes`, `shuffle`, `sign out`, `clear cache`. they show up as rows, enter fires them

every track row has a right-click menu too: play, add to queue, like, repost, copy link, open on soundcloud, open artist, open track page

## how i use it

**find and play.** `⌘K`, type, `↓`, `↵` to open, `↵` again to play

**play a whole playlist.** open it from the home shelves or search, hit the orange play, or **shuffle all**. shuffle all pulls the full set first and then shuffles, so it's the whole playlist and not just the loaded page

<p align="center">
  <img src="screenshots/playlist.png" alt="playlist page with ambient backdrop, track list and shuffle all" width="100%" />
</p>

**fix what's coming up.** queue icon in the top bar opens the panel on the right, current track on top. drag rows to reorder, `×` to remove

<p align="center">
  <img src="screenshots/queue.png" alt="queue panel on the right with the current track and a drag-reorderable list" width="100%" />
</p>

**dig around.** any `/track/:id` page has related tracks at the bottom, enter on one starts a new queue from it. the track page follows playback, so when the next track starts the page moves with it

**more screen.** `▽` on the right of the bottom player folds it into a 44 px bar with cover, ticker, play and next. `△` brings it back

**check your listening.** `⌘K`, `stats`, enter. or just `/stats`: top 10 artists, top genres, totals in big mono numbers

<p align="center">
  <img src="screenshots/stats.png" alt="stats screen with mono totals, top artists and genre pills" width="100%" />
</p>

**scrobble.** settings → last.fm → connect → auth in the browser → continue. done

## install

builds are attached to every github release. test builds and news go to telegram first: **[t.me/waveformsc](https://t.me/waveformsc)**

**macos.** needs macos 12 monterey or later starting after v0.3.0
1. grab `waveform-macos-vX.Y.Z.dmg` from the [latest release](https://github.com/mollykitten/waveform/releases/latest)
2. drag waveform into applications
3. open it. it's signed with developer id and notarized, gatekeeper won't ask

**windows.**
1. grab `waveform-windows-vX.Y.Z.zip` and unzip
2. run `Waveform.exe`. smartscreen says "unknown publisher" the first time (no ev cert yet), click more info → run anyway

**linux.**
1. grab `waveform-linux-vX.Y.Z.tar.gz`
2. `tar xzf` and run `./waveform_app`

first launch: sign in via settings → account, go back home, your stream, likes and playlists show up

## what works today

- **live soundcloud data** from the internal `api-v2`, no mocks in the shipping app
- **per-user login** through soundcloud's real sign-in page in an embedded webview. token goes to `getApplicationSupportDirectory()`
- **real hls playback** via [`just_audio`] (avplayer on macos). engine ops are serialized so volume, progress and play/pause never desync mid-transition. progressive fallback when hls fails. encrypted hls (`cbc-/ctr-encrypted-hls`, the go+ tracks) gets detected and skipped with a notice
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
- **logs screen** at `/logs`, powered by [Talker]

<p align="center">
  <img src="screenshots/library.png" alt="library likes in list view with listens, likes and duration columns" width="100%" />
</p>

## design

dark by default, light theme later. 3 px radii, 0.5 px borders, orange only on what's active

| token | value | for |
|---|---|---|
| `bg` / `surface` / `surface2` | `#0A0A0A` / `#111111` / `#1A1A1A` | backgrounds |
| `textHi` / `textMid` / `textLow` | `#F5F5F5` / `#888888` / `#555555` | text |
| `acid` | `#FF5500` | active stuff only |
| `lime` | `#C6FF00` | web3 markers, visual only for now |

inter for text, jetbrains mono for every number, timecode and technical label

the logo is five bars, the same shape as `lib/shared/widgets/wave_logo.dart`. in the app icon the first three are orange and the last two grey, like a track you're halfway through. svg logos live in [`assets/brand/`](assets/brand/). the icon, favicons and the share card all come out of one script, so change the mark there and rerun it:

```bash
python3 tool/brand/make_icons.py
dart run flutter_launcher_icons
```

the landing page is plain static html in [`site/`](site/), no build step. any static host works, point it at `site/`

## stack

flutter + dart 3.11. `flutter_riverpod` for state, `go_router` for navigation, `just_audio` for playback, `audio_service` for os media controls, `dio` for http, `path_provider` for token and cache paths, `cached_network_image`, `google_fonts`, `talker_flutter` for logs, `window_manager` for the title and traffic lights

```
lib/
├── app/        # theme, router, shell, global shortcuts
├── core/
│   ├── api/    # soundcloud api-v2 client, dtos, mappers, auth, liked tracks
│   ├── audio/  # two-engine just_audio wrapper behind an interface
│   ├── cache/  # image cache (json, no sqflite on desktop)
│   ├── lastfm/ # auth + scrobbler
│   ├── log/    # talker
│   └── storage/# file-based token + prefs
├── features/   # auth, home, feed, library, search, track, artist, playlist, player, queue, stats, settings, omnibox, debug
└── shared/     # models, widgets, intents, formatting
```

every number goes through `AppTheme.mono()`

## run it yourself

you need a recent [flutter](https://docs.flutter.dev/get-started/install) sdk with desktop enabled

```bash
flutter pub get
flutter run -d macos      # or -d windows / -d linux
```

offline with mock data, no login:

```bash
flutter run -d macos --dart-define=MOCK=true
```

tests and analysis:

```bash
flutter test
flutter analyze
```

## data and auth

- waveform talks to soundcloud's **undocumented `api-v2`**. the `client_id` gets scraped from soundcloud.com at runtime, nothing is shipped or hardcoded
- your personal stuff needs your own soundcloud login through the webview. the oauth token sits in a file in the app's sandboxed support dir, anonymous requests never carry it
- personal collections use `/users/{id}/…` because the `/me/…` versions 404 in api-v2

## known limitations

- **drm tracks don't play.** soundcloud serves more and more encrypted hls, the desktop audio engine can't decode it. those tracks get a `🔒 GO+` badge and get skipped. playing them would need widevine / eme, which `just_audio` doesn't have on desktop
- **macos first.** windows and linux build but i run them less
- **likes and reposts are best effort.** the api-v2 write endpoints aren't a stable contract. if one gets blocked (vpn, captcha) you'll see it in the ui but it may not recover
- **no play-history writes or comment likes.** i checked with curl: the write endpoints 404 and there's no per-user like flag on tracks or comments. the home history rail shows plays from official soundcloud clients
- **links work through clipboard and paste, not the os.** owning `https://soundcloud.com` would need universal links on soundcloud's own servers or hijacking all of `https`, so no. `waveform://` is registered on macos, windows and linux need it at the installer level
- **windows sign-in lags.** the webview2 sign-in page is heavy. the reliable way on windows is pasting your `oauth_token`, the login dialog walks you through it
- **no official oauth 2.1 + pkce.** soundcloud's app registration has been closed for years, the webview token flow stands in for it
- **no light theme yet, no real walletconnect yet.** web3 bits are visual only

## roadmap

- light theme that follows the system
- drag tracks between playlists
- lyrics on the track page
- reduced motion + a full voiceover pass
- stats: hour-of-week heatmap from `played_at`
- always-on-top mini player, 300×120
- official oauth 2.1 + pkce if soundcloud ever reopens registration
- real walletconnect v2
- windows ev code signing so smartscreen stops asking

## cutting a release

ci and the release pipeline are wired up, the tag is the only manual part

### one-time setup

1. **apple developer program** ($99/yr). you need the `Developer ID Application` cert in your keychain, export it as `.p12` with a password
2. **github actions secrets** in settings → secrets and variables → actions:
   - `APPLE_TEAM_ID`: the 10-char team id from [apple developer → membership](https://developer.apple.com/account#MembershipDetailsCard)
   - `APPLE_CERT_P12_BASE64`: `base64 -i cert.p12 | pbcopy`
   - `APPLE_CERT_PASSWORD`: the `.p12` password
   - `APPLE_ID`: your apple id email
   - `APPLE_APP_PASSWORD`: an app-specific password from [appleid.apple.com](https://appleid.apple.com), name it `Waveform notarytool`
   - `KEYCHAIN_PASSWORD`: any random string, only used inside the ci runner
3. **last.fm** (optional, only if you want scrobbling in the shipped build): register on [last.fm/api/account/create](https://www.last.fm/api/account/create) and add `LASTFM_API_KEY` and `LASTFM_SHARED_SECRET` as two more secrets. the release workflow passes them through `--dart-define`, so they land in the binary and never in the public source. last.fm asks to keep `shared_secret` private, don't paste it into `lib/core/lastfm/lastfm_constants.dart`. locally: `flutter run --dart-define=LASTFM_API_KEY=… --dart-define=LASTFM_SHARED_SECRET=…`

### cutting v0.X.Y

```bash
# 1. bump version in pubspec.yaml and _kAppVersion in lib/features/settings/settings_screen.dart
# 2. update CHANGELOG.md
# 3. commit + push
git tag v0.X.Y
git push --tags
```

github actions runs `release.yml`: macos, windows and linux build in parallel, the macos `.app` gets signed and notarized, everything lands in a release at `https://github.com/mollykitten/waveform/releases`. notes come from `.github/release_template.md`

if the macos job dies at codesign or notarytool, `gh run view --log-failed <id>` and check the secrets are there and the `.p12` exports on a clean machine

## disclaimer

this is an **unofficial** client, **not affiliated with, endorsed by or connected to soundcloud**. it uses an undocumented internal api, and using that api may be against soundcloud's terms of service. it's for educational and personal use: use your own account, at your own risk. soundcloud, the soundcloud logo and related marks are trademarks of their owners

## license

[MIT](LICENSE)

the vendored [`third_party/desktop_webview_window`](third_party/desktop_webview_window) keeps its own [apache-2.0 license](third_party/desktop_webview_window/LICENSE). the license covers this code only and gives no rights to soundcloud's api, content or trademarks

[`just_audio`]: https://pub.dev/packages/just_audio
[Talker]: https://pub.dev/packages/talker_flutter
