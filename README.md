<p align="center">
  <img src="screenshots/track-page.png" alt="Waveform — track page with ambient cover backdrop, waveform, and timecoded comments" width="100%" />
</p>

<p align="center">
  <a href="https://github.com/mollybyte/waveform/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/mollybyte/waveform/actions/workflows/ci.yml/badge.svg?branch=main" /></a>
  <img alt="Flutter" src="https://img.shields.io/badge/Flutter-3.41-02569B?logo=flutter&logoColor=white" />
  <img alt="Dart" src="https://img.shields.io/badge/Dart-3.11-0175C2?logo=dart&logoColor=white" />
  <img alt="Riverpod" src="https://img.shields.io/badge/Riverpod-3.3-2c3e50" />
  <img alt="Platforms" src="https://img.shields.io/badge/Platform-macOS%20%7C%20Windows%20%7C%20Linux-lightgrey" />
  <img alt="Version" src="https://img.shields.io/badge/version-0.3.0-FF5500" />
  <a href="https://t.me/waveformsc"><img alt="Telegram" src="https://img.shields.io/badge/Telegram-waveform-26A5E4?logo=telegram&logoColor=white" /></a>
</p>

# Waveform

**A keyboard-first, minimalist SoundCloud client for desktop.** Built with Flutter for macOS, Windows, and Linux.

Closer to canonical SoundCloud than any other unofficial client — but darker, quieter, and built so you almost never have to touch the mouse.

> **v0.3.0 — account actions that stick.** Likes and reposts now actually save: SoundCloud's DataDome anti-bot was 403-ing write requests because a plain HTTP client doesn't look like a browser, so they now run inside the app's own invisible WebView with a real browser fingerprint. Plus full SoundCloud-web keyboard parity (press `H` for the full cheat sheet) and crossfade fixes — no more silent or non-overlapping transitions. Daily-driver loop works end-to-end on macOS (Windows/Linux build too, less exercised). APIs are unofficial; rough edges remain. Full change log in [`CHANGELOG.md`](CHANGELOG.md).

---

## Why Waveform

The web SoundCloud is fine. Tabs are not. Native clients for it either don't exist on desktop, or they're Electron wrappers around the web. Waveform is a **real native desktop app**:

- **Keyboard-first.** Space plays. ⌘K finds anything. Arrows seek, ⇧+arrows skip tracks. Enter on a track page plays it. You can run the app for hours without touching the trackpad.
- **Gapless + crossfade (0–6s).** Two-engine architecture — preloads the next track on an inactive `AudioPlayer` and instant-swaps on completion. No silence between tracks. Optional crossfade for DJ-style transitions.
- **OS-native integration.** Real media keys via `audio_service` — Control Center on macOS, SystemMediaTransportControls on Windows, MPRIS on Linux. Pause from your bluetooth headphones, see now-playing on your lock screen.
- **Your account, your data.** Real SoundCloud login via WebView (your password is never seen by the app — only the session token, stored in the app's sandboxed support directory). Your stream, your likes, your playlists, your play history.
- **Last.fm scrobbling.** Optional, off until you configure it. Now-playing pings after 3s, scrobbles at ≥50% played or ≥4 min, persisted across launches.
- **Local listening stats.** Aggregated from `/me/play-history` (up to 400 plays): top artists, top genres, total hours, unique tracks. All client-side — nothing leaves the app.

---

## The killer feature: keyboard flow

The whole app is one giant `Shortcuts` + `Actions` graph. Here's the canonical flow:

```
⌘K        →  open command palette (centered, blurred backdrop)
type      →  live SoundCloud results (debounced 250 ms)
↑ / ↓     →  navigate results
↵         →  open the selected track / playlist / artist
↵         →  (on the /track page) play it, queue = related tracks
Space     →  pause / resume
→ / ←     →  seek ± 5 s
⇧ → / ←   →  next / previous track
⇧ ↑ / ↓   →  volume up / down
Esc       →  close the palette
```

That's the full loop. Find anything, open it, play it, transport-control it — without your hand leaving the home row.

<p align="center">
  <img src="screenshots/omnibox.png" alt="⌘K command palette: centered modal over blurred app, live SoundCloud results with covers and avatars" width="100%" />
</p>

### Global shortcuts

| Key | Action |
|---|---|
| **Space** | Play / pause |
| **→ / ←** | Seek ± 5 s |
| **⇧ + → / ←** | Next / previous track |
| **⇧ + ↑ / ↓** | Volume up / down |
| **M** | Mute |
| **L** | Like playing track |
| **⇧ + L** | Repeat |
| **R** | Repost playing track |
| **⇧ + S** | Shuffle |
| **0 … 9** | Seek to position (0–90 %) |
| **P** | Go to playing track |
| **S** | Search |
| **Q** | Show queue |
| **H** | Keyboard-shortcut help overlay |
| **G** then **L / S / C / P / H** | Go to likes / feed / library / profile / history |
| **⌘K** or **⌘F** | Open command palette |
| **⌘L** | Jump to library / likes |
| **⌘,** | Open settings |
| **⌘ + Shift + L** | Open logs |
| **⌘ + Shift + C** | Copy current page / track link |
| **↵** *(on `/track/:id`)* | Play / resume this page's track |

*macOS: ⌘ — Windows/Linux: Ctrl. Single-key shortcuts are suppressed while a text field or the ⌘K palette is focused.*

### Inside the palette

| Key | Action |
|---|---|
| **type anything** | Live search (tracks / playlists / artists) |
| **↑ / ↓** | Navigate results |
| **↵** | Activate the selected row |
| **Esc** | Close |

The palette also recognises a few **action words** — type `settings`, `logs`, `likes`, `shuffle`, `sign out`, `clear cache` and they appear as actionable rows you can fire with Enter.

### Right-click everywhere

Every track row has a context menu: **play / add to queue / like / repost / copy link / open on SoundCloud / open artist / open track page**.

---

## How to use it

A few common flows once you've launched the app:

**Find and play a track.** `⌘K` → type → `↓` to pick → `↵` to open → `↵` again to play.

**Build a queue from a playlist.** Open the playlist (from the home shelves or from search). Hit the orange **play** for sequential or **shuffle all** to drain the whole playlist (paginates the full set first, then shuffles — true full-collection shuffle, not just the loaded page).

<p align="center">
  <img src="screenshots/playlist.png" alt="Playlist page with ambient backdrop, track list, and shuffle-all" width="100%" />
</p>

**Reorder what's coming up.** Click the queue icon in the top bar → floating queue panel slides in from the right with current track at top and upcoming below. Drag the rows to reorder. Click `×` to remove.

<p align="center">
  <img src="screenshots/queue.png" alt="Queue panel slid in from the right with current track header and drag-reorderable upcoming list" width="100%" />
</p>

**Discover what's adjacent.** Open any `/track/:id` page → scroll to **related tracks** at the bottom → Enter on any of them to start playing with that track as the new queue head. The current `/track` page auto-follows playback — when a track auto-advances, the page navigates with it.

**Free up screen space.** Click the `▽` at the right edge of the bottom player → the player collapses to a 44px mini-bar with cover, ticker, play / next, chevron. Click `△` to expand again.

**Check your listening.** `⌘K` → `stats` → Enter. Or visit `/stats` directly. Top 10 artists with progress bars, top genres as pills, totals (plays / unique tracks / hours) as big mono numbers.

<p align="center">
  <img src="screenshots/stats.png" alt="/stats screen with mono totals, top artists with progress bars, top genres pills" width="100%" />
</p>

**Scrobble to Last.fm.** Settings → **last.fm** → Connect → browser auth → continue. From then on, every play ≥50 % (or ≥4 min) gets scrobbled; now-playing pings after 3 s.

---

## Install

Pre-built binaries are attached to every GitHub release. Preview/test builds and
update news are posted to the Telegram channel — **[t.me/waveformsc](https://t.me/waveformsc)**.

### macOS
Requires **macOS 12 Monterey or later** for upcoming builds (starting after v0.3.0).

1. Download `waveform-macos-vX.Y.Z.dmg` from the [latest release](https://github.com/mollybyte/waveform/releases/latest).
2. Open the DMG and drag `Waveform` to your `Applications` folder.
3. Double-click. The app is signed with Apple Developer ID and notarized, so it opens without Gatekeeper prompts.

### Windows
1. Download `waveform-windows-vX.Y.Z.zip` and unzip.
2. Run `Waveform.exe`. SmartScreen will say "Unknown publisher" the first time (no EV signing cert yet) — click **More info → Run anyway**.

### Linux
1. Download `waveform-linux-vX.Y.Z.tar.gz`.
2. `tar xzf` it and run `./waveform_app`.

After first launch: **sign in** via Settings → account, then go back to Home — your personal stream, likes, and playlists populate from your real account.

---

## What works today

Daily-driver loop:

- **Live SoundCloud data** via the internal `api-v2`. No mock data in the shipping app.
- **Per-user login** through SoundCloud's real sign-in page in an embedded WebView. The session token is captured and persisted locally in `getApplicationSupportDirectory()` (sandboxed per-user app data).
- **Real HLS playback** via [`just_audio`] (native AVPlayer on macOS). Gapless + crossfade, with serialized engine ops so the volume slider, progress bar and play/pause never desync mid-transition. Progressive-stream fallback when HLS variants fail. Encrypted HLS (`cbc-/ctr-encrypted-hls`) is detected and skipped with a UI notice (GO+ tracks).
- **True-shuffle with real history** — next / previous retrace the exact path you played, no repeats within a cycle, stable upcoming queue.
- **Perceptual volume** (cubic taper) — usable range spread across the whole slider instead of the bottom few percent.
- **Real waveforms everywhere** — lists, player, feed cards and the track page all show the same SoundCloud waveform (fetched lazily with a shared cache; procedural shape as an instant fallback).
- **OS media keys + now-playing card** via `audio_service`.
- **Screens:** Home (your stream + curated shelves), Feed, Library (likes / playlists / albums / stations / following / history), Search (tracks / people / playlists), Track page (waveform + comments with timecodes + related), Artist page, Playlist page, Settings, Stats. Content is centered and width-capped on wide displays; the right rail stays pinned to the window edge.
- **Liked / reposted state** synced across track rows, player, and track page. The full likes set loads progressively so highlighting is complete, not capped. Optimistic +1/−1 with revert on API failure.
- **Open SoundCloud links in-app** — copy a `soundcloud.com/…` link and a toast offers to open it here (toggle in Settings → links); or paste it into ⌘K. `waveform://` scheme registered on macOS.
- **Top-right toasts** that dismiss on click.
- **Persistent queue panel** with drag-reorder + remove; likes list is virtualized (smooth with hundreds of tracks / "shuffle all").
- **Tiles ↔ list** view toggle (persisted), available in Library + Search.
- **Hero transitions** on cover art when navigating cards → detail.
- **Ambient album-art backdrop** behind hero blocks (full window width, blur 80, soft top→bg gradient).
- **Skeleton loaders** on first paint.
- **Dynamic window title** — `Waveform · {artist} — {title}`; drag the window by the top bar (all platforms).
- **In-app log screen** at `/logs` powered by [Talker] (Riverpod + Dio integration).

<p align="center">
  <img src="screenshots/library.png" alt="Library / likes in list view: TrackRow with listens / likes / duration columns, search field, view toggle, shuffle-all" width="100%" />
</p>

---

## Design

Dark theme by default (light theme planned). Brutal details: **3px radii, 0.5px borders**.

| Token | Value | Use |
|-------|-------|-----|
| `bg` / `surface` / `surface2` | `#0A0A0A` / `#111111` / `#1A1A1A` | backgrounds |
| `textHi` / `textMid` / `textLow` | `#F5F5F5` / `#888888` / `#555555` | text |
| `acid` | `#FF5500` | active elements only (SoundCloud orange) |
| `lime` | `#C6FF00` | web3 markers (minted / owned — visual only for now) |

Typography: **Inter** for text and headings, **JetBrains Mono** for all numbers, timecodes, durations, and technical labels.

---

## Stack

Flutter + Dart 3.11. Key packages: `flutter_riverpod` (state), `go_router` (navigation), `just_audio` (playback), `audio_service` (OS media controls), `dio` (HTTP), `path_provider` (token + cache paths), `cached_network_image`, `google_fonts`, `talker_flutter` (logging), `window_manager` (dynamic title + traffic-light overlay).

Feature-first layout:

```
lib/
├── app/        # theme, router, shell, global keyboard shortcuts
├── core/
│   ├── api/    # SoundCloud api-v2 client, DTOs, mappers, auth, liked-tracks
│   ├── audio/  # two-engine just_audio wrapper behind an interface
│   ├── cache/  # image cache (JSON-backed; no sqflite on desktop)
│   ├── lastfm/ # auth flow + scrobbler
│   ├── log/    # Talker
│   └── storage/# file-based token + prefs persistence
├── features/   # auth, home, feed, library, search, track, artist, playlist, player, queue, stats, settings, omnibox, debug
└── shared/     # models, reusable widgets, intents, formatting helpers
```

State via Riverpod, navigation via go_router. All numerics through an `AppTheme.mono()` helper; acid orange used sparingly (active elements only).

---

## Getting started

Prerequisites: a recent [Flutter](https://docs.flutter.dev/get-started/install) SDK with desktop support enabled.

```bash
flutter pub get
flutter run -d macos      # or -d windows / -d linux
```

Run against built-in mock data (offline, no network or login):

```bash
flutter run -d macos --dart-define=MOCK=true
```

Tests + static analysis:

```bash
flutter test
flutter analyze
```

---

## How data & auth work

- Waveform talks to SoundCloud's **undocumented `api-v2`**. The app key (`client_id`) is **scraped from soundcloud.com at runtime** — nothing is shipped or hardcoded.
- Personal data requires logging in with **your own SoundCloud account** via the WebView flow. The OAuth token is written to a file inside the app's sandboxed support directory (`getApplicationSupportDirectory()`); anonymous endpoints never carry it.
- Personal collections use `/users/{id}/…` (the `/me/…` equivalents 404 in api-v2).

---

## Known limitations

- **DRM tracks won't play.** SoundCloud increasingly serves encrypted HLS (`cbc-/ctr-encrypted-hls`), which the desktop audio engine can't decode. Such tracks are detected, marked `🔒 GO+` in UI, and skipped — playing them would require Widevine/EME support that `just_audio` doesn't provide on desktop.
- **macOS-first.** Windows/Linux build but are less exercised.
- **Like / repost writes are best-effort.** The api-v2 write endpoints aren't a stable contract; blocked writes (e.g. behind a VPN / captcha challenge) are surfaced in the UI but may not always recover.
- **No play-history writing or comment likes.** Verified against api-v2 with a token client — the write endpoints return 404 and tracks/comments expose no per-user like flag — so these aren't implemented. The home "listening history" rail reflects plays recorded by official SoundCloud clients.
- **Deep links are clipboard / paste based, not OS-level.** Becoming the system handler for `https://soundcloud.com` would need Universal Links hosted on SoundCloud's own servers (impossible) or hijacking all `https` (unacceptable), so Waveform watches the clipboard and accepts pasted links instead. A `waveform://` scheme is registered on macOS; Windows/Linux scheme registration is installer-level and pending.
- **Windows sign-in lags.** The embedded WebView2 sign-in page is heavy; the reliable path on Windows is pasting your `oauth_token` (the login dialog has a step-by-step guide).
- **Official OAuth 2.1 + PKCE** is not used — SoundCloud's developer-app registration has been effectively closed for years, so the WebView token flow stands in for it.
- **No light theme yet** — design is dark-by-default.
- **No real WalletConnect yet** — web3 markers are visual accents only.

---

## Roadmap

- Light theme + system-appearance follow
- Drag tracks between playlists
- Lyrics view on the track page
- Reduced-motion + full VoiceOver pass (accessibility audit)
- Stats: hour-of-week heatmap from `played_at`
- Always-on-top compact "just the player" mode (300×120)
- Official OAuth 2.1 + PKCE (if SoundCloud reopens registration)
- Real WalletConnect v2 (currently visual accents only)
- Windows EV code-signing (currently `.zip` without signature → SmartScreen prompt)

---

## Cutting a release

The CI/release pipeline is wired up; tagging is what you do by hand.

### One-time setup (per maintainer machine)

1. **Apple Developer Program** ($99/yr) — you need the `Developer ID Application` cert in your local Keychain. Export it as `.p12` (right-click cert + private key → Export → set a password).
2. **GitHub Actions secrets** at `Settings → Secrets and variables → Actions`:
   - `APPLE_TEAM_ID` — 10-char Team ID from [Apple Developer → Membership](https://developer.apple.com/account#MembershipDetailsCard).
   - `APPLE_CERT_P12_BASE64` — `base64 -i cert.p12 | pbcopy`.
   - `APPLE_CERT_PASSWORD` — the password you set on `.p12`.
   - `APPLE_ID` — your Apple ID email.
   - `APPLE_APP_PASSWORD` — an app-specific password ([appleid.apple.com](https://appleid.apple.com) → Sign-In and Security → App-Specific Passwords; name it `Waveform notarytool`).
   - `KEYCHAIN_PASSWORD` — any random string; used only inside the CI runner.
3. **Last.fm credentials** (optional, only if you want scrobbling in the shipped build): register Waveform on [last.fm/api/account/create](https://www.last.fm/api/account/create), then add **two more GitHub Actions secrets**: `LASTFM_API_KEY` and `LASTFM_SHARED_SECRET`. The release workflow passes them through `--dart-define` at build time — they end up in the binary but **never in the public source**. Last.fm explicitly asks to keep `shared_secret` private, so don't paste it into `lib/core/lastfm/lastfm_constants.dart` directly. For local testing: `flutter run --dart-define=LASTFM_API_KEY=… --dart-define=LASTFM_SHARED_SECRET=…`.
4. **App icon**: put a square `1024×1024` PNG at `assets/icon/icon.png` and run:
   ```bash
   dart run flutter_launcher_icons
   flutter clean
   ```

### Cutting v0.X.Y

```bash
# 1. Bump version in pubspec.yaml and lib/features/settings/settings_screen.dart::_kAppVersion
# 2. Update CHANGELOG.md
# 3. Commit + push
git tag v0.2.0
git push --tags
```

GitHub Actions runs `release.yml`: parallel macOS / Windows / Linux builds, signs and notarizes the macOS `.app`, packs everything into a release, and publishes at `https://github.com/mollybyte/waveform/releases/tag/v0.2.0`. Notes come from `.github/release_template.md`.

If the macOS job fails at codesign or notarytool, check `gh run view --log-failed <id>` and validate the secrets are present + the `.p12` is exportable on a fresh machine.

---

## Disclaimer

This is an **unofficial** client and is **not affiliated with, endorsed by, or connected to SoundCloud**. It uses an undocumented internal API; use of that API may be against SoundCloud's Terms of Service. This project is provided for **educational and personal use** — use it with your own account and at your own risk. SoundCloud, the SoundCloud logo, and related marks are trademarks of their respective owners.

## License

Waveform is released under the [MIT License](LICENSE).

The vendored [`third_party/desktop_webview_window`](third_party/desktop_webview_window) keeps its own [Apache-2.0 license](third_party/desktop_webview_window/LICENSE). The license covers this code only; it grants no rights to SoundCloud's API, content, or trademarks (see the disclaimer above).

[`just_audio`]: https://pub.dev/packages/just_audio
[Talker]: https://pub.dev/packages/talker_flutter
