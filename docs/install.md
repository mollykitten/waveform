# install

builds are attached to every github release. test builds and news go to telegram first: **[t.me/waveformsc](https://t.me/waveformsc)**

**macos.** needs macos 12 monterey or later starting after v0.3.0
1. grab `waveform-macos-vX.Y.Z.dmg` from the [latest release](https://github.com/mollykitten/waveform/releases/latest)
2. drag waveform into applications
3. open `Waveform.app`. the release workflow requires developer id signing,
   accepted notarization and a validated stapled ticket before packaging. macos
   may still show its normal first-open confirmation; clean-system installation
   must be checked separately

updates: waveform checks for new versions once a day (and on settings → about →
check for updates) and installs them through sparkle.

**windows.**
1. grab `waveform-windows-vX.Y.Z-setup.exe` and run it. it installs for the
   current user only (no admin rights), adds a start menu shortcut and an
   uninstaller. builds are unsigned; smartscreen may warn about an unknown
   publisher, depending on the machine's policy
2. updates arrive through winsparkle and run the same setup silently
3. portable: `waveform-windows-vX.Y.Z.zip` unzips anywhere; run `waveform_app.exe`
   with the extracted libraries and data beside it (no automatic updates)

**linux.**
1. appimage: grab `waveform-vX.Y.Z-x86_64.AppImage`, `chmod +x` it and run it.
   it needs the system gtk 3, webkit2gtk 4.1 and libmpv libraries (same as the tar.gz).
   to update in place install [appimageupdatetool](https://github.com/AppImage/AppImageUpdate)
   and put it in `PATH`; without it waveform tells you a new version exists and
   opens the release page
2. tarball: grab `waveform-linux-vX.Y.Z.tar.gz`, `tar xzf` and run `./waveform_app`
   (update checks only point you to the release page)

linux update checks are not signed: they rely on tls and github alone (the
releases api tells waveform a newer tag exists; `appimageupdatetool` downloads
the appimage from the same release). macos and windows verify an ed25519
signature before installing.

first launch: sign in via settings → account, go back home, your stream, likes and playlists show up

want to build it yourself? see [development](development.md)
