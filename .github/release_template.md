<!-- release.yml uses this file as the github release body. -->

## waveform v0.4.0

my wave recommendations that run entirely on your device, continuous queue
refill, local listening graph vectors, macos output selection and a native
airplay picker, plus keyboard accessibility and reduced-motion improvements.
see the [changelog](https://github.com/mollykitten/waveform/blob/main/CHANGELOG.md)
for the full changes, including the optional developer worker notifier.

## install

### macos (12+)

1. download `waveform-macos-v0.4.0.dmg` from the assets below.
2. open the DMG and drag `Waveform.app` into applications.
3. open waveform from applications.

the release workflow requires developer id signing, accepted apple
notarization and a validated stapled ticket before creating the DMG.
macos may still show its normal first-open confirmation. signing and
notarization do not replace checking the downloaded app on a clean macos system.

### windows (when a zip is attached)

1. download `waveform-windows-v0.4.0.zip` and extract the entire archive.
2. run `waveform_app.exe` with the extracted libraries and data beside it.

windows builds are unsigned. smartscreen may warn about an unknown publisher;
the exact warning and available actions depend on the machine's policy.

### linux (when an archive is attached)

1. download `waveform-linux-v0.4.0.tar.gz`.
2. create a directory: `mkdir -p ~/waveform`.
3. extract: `tar xzf waveform-linux-v0.4.0.tar.gz -C ~/waveform`.
4. run `~/waveform/waveform_app`; keep the bundled libraries and data beside it.

system GTK, webkit2gtk 4.1 and libsoup 3 runtimes are required;
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
- go+ DRM fallback is macos-only and requires a user-supplied device profile.
  no device profile is bundled. without one, encrypted-only tracks can be
  unavailable and skipped; there is no locked-track badge.
- this unofficial client uses soundcloud's undocumented `api-v2` and is not
  affiliated with soundcloud. use your own account and expect rough edges.

[readme](https://github.com/mollykitten/waveform#readme) ·
[issues](https://github.com/mollykitten/waveform/issues) ·
[source](https://github.com/mollykitten/waveform)
