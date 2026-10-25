# known limitations

- **go+ tracks need your own widevine device profile.** they're served as encrypted hls that `just_audio` can't decode. on macos a bundled decryption core (`scdrm`) can play them, but only if you supply `assets/widevine/device.wvd` yourself — it's never shipped. without it those tracks are skipped as unavailable. windows and linux: not yet
- **macos first.** windows and linux build but i run them less
- **likes and reposts are best effort.** the api-v2 write endpoints aren't a stable contract. if one gets blocked (vpn, captcha) you'll see it in the ui but it may not recover
- **no play-history writes or comment likes.** i checked with curl: the write endpoints 404 and there's no per-user like flag on tracks or comments. the home history rail shows plays from official soundcloud clients
- **links work through clipboard and paste, not the os.** owning `https://soundcloud.com` would need universal links on soundcloud's own servers or hijacking all of `https`, so no. `waveform://` is registered on macos, windows and linux need it at the installer level
- **windows sign-in lags.** the webview2 sign-in page is heavy. the reliable way on windows is pasting your `oauth_token`, the login dialog walks you through it
- **no official oauth 2.1 + pkce.** soundcloud's app registration has been closed for years, the webview token flow stands in for it
- **no light theme yet.**
- **media keys and now-playing are macos only.** windows (smtc) and linux (mpris) backends aren't wired yet

what's planned: [roadmap](roadmap.md)
