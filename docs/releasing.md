# cutting a release

the next release is `v0.4.0`; `pubspec.yaml` is already `0.4.0+33`.
release the reviewed main tree after #56 without adding backlog features.
keep the changelog's `unreleased` status until publication is ready.

## one-time setup

1. an active apple developer membership, all required agreements accepted, and
   a `Developer ID Application` certificate exported as a password-protected
   `.p12`.
2. github actions secrets in settings → secrets and variables → actions:
   - `APPLE_TEAM_ID`: the apple team id.
   - `APPLE_CERT_P12_BASE64`: base64-encoded `.p12`.
   - `APPLE_CERT_PASSWORD`: the `.p12` password.
   - `APPLE_ID`: apple id email.
   - `APPLE_APP_PASSWORD`: app-specific password for notarization.
   - `KEYCHAIN_PASSWORD`: password for the temporary CI keychain.
3. optional last.fm credentials: `LASTFM_API_KEY` and `LASTFM_SHARED_SECRET`.
   the workflow passes them through `--dart-define`. they are compiled into
   the binary; keeping them out of git does not make a client binary a secret
   store. never commit credential values.

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
   python3 -m unittest discover -s test -p worker_notifier_test.py
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
   DMG creation and upload. record windows and linux results separately:
   they are best effort, and notes must only claim assets that actually exist.
   confirm the publish job is **skipped**: `workflow_dispatch` on a branch
   builds artifacts but its non-tag ref cannot publish a release.
5. download and inspect the packaged artifacts. check macos installation and
   launch on a clean system, including `codesign --verify --strict --deep`,
   `xcrun stapler validate` and gatekeeper assessment
   (`spctl --assess --type execute --verbose`), each against the downloaded app.
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
attempt. this observation does not establish missing secrets or a workflow
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
