# cutting a release

ci and the release pipeline are wired up, the tag is the only manual part

## one-time setup

1. **apple developer program** ($99/yr). you need the `Developer ID Application` cert in your keychain, export it as `.p12` with a password
2. **github actions secrets** in settings → secrets and variables → actions:
   - `APPLE_TEAM_ID`: the 10-char team id from [apple developer → membership](https://developer.apple.com/account#MembershipDetailsCard)
   - `APPLE_CERT_P12_BASE64`: `base64 -i cert.p12 | pbcopy`
   - `APPLE_CERT_PASSWORD`: the `.p12` password
   - `APPLE_ID`: your apple id email
   - `APPLE_APP_PASSWORD`: an app-specific password from [appleid.apple.com](https://appleid.apple.com), name it `Waveform notarytool`
   - `KEYCHAIN_PASSWORD`: any random string, only used inside the ci runner
3. **last.fm** (optional, only if you want scrobbling in the shipped build): register on [last.fm/api/account/create](https://www.last.fm/api/account/create) and add `LASTFM_API_KEY` and `LASTFM_SHARED_SECRET` as two more secrets. the release workflow passes them through `--dart-define`, so they land in the binary and never in the public source. last.fm asks to keep `shared_secret` private, don't paste it into `lib/core/lastfm/lastfm_constants.dart`. locally: `flutter run --dart-define=LASTFM_API_KEY=… --dart-define=LASTFM_SHARED_SECRET=…`

## cutting v0.X.Y

```bash
# 1. bump version in pubspec.yaml and _kAppVersion in lib/features/settings/settings_screen.dart
# 2. update CHANGELOG.md
# 3. commit + push
git tag v0.X.Y
git push --tags
```

github actions runs `release.yml`: macos, windows and linux build in parallel, the macos `.app` gets signed and notarized, everything lands in a release at `https://github.com/mollykitten/waveform/releases`. notes come from `.github/release_template.md`

if the macos job dies at codesign or notarytool, `gh run view --log-failed <id>` and check the secrets are there and the `.p12` exports on a clean machine
