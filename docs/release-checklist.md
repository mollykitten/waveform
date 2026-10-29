# manual release checklist

run on the dry-run build of main (`gh workflow run release.yml --ref main`),
installed from the dmg on a clean mac, not from `flutter run`.

## install and first run
- [ ] dmg opens with the branded background, drag into applications works
- [ ] first launch: no gatekeeper warning (signed, notarized, stapled)
- [ ] onboarding tour plays, can be skipped, doesn't reappear on relaunch
- [ ] app icon and window title look right

## account
- [ ] settings → account: sign in via webview, avatar and name appear
- [ ] relaunch keeps the session; sign out clears it
- [ ] signed-out state: home, search and track pages still load

## playback
- [ ] play a track from home, a playlist and search; hls streams start
- [ ] scrub on the waveform, buffered tier shows
- [ ] next / prev, shuffle, repeat, volume, scroll-wheel volume
- [ ] gapless: let a track end, next starts without a gap
- [ ] crossfade at 3 s and 6 s
- [ ] unavailable track shows the "unavailable — skipped" notice
- [ ] queue panel: reorder, remove, add to queue; collapsed player works
- [ ] media keys and control center now-playing (macos)

## keyboard
- [ ] space, ←/→ seek, ⇧ + arrows skip and volume, ⌘K, ⌘L, ⌘, , ⌘⇧L
- [ ] shortcuts don't fire while typing in a text field; no system beep

## library and social
- [ ] likes, playlists, following, history tabs; tiles ↔ list toggle persists
- [ ] like and repost a track, state survives relaunch
- [ ] shuffle all likes, shuffle all on a playlist
- [ ] track page: comments with timecodes, related tracks, share / copy link
- [ ] artist page, search tabs (tracks / people / playlists)
- [ ] right-click menu on a track row

## extras
- [ ] stats screen with a real account
- [ ] last.fm connect and a scrobble (only if credentials are in the build)
- [ ] my wave: configure a provider, generate, consent prompt, queue refill
- [ ] audio output picker lists devices, switching doesn't change system default
- [ ] drm track: skipped cleanly without a device profile

## release hygiene
- [ ] `WIDEVINE_DEVICE_WVD_BASE64` is set; the dmg plays a drm track
- [ ] no `*.wvd` in the windows zip or linux tar.gz
- [ ] version in settings → about is 0.4.0
- [ ] reduced-motion on: transitions calm down
- [ ] windows and linux artifacts start (best effort)
