# Changelog

All notable changes to Waveform are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### added
- **my wave draws on three candidate sources**: the related-track graph, your
  home stream and co-likers (people with similar likes), interleaved 50% /
  25% / 25% with a shared playability filter. co-likers run as a background
  job (at most 250 requests, cached for 24 hours without other users' ids);
  listening facts record which source supplied each track, and stats shows a
  listened/skipped tally per source.

### removed
- **the model-assisted route of my wave.** the chatgpt connection, custom
  openai-compatible and ollama providers, the mood field and the listening
  consent dialog are gone: my wave now runs entirely on this device. an
  offline pilot found the model route reached none of 100 new likes, below the
  related-track graph. dev builds may leave a keychain item
  `waveform.chatgpt.credentials.v1` and an `ai_config.json` in the support
  directory; both can be deleted by hand.
- the `jose`, `flutter_secure_storage` and `url_launcher` dependencies, the
  loopback-server entitlement and the linux libsecret build requirement.

## [0.4.0] — 2026-10-28

my wave recommendations, macos audio output controls, keyboard accessibility,
and release preparation. includes the merged work in #50–#56.

### added
- **my wave** plays a continuous queue of real soundcloud tracks. local
  structural vectors rank a bounded related-track pool using account-isolated
  listening evidence, diversity and exploration; these are graph vectors, not
  audio embeddings. nothing is sent to a model.
- **macos audio output selection** lists real core audio devices and routes
  waveform's players without changing the system default. a native airplay
  picker stays attached to the active player; opening it conservatively
  suspends gapless/crossfade until a local output is selected.
- **keyboard activation, focus and semantics** for shared controls and player
  collapse controls; reduced motion extends to routes and transient UI.
- **opt-in developer worker notifier** delivers completed ACP worker messages
  to a coordinator with durable identities, retries and journal replay. its
  python regressions run in CI; no active watcher or credentials are shipped.
- **drm-protected tracks play on macos** (uploaded by distributors and labels)
  through a bundled Widevine decryption core (`scdrm`, go over `dart:ffi`), as
  a fallback after regular streams. go+ tracks still require a go+
  subscription. from source you need your own device profile in
  `assets/widevine/device.wvd`; it's never committed.
- **copy-link button** in both player layouts; selectable track title and
  description.
- **new app icon, svg logo** and a static landing page.

### changed
- **my wave presentation** uses animated ribbons and a single play action.
  generation preserves the queue until results play.
- desktop account controls stay aligned 16px from the window edge.
- **macos 12 monterey is now the minimum supported version.** runner, tests,
  and cocoapods targets use a consistent minimum compatible with xcode 27.
- **web3 removed.** the `◆ minted` badge and wallet placeholders are gone;
  lime stays as a secondary accent for markers.
- **the `🔒 GO+` locked-track badge is gone**; unplayable tracks get the
  common "unavailable — skipped" notice.
- docs moved from the README into `docs/`.

### fixed
- settings and my wave forms share compact controls, consistent labels and
  spacing.
- the owned wave control pauses and resumes playback; compact rows show the
  actual upcoming queue and preserve recommendation reasons.
- my wave background reacts to fetched soundcloud waveform envelopes during
  advancing playback, not an fft/pcm spectrum; the envelope reaction stops
  when hidden or paused.
- audio output uses an icon-only trigger and shows full device names in its menu.
- initial profile lookup failures retry with bounded backoff; listening
  attribution stays suspended until identity is verified.
- player source generations and swap recovery preserve playback intent,
  reject stale preloads after queue edits, and avoid attributing outgoing
  audio to a pending track.
- audio output binding keeps pause/resume and active-player state coherent.
- collection navigation avoids invalid hero tags.
- reduced motion is respected by press states and skeleton pulses.
- windows sign-in navigation no longer gets intercepted.
- webview engines start through their own titlebar entrypoint.
- the ⌘K search trigger stays in sync with query edits.
- release workflow uses a bounded notarization wait, retrieves the apple log
  when a submission id is available, installs linux webkit/libsoup
  build dependencies, and waits for all platforms before the publish gate.

### validation limits
- native playback/refill of my wave and its musical recommendation quality
  still require manual validation.
- physical airplay receiver playback and switching outputs during playback
  still require hardware verification; a compiled picker is not that evidence.
- the older [dry run on 2026-10-25](https://github.com/mollykitten/waveform/actions/runs/40156324361)
  built and signed macos and built windows/linux, but apple rejected notarization
  with HTTP 403 for a missing or expired required agreement. staple and DMG
  creation were skipped. it ran SHA `4e4f87463f77f7e077724a1d73ffd7be9836edcc`,
  so the release candidate still needs its own successful dry run.

## [0.3.0] — 2026-06-10

Account actions finally stick, full keyboard control, and smoother transitions.

### Added
- **Likes & reposts now actually save.** SoundCloud's DataDome anti-bot was
  rejecting write requests (403) because a plain HTTP client doesn't present a
  browser TLS fingerprint. Writes now execute inside the app's own (invisible)
  WebView, which carries a real browser fingerprint + live anti-bot cookie — so
  the heart and repost buttons persist server-side. Reads are unchanged, and no
  other browser's data is ever touched.
- **Web-parity keyboard control.** Full SoundCloud-web keymap: Space play/pause,
  ←/→ seek ±5s, Shift+←/→ track nav, Shift+↑/↓ volume, M mute, 0–9 seek %,
  L like, R repost, S search, Q queue, P go-to-playing, plus G-then-key chords —
  and an `H` help overlay listing everything. ⌘⇧C copies the current
  page / track link.
- **Trackpad / mouse edge-swipe back**, with consistent push-style drill-in
  navigation from feed / home / rail cards.
- **Search across all likes**, not just the currently loaded page.

### Fixed
- **Silent incoming track on crossfade** — the swap awaited a `play()` future
  that only completes when playback *stops*, so the next track came up muted.
- **Crossfade now actually overlaps** — it begins before the current track ends
  instead of only at completion.
- **Shortcuts firing while typing** in text fields / the ⌘K omnibox.

## [0.2.0] — 2026-05-31

Stability pass after a week of daily-driving. The audio engine, shuffle and
likes got the most attention — several bugs that made the core loop feel broken
are fixed — plus a few new conveniences.

### Fixed — playback
- **Volume / progress / play-pause going dead together.** Root cause was an
  `_active`-pointer desync in the dual-player engine: during a crossfade ramp
  (up to 6 s) the pointer could land on a paused player while another produced
  sound, so the volume slider, the progress bar and Space all targeted the
  wrong player. Swap now keeps `_active` on the current track from the start and
  a generation counter lets a new action cleanly interrupt an in-flight ramp.
- **Pause not stopping the sound** during a crossfade — pause now cancels the
  ramp and silences both players.
- **Playback stalling at the end of a track** (~1 in 10) — the completion gate
  now uses the max observed position instead of the lagging last sample.
- **Next track starting from the middle / near the end** — explicit seek-to-zero
  on load/swap plus a guard that drops stale position events after a track change.

### Fixed — shuffle, likes, omnibox
- **True-shuffle** rebuilt around a real play-history stack: next / previous
  now retrace the actual path in both directions, no repeats within a cycle, and
  the upcoming queue stays stable across navigation and queue edits.
- **Likes not lighting up.** The highlight set only fetched the first 200 likes;
  it now loads the full set progressively (recent likes light up instantly, the
  rest fill in in the background).
- **Spacebar in the ⌘K omnibox** typed nothing — the global Space → play/pause
  shortcut ate it. Global shortcuts are now disabled while the palette is open.
- **Waveforms in lists / player** no longer differ from the track page — the
  real waveform is fetched lazily (shared cache) everywhere, with the procedural
  shape as an instant fallback.

### Added
- **Open SoundCloud links from the clipboard.** Copy a `soundcloud.com/…` link
  and Waveform offers a toast to open it in-app (toggle in Settings → links).
  Also: paste a link into ⌘K to jump to it, and a `waveform://` scheme on macOS.
- **Top-right toasts** that dismiss on click (replacing bottom SnackBars).
- **Drag the window** by the top bar on Windows / Linux (`DragToMoveArea`).
- **Sign-in help**: an "open soundcloud.com" button and a step-by-step guide to
  grab your `oauth_token` — the reliable path on Windows where the embedded
  webview lags.

### Changed
- **Perceptual volume taper** (cubic): the usable low-volume range is now spread
  across the slider instead of being crammed into the bottom few percent.
- **Wide-screen layout**: home / feed / search / library content is centered and
  width-capped on large displays; the right rail stays pinned to the window edge.
- **Likes list virtualized** — no lag with hundreds of likes or after "shuffle
  all" (only visible rows render).
- **Comments** on the track page are capped with a "show all" expander so
  related tracks stay reachable on heavily-commented tracks.

### Removed
- Non-functional **play-history writing** and **comment likes** — verified that
  SoundCloud's api-v2 doesn't expose these to a token client (the write
  endpoints 404), so the dead calls and UI were removed rather than left to fail
  silently.

## [0.1.0] — 2026-05-28

First demo release for friends. Far from a polished v1.0, but the daily-driver
loop works end-to-end on macOS (Windows / Linux build too, less exercised).

### Added — visual & interaction
- Hero transitions for cover art when navigating cards → track / playlist
  detail.
- Subtle hover fill on every `Pressable` (Apple Finder-like).
- Unified `EmptyState` widget wired into search / library tabs / feed / track
  comments (no more bare blank zones).
- Skeleton loaders for the home screen first paint (replaces the acid
  spinner with a layout-matching placeholder).
- Optimistic +1 / −1 on like and repost counters on the track page; reverts
  if the API write fails.
- Volume scroll-wheel on the player volume icon + mute tooltip with the
  current `xx%`.
- Buffered tier on the mini-waveform (acid at 0.35 alpha between played and
  unplayed bars).
- Ambient album-art backdrop on `/track` and `/playlist` heroes (extracted
  via `palette_generator`, soft top→transparent gradient).

### Added — input & navigation
- TopBar search field doubles as a **⌘K omnibox**: actions
  (settings / logs / likes / shuffle / sign out / clear cache), live
  SoundCloud results (debounced 250 ms), recent queries (persisted), and a
  "search '<q>' →" footer for the full results page. Placeholder shows
  `playing: <artist> — <title>` when empty.
- Global keyboard shortcuts: **Space** play / pause, **← / →** prev / next,
  **⌘/Ctrl + K** or **F** focus omnibox, **⌘/Ctrl + L** open library /
  likes, **⌘/Ctrl + ,** open settings, **⌘/Ctrl + Shift + L** open logs.
- Right-click context menu on track rows (play / like / repost / copy
  link / open on SoundCloud / open artist / open track page).

### Added — player
- Persistent right-side **queue panel** with current-track header,
  drag-handle reorder, and remove buttons. Toggle via the `queue_music`
  icon in the top bar.
- BottomPlayer **collapse mode**: a 44 px bar with mini cover + mono ticker
  + play / next / chevron-up. Toggle via the `expand_more` icon at the right
  edge of the expanded bar.
- **Gapless playback** by default (two-engine architecture in
  `JustAudioEngine` — preloads the next track on the inactive `AudioPlayer`
  and instant-swaps on completion).
- **Crossfade** 0–6 s configurable in `/settings → playback`; 0 = pure
  gapless.
- **OS media keys + now-playing** via `audio_service`: Control Center on
  macOS, SystemMediaTransportControls on Windows, MPRIS on Linux.

### Added — integrations
- **Last.fm scrobbling**: optional, off by default until you fill
  `lastfmApiKey` + `lastfmSharedSecret` in
  `lib/core/lastfm/lastfm_constants.dart`. Once configured: connect via
  `/settings → last.fm`, browser auth flow, scrobbles on ≥50 % played
  OR ≥4 min.
- **Local listening stats** (`/stats`): total plays / unique artists / total
  hours, top 10 artists with progress bars, top genres pills. Aggregated
  from up to ~400 entries of `/me/play-history`.

### Added — release pipeline
- GitHub Actions CI (`flutter analyze` + `flutter test` on every push and
  PR, pinned to Flutter 3.41.0 to match local dev).
- Release workflow on `v*` tags: parallel macOS / Windows / Linux builds.
  macOS is signed with the `Developer ID Application` cert, notarized via
  `xcrun notarytool`, stapled, and packaged as a `.dmg` (no Gatekeeper
  prompts at install for users). Windows / Linux ship as plain `.zip` /
  `.tar.gz` for now.

### Changed
- Library tabs and search → playlists support a global **tiles ↔ list**
  toggle (persisted via the new `PrefsStore`).
- OAuth token persistence moved from `flutter_secure_storage` (didn't
  survive launches on sandboxed macOS without a dev-team signing
  identity) to a small file in `getApplicationSupportDirectory()` —
  inside the per-app sandbox container.

### Known limitations
- **GO+ (subscription) tracks won't play**: they're served as DRM-encrypted
  HLS that `just_audio` can't decode on desktop. They're labelled `🔒 GO+`
  and skipped instead of failing silently.
- **macOS-first**. Windows / Linux build but are less exercised.
- Like / repost API write endpoints (`/users/{me}/track_likes/{id}` and
  `/track_reposts/{id}`) are best-effort — blocked / captcha responses are
  surfaced via a SnackBar with a "verify" action that opens
  soundcloud.com in a webview.
- Listening stats currently look at the most recent ~400 plays — no
  full-history paginator, no time-of-day heatmap (backlog).
- Windows builds are **unsigned** (no EV cert yet); SmartScreen will warn
  the first time.

[0.1.0]: https://github.com/mollybyte/waveform/releases/tag/v0.1.0
