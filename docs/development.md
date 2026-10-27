# development

## stack

flutter + dart 3.11. `flutter_riverpod` for state, `go_router` for navigation, `just_audio` for playback, `audio_service` for os media controls, `dio` for http, `path_provider` for token and cache paths, `cached_network_image`, `google_fonts`, `talker_flutter` for logs, `window_manager` for the title and traffic lights

```
lib/
├── app/        # theme, router, shell, global shortcuts
├── core/
│   ├── api/    # soundcloud api-v2 client, dtos, mappers, auth, liked tracks
│   ├── audio/  # two-engine just_audio wrapper behind an interface
│   ├── cache/  # image cache (json, no sqflite on desktop)
│   ├── lastfm/ # auth + scrobbler
│   ├── log/    # talker
│   └── storage/# file-based token + prefs
├── features/   # auth, home, feed, library, search, track, artist, playlist, player, queue, stats, settings, omnibox, debug
└── shared/     # models, widgets, intents, formatting
```

## run it yourself

you need a recent [flutter](https://docs.flutter.dev/get-started/install) sdk with desktop enabled

linux builds also need the gtk, webkit2gtk and libsoup development packages listed in [the release workflow](../.github/workflows/release.yml)

```bash
flutter pub get
flutter run -d macos      # or -d windows / -d linux
```

offline with mock data, no login:

```bash
flutter run -d macos --dart-define=MOCK=true
```

tests and analysis:

```bash
flutter test
flutter analyze
```

contributing rules: [`CONTRIBUTING.md`](../CONTRIBUTING.md). releases: [releasing](releasing.md)
