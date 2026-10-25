# install

builds are attached to every github release. test builds and news go to telegram first: **[t.me/waveformsc](https://t.me/waveformsc)**

**macos.** needs macos 12 monterey or later starting after v0.3.0
1. grab `waveform-macos-vX.Y.Z.dmg` from the [latest release](https://github.com/mollykitten/waveform/releases/latest)
2. drag waveform into applications
3. open `Waveform.app`. the release workflow requires developer id signing,
   accepted notarization and a validated stapled ticket before packaging. macos
   may still show its normal first-open confirmation; clean-system installation
   must be checked separately

**windows.**
1. grab `waveform-windows-vX.Y.Z.zip` and unzip
2. run `waveform_app.exe` with the extracted libraries and data beside it. builds
   are unsigned; smartscreen may warn about an unknown publisher, depending on
   the machine's policy

**linux.**
1. grab `waveform-linux-vX.Y.Z.tar.gz`
2. `tar xzf` and run `./waveform_app`

first launch: sign in via settings → account, go back home, your stream, likes and playlists show up

want to build it yourself? see [development](development.md)
