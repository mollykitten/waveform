<!--
This file is the body for every GitHub Release published by release.yml.
Edit before tagging if you want release-specific notes; otherwise it
documents how to install Waveform on each platform.
-->

## Install

### macOS

1. Download `waveform-macos-<version>.dmg` from the **Assets** below.
2. Open the DMG and drag **waveform_app** into your **Applications** folder.
3. Double-click **waveform_app** in Applications.

The app is **signed with our Apple Developer ID and notarized by Apple**, so
macOS opens it without any Gatekeeper prompts.

### Windows

1. Download `waveform-windows-<version>.zip` and unzip it anywhere.
2. Run `waveform_app.exe`.

Windows SmartScreen will show **"Windows protected your PC — Unknown
publisher"** because we don't yet have a Windows code-signing EV certificate.
Click **More info → Run anyway** once; subsequent launches are clean.

### Linux

1. Download `waveform-linux-<version>.tar.gz`.
2. Extract it: `tar xzf waveform-linux-<version>.tar.gz -C ~/waveform`
3. Run `~/waveform/waveform_app`.

You may need to install `libsecret-1-0` and a GTK runtime if your distro
doesn't have them.

## What is this?

Waveform is a minimal cross-platform **desktop SoundCloud client** built with
Flutter. See the [README](https://github.com/mollybyte/waveform#readme) for the
full picture.

> **Status:** early WIP. Use it with your own SoundCloud account, expect rough
> edges, and please file issues at
> https://github.com/mollybyte/waveform/issues.

## Known limitations

- **GO+ tracks won't play.** SoundCloud serves them as DRM-encrypted HLS that
  `just_audio` can't decode on desktop; they're labelled `🔒 GO+` and skipped.
- **macOS-first.** Windows and Linux build, but are less exercised.
- This client uses SoundCloud's undocumented `api-v2`; the project is not
  affiliated with SoundCloud.

## Source code

https://github.com/mollybyte/waveform

🤖 Built and published by GitHub Actions.
