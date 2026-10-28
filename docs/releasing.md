# cutting a release

the next release is `v0.4.0`; `pubspec.yaml` is already `0.4.0+33`.
release the reviewed main tree after #56 without adding backlog features.
keep the changelog's `unreleased` status until publication is ready.

## one-time setup

1. an active apple developer membership (the company team), all required
   agreements accepted by the account holder, and a `Developer ID Application`
   certificate for that team exported as a password-protected `.p12`.
2. an app store connect api key (team key, `Developer` access is enough for
   notarization) downloaded once as `AuthKey_<id>.p8`.
3. github actions secrets in settings → secrets and variables → actions:
   - `APPLE_CERT_P12_BASE64`: base64-encoded `.p12`.
   - `APPLE_CERT_PASSWORD`: the `.p12` password.
   - `KEYCHAIN_PASSWORD`: password for the temporary CI keychain.
   - `APPLE_API_KEY_P8_BASE64`: base64-encoded `.p8` api key.
   - `APPLE_API_KEY_ID`: the api key id.
   - `APPLE_API_ISSUER_ID`: the issuer id from app store connect.

   `APPLE_ID` and `APPLE_APP_PASSWORD` are no longer used, and neither is
   `APPLE_TEAM_ID`; delete them once the first run is green.
4. optional last.fm credentials: `LASTFM_API_KEY` and `LASTFM_SHARED_SECRET`.
   the workflow passes them through `--dart-define`. they are compiled into
   the binary; keeping them out of git does not make a client binary a secret
   store. never commit credential values.

## update signing key (sparkle / winsparkle)

macos (sparkle) and windows (winsparkle) verify updates with one ed25519 key
pair. the public half is committed; the private half is only a github secret.

1. download the sparkle release matching the pod (`Sparkle-2.9.6.tar.xz` from
   github.com/sparkle-project/Sparkle/releases), unpack it somewhere outside
   the repo and run `bin/generate_keys`. it stores the private key in your
   login keychain and prints the public key.
2. put the public key into `macos/Runner/Info.plist` (`SUPublicEDKey`) and
   `windows/runner/Runner.rc` (`EdDSAPub EDDSA "…"`), replacing
   `REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY`. tag builds refuse to run while the
   placeholder is still there.
3. export the private key with `bin/generate_keys -x sparkle_private.key`,
   store the file's contents as the github secret **`SPARKLE_ED_PRIVATE_KEY`**
   and delete the file. never commit it, paste it in a pr or keep a copy in
   the repo. losing it means shipping a new public key in a manual release:
   existing installs cannot verify updates signed by another key.

## updates: how they reach users

the `appcast` job runs after the dmg is notarized and stapled and after the
windows installer is built. `tool/appcast.py` signs the final bytes with the
private key and writes the feeds, which the publish job attaches to the
release next to the installers:

- `appcast-macos.xml` (the dmg; `sparkle:version` = build number from
  `version: x.y.z+N`, `shortVersionString` = `x.y.z`). the app reads it from
  `SUFeedURL`:
  `https://github.com/mollykitten/waveform/releases/latest/download/appcast-macos.xml`.
- `appcast-windows.xml` (the `-setup.exe`). winsparkle compares the exe's
  `ProductVersion`, which is the whole pubspec version, so here
  `sparkle:version` is `x.y.z+N` verbatim. the setup is run with `/SILENT`.
- linux: no feed. the app asks the github releases api for the latest tag. an
  appimage started with `appimageupdatetool` in `PATH` updates in place
  (delta via the embedded `gh-releases-zsync` info and the published
  `.zsync`); everything else shows "vX available" and opens the release page.

`releases/latest` skips prereleases and drafts, so a `-rc` tag never reaches
users through the feeds. a dry run (`workflow_dispatch`) signs with a
throwaway key, so the whole path runs without the secret.

checking an update locally (macos): build a release app, serve an appcast on
`localhost` signed with a scratch key pair made in a temp directory, point
`SUFeedURL`/`SUPublicEDKey` of that scratch build at it, give the feed a
higher build number and run "check for updates" in settings → about.

## what the macos job does

1. writes the widevine device profile from the `WIDEVINE_DEVICE_WVD_BASE64`
   secret (base64 of `device.wvd`) into `assets/widevine/` for this build only,
   then deletes it from the workspace. the profile is never committed
   (`.gitignore`). without the secret the build only warns and go+ stays off.
   the windows and linux jobs still fail on any `*.wvd` (`tool/check_no_wvd.sh`):
   go+ is macos only. `pubspec.yaml` bundles the whole `assets/widevine/`
   directory because flutter has neither globs nor optional assets.
2. signs inside out, without `--deep`: every nested bundle (`.framework`, `.app`,
   `.xpc`, `.appex`) and every mach-o except the main executable, deepest path
   first (hardened runtime, timestamp), then the `.app` with
   `macos/Runner/Release.entitlements`. sparkle's helpers (`Autoupdate`,
   `Updater.app`, `Installer.xpc`, `Downloader.xpc`) are covered by that loop
   and verified afterwards; `Downloader.xpc` keeps its own entitlements
   (`--preserve-metadata=entitlements`). the sandbox mach-lookup names
   `$(PRODUCT_BUNDLE_IDENTIFIER)-spks`/`-spki` are resolved to the real bundle
   id before signing, because `codesign` does not expand build settings.
   prints the effective entitlements.
3. notarizes the `.app` with the api key via `tool/notarize.sh` (bounded
   wait, apple log on failure), staples it and runs
   `spctl --assess --type execute`.
4. builds the styled dmg from the stapled app with `tool/make_dmg.sh`
   (`ditto` copy + `dmgbuild` for background, window size and icon layout;
   the background is `assets/brand/dmg-background*.png` from
   `tool/brand/make_icons.py`), checks the staple inside it, signs it,
   notarizes it, staples it and runs `spctl --assess --type open --context
   context:primary-signature`.
5. the api key lives in `$RUNNER_TEMP` (written with `umask 077`) and is
   removed in an `if: always()` step.

all third-party actions are pinned to full commit shas (tag in the comment).
bump them deliberately; dependabot proposes the new sha.

## libscdrm.dylib

`macos/Runner/Frameworks/libscdrm.dylib` is a committed binary built from
`third_party/scdrm` by `tool/build_scdrm.sh`. ci runs `go test ./...` and
rebuilds it on a mac runner to prove the sources still build, but the release
bundles the committed file as is.

## candidate checks

1. review the exact candidate diff and confirm `pubspec.yaml` stays at
   `0.4.0+33` and `_kAppVersion` in `lib/features/settings/settings_screen.dart`
   stays at `0.4.0` so the about screen matches the release. confirm release
   notes describe the merged scope and outstanding manual checks honestly.
2. require a clean analyzer, passing flutter tests, and passing worker notifier
   tests on that tree. CI uses flutter 3.41.0 and runs:

   ```bash
   flutter analyze
   flutter test
   ```

   the #56 baseline reported 356 flutter tests passing (10 optional image
   captures skipped) and 36 notifier tests passing. those counts do not
   replace checking the final candidate.
3. merge the reviewed release preparation PR only after required CI passes.
   record the final `origin/main` SHA. run the dry run from that final main
   ref, without a tag:

   ```bash
   gh workflow run release.yml --repo mollykitten/waveform --ref main
   gh run list --repo mollykitten/waveform --workflow release.yml --limit 5
   gh run view <run-id> --repo mollykitten/waveform --json headSha,jobs,conclusion,url
   ```

4. confirm the run's `headSha` equals the intended main SHA. macos must
   complete signing verification, accepted notarization, staple validation,
   DMG signing, notarization and staple, gatekeeper assessment and upload.
   record windows and linux results separately:
   they are best effort, and notes must only claim assets that actually exist.
   confirm the publish job is **skipped**: `workflow_dispatch` on a branch
   builds artifacts but its non-tag ref cannot publish a release.
5. download and inspect the packaged artifacts. on a clean macos machine
   (no developer tools, never used for builds), with the dmg downloaded through
   a browser so it carries the quarantine flag:

   ```bash
   xcrun stapler validate waveform-macos-<ref>.dmg
   spctl --assess --type open --context context:primary-signature -v waveform-macos-<ref>.dmg
   # mount, drag Waveform.app to /Applications, then:
   codesign --verify --strict --deep --verbose=2 /Applications/Waveform.app
   codesign -d --entitlements :- /Applications/Waveform.app
   xcrun stapler validate /Applications/Waveform.app
   spctl --assess --type execute -vv /Applications/Waveform.app
   find /Applications/Waveform.app -name '*.wvd'   # prints the profile only if the secret was set
   ```

   then open the app by double-click with the network offline: it must launch
   without a gatekeeper prompt (the stapled ticket works offline).
   check extraction and launch for any windows/linux assets being published.
   record any runtime checks that remain unverified; builds and tests do not
   prove live OAuth, physical airplay or recommendation quality.

artifact names include `github.ref_name`; use final `main` for the dry run.
the workflow waits for all platform jobs, but its automatic publish condition
requires only macos success plus a tag ref; windows/linux failures do not
automatically block publication.

## observed dry-run blocker

[run 40156324361](https://github.com/mollykitten/waveform/actions/runs/40156324361)
on 2026-10-25 used SHA `4e4f87463f77f7e077724a1d73ffd7be9836edcc`.
macos build and developer id signing succeeded. notarization returned HTTP
403 because a required apple agreement was missing or expired, without a
submission id; staple, DMG creation and macos upload were skipped. windows
and linux build/package/upload succeeded. no release was published.

the apple team must resolve the required agreement before another notarization
attempt. notarization now uses an app store connect api key instead of an apple
id; the key does not change the agreement requirement.

this observation does not establish missing secrets or a workflow
defect. it also predates the current candidate: require a fresh successful macos
run on the final SHA before tagging, and record the other platform outcomes.

for a failure, inspect the actual failing step:

```bash
gh run view <run-id> --repo mollykitten/waveform --log-failed
```

the bounded notarization step requests the apple log when a submission id
exists. do not retry a red run blindly or assume every notarization error
means missing credentials.

## tag and publish v0.4.0

when the checks pass and publication is ready, replace the v0.4.0
`unreleased` marker with the actual release date through a reviewed PR. merge
it, require green CI and repeat the main dry run on the resulting final SHA.
the tag must point to the commit that passed that dry run; do not change main
between verification and tagging.

```bash
git fetch origin main --tags
git rev-parse origin/main
# compare this SHA with the successful dry run's headSha before continuing
git tag v0.4.0 origin/main
git push origin v0.4.0
```

push only this tag. do not force or replace a published tag. the `v*` push
starts `release.yml`, which rebuilds the tagged tree, signs/notarizes/staples
macos, creates the archives and publishes the github release using
`.github/release_template.md`.

verify the tag run, the macos asset (`waveform-macos-v0.4.0.dmg`), any successful
windows/linux assets (`waveform-windows-v0.4.0.zip` and
`waveform-linux-v0.4.0.tar.gz`), and accurate notes at
[github releases](https://github.com/mollykitten/waveform/releases).
record the tag SHA, run URL, per-platform results, artifact inspection and
remaining manual validation in the release report. a successful dry run alone
is not a published release.
