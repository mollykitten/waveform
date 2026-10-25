---
name: dev-loop
description: Use when making a change to Dart code in this repo that needs to be seen working — run the app, hot reload, read runtime errors, analyze and test through the Dart MCP server instead of shell commands and eyeballing the terminal.
---

# Dev loop (Dart MCP)

Цикл проверки изменений через инструменты `plugin:dart-flutter:dart-mcp-server`.
Смысл: агент читает структурированный результат, а не гадает по stdout.
Waveform — чисто desktop-приложение без нативных расширений (нет
Network Extension/appex, нет платформенных плагинов с ручным нативным кодом),
поэтому hot reload/hot restart покрывают почти весь цикл разработки.

## 0. Приложение уже запущено?

`list_running_apps`. Если да — переходи к шагу 2, не поднимай второй инстанс.

## 1. Запуск

`list_devices` → `launch_app` с нужным устройством.

Целевая платформа по умолчанию в этом репозитории: **macOS** — основная
платформа разработки и единственная, где сейчас работает webview-логин со
скрытым окном (`third_party/desktop_webview_window`, macOS-only патч).
Windows/Linux — вторичные, проверяются руками при изменениях, специфичных
для платформы.

Запускать из корня репозитория. В проекте нет кодогенерации (`build_runner`)
и нет git submodule — перед запуском делать ничего не нужно, только
`flutter pub get`, если менялся `pubspec.yaml`. По умолчанию клиент идёт в
живой api-v2 (client_id скрейпится на лету, без ключей).

**`launch_app` не умеет `--dart-define`** — у него есть только `root`, `device`
и `target`. Если нужны define'ы (моки — `--dart-define=MOCK=true`; Last.fm
scrobbling без `--dart-define=LASTFM_API_KEY=…` и `LASTFM_SHARED_SECRET=…` тихо
no-op'ит, это нормальное состояние — не придумывай и не ищи эти значения),
поднимай приложение из терминала и подключайся к нему:

```bash
flutter run -d macos --dart-define=MOCK=true --print-dtd
```

`--print-dtd` напечатает адрес вида `ws://127.0.0.1:PORT/TOKEN` — передай его в
`connect_dart_tooling_daemon`, дальше `hot_reload`, `get_runtime_errors` и
остальные инструменты работают как обычно. `list_running_apps` показывает только
то, что поднял сам `launch_app`, — внешний запуск туда не попадёт.

## 2. Правка → перезагрузка

После правки `.dart` под `lib/`:

* `hot_reload` — UI, тела `build()`, простые методы.
* `hot_restart` — `main()`, `initState`, глобальное/статическое состояние,
  регистрация провайдеров, а также правки `AudioEngine`/`PlayerController`
  (держат живые `AudioPlayer`-инстансы и broadcast-стримы — hot reload может
  оставить их в неконсистентном состоянии) и правки инициализации
  `window_manager`/`app_links` в `main.dart`.
* Ничего не перезагружать при правке только комментариев или файлов вне
  `lib/`.

## 3. Что смотреть после перезагрузки

* `get_runtime_errors` — исключения, ошибки layout, ассерты фреймворка.
* `get_app_logs` — логи приложения (Talker).
* `get_widget_tree` — когда нужно понять, что реально построилось.
* `set_widget_selection_mode` + `get_selected_widget` — когда пользователь
  показывает на элемент в работающем приложении.

## 3.5. Прогнать сценарий руками агента (`flutter_driver`)

Это desktop-приложение без нативных расширений, поэтому сценарий целиком
проходится инструментом `flutter_driver` — не надо просить пользователя
«потыкать».

Порядок обязательный: сначала `get_widget_tree`, чтобы увидеть реальные тексты,
тултипы, `Key` и типы виджетов. Селекторы **не угадывать** — брать из дерева.
Дальше `flutter_driver` с нужной командой: `tap`, `enter_text`, `scroll`,
`scrollIntoView`, `waitFor` / `waitForAbsent` / `waitForTappable`, `get_text`,
`screenshot`. Finder задаётся через `finderType` (`ByValueKey`, `ByText`,
`ByTooltipMessage`, `BySemanticsLabel`, `ByType`).

Типичный прогон здесь: найти трек в списке → `tap` по нему → `waitFor`
плеерной панели → `get_text` с тайтла, чтобы убедиться, что играет именно он.

Если сценарий стоит закрепить навсегда — переводи его в постоянный тест скиллом
`flutter-add-integration-test` (он есть в плагине dart-flutter). Учти, что
`integration_test` в этом репозитории ещё не заведён: скилл добавит и зависимость,
и директорию, а CI его гонять не будет, пока не допишешь шаг в `ci.yml`.

## 4. Перед тем как сказать «готово»

1. `analyze_files` — должно быть чисто (info допустимы, warnings и errors нет).
2. `dart_format` по изменённым файлам.
3. `run_tests` — весь `test/` (юнит-тесты на audio engine/player/API DTO,
   widget-тесты на shortcuts/навигацию; `integration_test` в репозитории нет).

Это ровно то, что гоняет CI (`.github/workflows/ci.yml`: `flutter analyze` +
`flutter test` на Flutter 3.41.0) — больше CI ничего не проверяет. Отдельного
шага форматирования в CI нет, сборки (macOS/Windows/Linux, `release.yml`)
в этот цикл не входят и руками их гонять перед «готово» не обязательно.

Не заявляй, что что-то работает, пока не увидел результат этих вызовов.

## Границы

Чего этот цикл НЕ покрывает:

* **OS-интеграции мимо hot reload**: заголовок/размер окна
  (`window_manager`), медиа-клавиши и Now Playing в Control Center/lockscreen
  через `audio_service`, deep links `waveform://` (на macOS зарегистрирована
  через Info.plist; на Windows/Linux схема вообще не зарегистрирована) —
  нужен полный релонч собранного приложения, не hot restart.
* **Платформо-специфичное поведение Windows/Linux** — цикл выше гоняется на
  macOS; поведение, завязанное на Windows (webview-логин через
  `desktop_webview_window`/WebView2 — известно тормозит, см. бэклог в
  `CLAUDE.md`) или Linux, нужно проверять на соответствующей ОС отдельно.
* **Живые сетевые сценарии с SoundCloud**: client_id-скрейп, OAuth webview
  login, HLS-стриминг и запись лайков/репостов ходят в реальный api-v2 (моков
  по умолчанию нет) — сеть может быть недоступна или SoundCloud может менять
  поведение API вне контроля этого репозитория; такие расхождения не бага
  дев-лупа.
* **macOS code signing / notarization / .dmg-сборка** — это `release.yml`
  (CI), не dev loop.
