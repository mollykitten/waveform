# Waveform — инструкции для агентов (Hermes, Codex)

Этот файл — точка входа для Hermes Agent и Codex CLI. Он намеренно короткий.

- **Зачем проект и куда идёт** — `IDEA.md`. Прочитай при первом знакомстве.
- **Полный контракт**: дизайн-система, архитектура, история решений, грабли
  api-v2, бэклог — `CLAUDE.md`. Hermes загружает только один контекстный файл
  (AGENTS.md перекрывает CLAUDE.md), поэтому перед любой нетривиальной
  задачей открой `CLAUDE.md` через `read_file`. Это канонический документ,
  здесь только выжимка.
- **Правила Flutter/Dart** — `.claude/rules/flutter.md` (Hermes его не
  подхватывает сам, читай при работе с `lib/**`). Глобальные грабли Flutter
  у Алины — скилл `alina-flutter-workflow`.
- **Запуск и проверка приложения** — сценарий в
  `.claude/skills/dev-loop/SKILL.md`. Целевая платформа по умолчанию macOS.

## Стек и структура

Flutter (desktop: macOS / Windows / Linux), Riverpod, go_router, dio,
just_audio + audio_service. Feature-first: `lib/features/*`, общее в
`lib/shared/`, API / аудио / кэш / логи в `lib/core/`. UI ходит в сеть только
через интерфейс `SoundcloudApi`; моки живут в `MockSoundcloudApi` под
`--dart-define=MOCK=true` и в тестах, в боевой сборке их нет.

## Инструменты

- Анализ, тесты, запуск, hot reload — через MCP-сервер `dart`
  (`analyze_files`, `run_tests`, `launch_app`, `hot_reload`), а не через
  `terminal` с `flutter run`. Долгоживущее в шелле — только
  `terminal(background=true)`; что запустил — убей и перечисли.
- Поиск по коду точечно: `rg -n 'pattern' lib/ -t dart`, `git grep -n`,
  файлы по имени через `rg --files | rg name`. Без `cat`, `ls -R`, `grep -r`
  по всему репозиторию; это же в бриф каждой делегированной подзадачи.
- Перед пушем: `flutter analyze` без замечаний, `flutter test` зелёный.
  CI закреплён на Flutter 3.41.0.
- Форматирование: `dart format` на изменённых файлах (в Claude Code это
  делает хук, в Hermes — руками).

## Дизайн-контракт (минимум, детали в CLAUDE.md)

Тёмная тема. Акцент `#FF5500` только на активных элементах, lime `#C6FF00`
только для web3-меток. Inter для текста, JetBrains Mono для всех цифр,
тайм-кодов и технических меток через `AppTheme.mono()`. Радиусы 3px,
границы 0.5px. Любое UI-изменение — со скриншотами до/после.

## Как работать

- «Реализуй / почини / поправь» — режим исполнения: короткий список задач и
  код, без брейншторма и спеки. Проектирование — только на явный запрос.
- Баг сначала воспроизведи и покажи наблюдение (лог, скриншот). Контракт
  api-v2 не выводи из соседнего кода — проверь на живом сервисе
  (`dart run tool/live_smoke.dart`).
- Отчёт делегата — заявление, а не доказательство: перед «готово» смотри дифф
  или прогоняй проверку.
- Рискованные зоны: авторизация и токены, `WebviewApiExecutor` и всё вокруг
  DataDome, аудиодвижок (`audio_engine.dart`, crossfade), релизный пайплайн.
  После любой правки там — ревью и личный просмотр диффа.

## Git

- Автор и коммиттер — из локального `.git/config` этого репо, глобальный
  git-конфиг не трогать.
- **Не добавлять** трейлеры `Co-Authored-By` и любые пометки об ИИ-соавторстве:
  GitHub засчитывает их в contributors и искажает статистику мейнтейнера.
- Ничего не пушить, не мержить и не ребейзить без прямой просьбы.
  Релиз — по тегу `v*`, процесс в `CLAUDE.md`.

## Kanban (Hermes)

Проект в Hermes — `waveform` (primary `~/dev/waveform_app`), доска — `waveform`.
Карточки создаются человеком или оркестратором, воркер их только исполняет.

```bash
hermes kanban --board waveform create "<title>" \
  --body-file brief.md --project waveform --branch <type>/<slug> \
  --completion-contract mollykitten/waveform --max-runtime 45m
```

- Воркер получает worktree `.worktrees/<task-id>/` (в `.gitignore`) на ветке
  `--branch`. Перед началом — `git fetch origin` и ветка от `origin/main`:
  основной checkout может отставать.
- Итог карточки с контрактом `mollykitten/waveform` — открытый PR в `main`
  с заголовком в Conventional Commits. Ссылку на PR положи в комментарий
  карточки и в `kanban_complete(metadata={"published_pr": "<url>"})`.
  Карточка закроется только когда required-чек `Analyze + test` на PR
  зелёный; красный или ещё идущий CI = `kanban_block` с причиной, не
  повторная попытка.
- Мержить PR, пушить в `main`, менять ветку чужой карточки — нельзя.
- Карточки без PR (исследование, аудит) — `--completion-contract local-only`
  и отчёт в `result`.

## Не делать

- Не скрейпить cookies и сессии из чужих браузеров: антибот-cookie только из
  собственного WebView приложения.
- Не добавлять абьюз сервиса (массовый скрейпинг, обход банов и GO+).
- Не хардкодить и не коммитить секреты: `client_id` скрейпится на лету,
  Last.fm-ключи только через `--dart-define`.
- Не пускать мок-данные и подставные секции в боевой UI.
