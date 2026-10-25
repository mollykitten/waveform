# install

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

want to build it yourself? see [development](development.md)
