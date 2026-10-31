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

## Where to start

- Issues labeled [`good first issue`](https://github.com/mollykitten/waveform/labels/good%20first%20issue)
  need little knowledge of the codebase. Many are hands-on checks on windows
  or linux, where we have no machines to test on.
- [`help wanted`](https://github.com/mollykitten/waveform/labels/help%20wanted)
  marks bigger pieces we'd love help with, like media keys on windows and
  linux or a light theme.
- Questions, ideas and show-and-tell go to
  [Discussions](https://github.com/mollykitten/waveform/discussions).

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
- The internal `client_id` is **scraped at runtime** and user tokens live in a file
  (`lib/core/storage/token_store.dart`) — **never hardcode or commit secrets.**

## Design contract

UI changes must follow the design contract:

- Dark, quiet minimalism close to canonical soundcloud; brutalist 3px radii,
  0.5px borders.
- Palette lives in `lib/app/theme/colors.dart`: bg `#0A0A0A`, surface
  `#111111`, surface2 `#1A1A1A`, border `#2A2A2A`, text `#F5F5F5` / `#888888`
  / `#555555`.
- **Inter** for text/headings, **JetBrains Mono** for every number, timecode,
  and technical label (use the `AppTheme.mono()` helper).
- Acid orange (`#FF5500`) only for active elements; lime (`#C6FF00`) only for
  small labels and markers.

Include before/after screenshots for any UI change.

## Commits & PRs

- Keep each PR focused on one logical change.
- Use [conventional commits](https://www.conventionalcommits.org/) in
  lowercase, imperative mood: `fix(player): commit one seek on drag release`.
  The same style goes for PR titles.
- Fill in the PR template checklist. PRs should pass `flutter analyze` and
  `flutter test`.

## Conduct

Be respectful and constructive. Harassment or hostile behavior isn't welcome
here. (A formal Code of Conduct may be added later.)
