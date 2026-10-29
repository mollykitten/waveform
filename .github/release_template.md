<!-- release.yml uses this file as the github release body. -->

## waveform v0.5.0

installers and automatic updates on all three platforms, a macos menu bar
player, playback, window controls and `waveform://` links on windows and linux,
and library, likes and player fixes.
see the [changelog](https://github.com/mollykitten/waveform/blob/main/CHANGELOG.md)
for the full changes.

## install

### macos (12+)

1. download `waveform-macos-v0.5.0.dmg` from the assets below.
2. open the DMG and drag `Waveform.app` into applications.
3. open waveform from applications.

the release workflow requires developer id signing, accepted apple
notarization and a validated stapled ticket before creating the DMG.
macos may still show its normal first-open confirmation. signing and
notarization do not replace checking the downloaded app on a clean macos system.

later versions arrive through the built-in updater (sparkle).

### windows (when assets are attached)

1. download `waveform-windows-v0.5.0-setup.exe` and run it. it installs per
   user, without admin rights, and updates itself through winsparkle.
2. or download `waveform-windows-v0.5.0.zip`, extract the entire archive and
   run `waveform_app.exe` with the extracted libraries and data beside it
   (no automatic updates).

windows builds are unsigned. smartscreen may warn about an unknown publisher;
the exact warning and available actions depend on the machine's policy.

### linux (when assets are attached)

1. download `waveform-v0.5.0-x86_64.AppImage`, `chmod +x` it and run it.
   with `appimageupdatetool` installed it updates through zsync; without it
   the app points to this page.
2. or download `waveform-linux-v0.5.0.tar.gz`, `mkdir -p ~/waveform`,
   `tar xzf waveform-linux-v0.5.0.tar.gz -C ~/waveform` and run
   `~/waveform/waveform_app`; keep the bundled libraries and data beside it.

system GTK, webkit2gtk 4.1, libsoup 3 and libmpv runtimes are required;
package names vary by distribution.

## known limitations

- early software, primarily exercised on macos. windows and linux have less
  runtime coverage; OS media controls currently work on macos only.
- native playback/refill of my wave and its recommendation quality still
  require manual validation. local structural vectors are not audio
  embeddings; no backend service or model weights are included.
- physical airplay receiver playback and switching outputs during playback
  still require hardware verification. airplay mode conservatively suspends
  gapless/crossfade until a local output is selected.
- DRM playback is macos-only. without a device profile, encrypted-only
  tracks are unavailable and skipped; go+ tracks still need a subscription.
- windows and linux playback (media_kit), installers and updaters have not
  been verified on real machines yet.
- this unofficial client uses soundcloud's undocumented `api-v2` and is not
  affiliated with soundcloud. use your own account and expect rough edges.

[readme](https://github.com/mollykitten/waveform#readme) ·
[issues](https://github.com/mollykitten/waveform/issues) ·
[source](https://github.com/mollykitten/waveform)
