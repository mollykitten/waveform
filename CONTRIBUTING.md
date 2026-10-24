# Contributing to Waveform

Thanks for your interest! Waveform is an **early work-in-progress**, so things
move and break. Issues, ideas, and PRs are all welcome — but please read this
first.

## Before you start

- **License.** Waveform is MIT-licensed (see [`LICENSE`](LICENSE)). By
  submitting a contribution, you agree that it is licensed under the same terms.
- **This is an unofficial client** built on SoundCloud's undocumented `api-v2`,
  which may conflict with their Terms of Service. Contributions must not add
  features designed to abuse the service (mass scraping, ban evasion, etc.).
- For anything non-trivial, **open an issue first** so we can agree on the
  approach before you write code.

## Development setup

Prerequisites: a recent [Flutter](https://docs.flutter.dev/get-started/install)
SDK with desktop support enabled.

```bash
flutter pub get
flutter run -d macos                      # or -d windows / -d linux
flutter run -d macos --dart-define=MOCK=true   # offline, mock data, no login
```

Before pushing:

```bash
flutter analyze   # must report "No issues found"
flutter test      # must pass
```

## Architecture & conventions

- **Feature-first** layout under `lib/features/`; shared models/widgets in
  `lib/shared/`; API / audio / cache / logging in `lib/core/`.
- **State:** Riverpod. **Navigation:** go_router. **HTTP:** dio.
- Data flows through the `SoundcloudApi` interface — UI never talks to the
  network directly. Mocks live only in `MockSoundcloudApi` (behind
  `--dart-define=MOCK=true`); never let mock data reach the live app.
- The internal `client_id` is **scraped at runtime** and user tokens live in
  `flutter_secure_storage` — **never hardcode or commit secrets.**

## Design contract

UI changes must follow the design contract documented in
[`CLAUDE.md`](CLAUDE.md):

- Dark theme, minimalism with light web3 accents; brutalist 3px radii, 0.5px borders.
- **Inter** for text/headings, **JetBrains Mono** for every number, timecode,
  and technical label (use the `AppTheme.mono()` helper).
- Acid orange (`#FF5500`) only for active elements; lime (`#C6FF00`) only for
  web3 markers.

Include before/after screenshots for any UI change.

## Commits & PRs

- Keep each PR focused on one logical change.
- Write clear commit messages (imperative mood: "Add …", "Fix …").
- Fill in the PR template checklist. PRs should pass `flutter analyze` and
  `flutter test`.

## Conduct

Be respectful and constructive. Harassment or hostile behavior isn't welcome
here. (A formal Code of Conduct may be added later.)
