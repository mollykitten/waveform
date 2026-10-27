# Waveform — minimal SoundCloud client

## Что это
Кроссплатформенный десктопный SoundCloud-клиент на Flutter для macOS, Windows, Linux.
Эстетика: минимализм, ближе к каноничному SoundCloud, но темнее и тише.

## Дизайн-контракт

**Тема:** тёмная по умолчанию (светлую добавим позже).

**Палитра:**
- bg `#0A0A0A`, surface `#111111`, surface2 `#1A1A1A`
- border `#2A2A2A`, borderDim `#1A1A1A`, waveDim `#3A3A3A`
- textHi `#F5F5F5`, textMid `#888888`, textLow `#555555`
- acid `#FF5500` (SoundCloud orange — только активные элементы)
- lime `#C6FF00` (второй акцент: метки и маркеры)

**Типографика:**
- Inter — основной текст, заголовки
- JetBrains Mono — все числа, тайм-коды, технические метки

**Структура канона SoundCloud:**
- Обложка трека 160×160 слева
- Waveform во всю ширину карточки справа от обложки
- Метаданные (лайки, репосты, длительность) снизу моно-шрифтом
- Активный (играющий) waveform — оранжевые бары для прослушанной части, `waveDim` для непрослушанной
- Радиусы 3px (брутальные углы), borders 0.5px

**Лого:** 5 вертикальных оранжевых баров разной высоты (стилизованная waveform).
Геометрия = `WaveLogo`. В иконке приложения первые 3 бара acid, последние 2 waveDim
(«прослушано наполовину»). Все PNG (иконка, фавиконки, OG, фон DMG) генерит
`python3 tool/brand/make_icons.py` → `assets/brand/`, `assets/icon/icon.png`,
`site/assets/`; потом `dart run flutter_launcher_icons`. SVG-лого — `assets/brand/`.
Лендинг — статический `site/index.html` без сборки.

## Стек

```yaml
dependencies:
  flutter_riverpod: ^2.5.1
  go_router: ^14.2.0
  google_fonts: ^6.2.1
  just_audio: ^0.9.39
  audio_service: ^0.18.13
  cached_network_image: ^3.3.1
  dio: ^5.4.3
  path_provider: ^2.1.5
```

## Структура

```
lib/
├── main.dart
├── app/
│   ├── app.dart
│   ├── theme/{colors.dart, app_theme.dart}
│   └── router.dart
├── core/
│   ├── api/        # SoundCloud client, OAuth 2.1 + PKCE
│   ├── audio/      # just_audio + audio_service
│   └── storage/    # file-based token store (path_provider, sandboxed)
├── features/
│   ├── auth/
│   ├── home/       # stream/feed
│   ├── search/
│   ├── track/
│   ├── library/
│   └── player/     # mini + full
└── shared/widgets/ # переиспользуемые компоненты
```

## Реальность API
- Регистрация SoundCloud API требует подписки Artist Pro
- OAuth 2.1 с обязательным PKCE
- Стримы отдаются как HLS — `just_audio` поддерживает
- На время разработки используем моки

## Дорожная карта
1. ✅ Дизайн-направление и название
2. ✅ Дизайн-система в Dart (colors, theme, mono helper, токены отступов)
3. ✅ Экраны на моках: shell с навигацией Home/Feed/Library, TopBar + BottomPlayer (persistent), CustomPainter waveform, карусели подборок, правый рейл
   - Home: from your stream + карусели (more/recently/mixed/albums/stations/liked by/made for you/new crew)
   - Feed: лента waveform-постов с баром действий
   - Library: вкладки overview/likes/playlists/albums/stations/following/history
   - Плеер: shuffle/prev/play/next/repeat, like, скраб по waveform (мок-тикер)
   - Экран трека (/track/:id): hero + waveform с маркерами комментариев, комментарии с таймкодами, related tracks
   - Экран артиста (/artist/:handle): шапка (аватар + моно-счётчики + follow), вкладки, popular tracks + albums/playlists
   - Apple-touch: Pressable (spring press), frosted chrome (BackdropFilter TopBar/Player, контент скроллится под баром), мягкие переходы экранов
4. ✅ Аудио-плеер:
   - ✅ just_audio: реальное воспроизведение HLS (lib/core/audio/audio_engine.dart за провайдером, PlayerController резолвит transcoding→m3u8 и играет; мок-тикер убран)
   - ✅ audio_service: медиа-контролы ОС (now-playing, медиа-клавиши) — пока только macOS: в pubspec только `audio_service`, бэкендов MPRIS/SMTC нет
5. 🔄 Замена моков на реальный API:
   - ✅ api-v2 живой по умолчанию (client_id-скрейп + DTO + мапперы); моки только под `--dart-define=MOCK=true`/тесты
   - ✅ Логин per-user через WebView (oauth_token), персональные ручки и рейл под auth-гейтом
   - ⏳ Официальный OAuth 2.1 + PKCE (если откроют регистрацию)
6. ✅ Поиск: экран `/search?q=` с вкладками tracks/people/playlists (search/tracks|users|playlists), поле в шапке submit→навигация

### Путь развития (с 2026-10)
**Горизонт 0 — выпустить то, что есть.** Код на 0.4.0 (следующий тег — `v0.4.0`), опубликованных релизов пока нет.
Сухой прогон [40156324361](https://github.com/mollykitten/waveform/actions/runs/40156324361)
от 2026-10-25 на SHA `4e4f87463f77f7e077724a1d73ffd7be9836edcc`: macOS собрался
и подписался; notarization вернул HTTP 403 — обязательное соглашение Apple
не подписано или истекло. Staple и DMG пропущены, Windows и Linux прошли.
Это старый SHA: он не подтверждает сборку текущего main после #56. Нужно
урегулировать соглашение Apple, прогнать финальный main без тега и проверить
артефакты/нотаризацию на чистой macOS; процесс — [docs/releasing.md](docs/releasing.md).
До публикации текущего кода новые фичи не берём.

**Горизонт 1 — платформенный паритет** (тезис «кроссплатформенность как условие»):
- медиа-клавиши и now-playing на Windows (SMTC) и Linux (MPRIS) — сейчас только macOS;
- нормальный логин на Windows (сейчас ручная вставка oauth_token);
- deep-link `waveform://` на Windows/Linux;
- Windows code-signing.

**Горизонт 2 — фичи, по одной на релиз** (порядок — ценность к усилию):
1. Shuffle всех лайков — реализовано (`loadAll()` и shuffle полной коллекции).
2. Light theme + следование системному appearance.
3. Reduced-motion и клавиатурная навигация — реализованы; полный VoiceOver-проход впереди.
4. Heatmap прослушиваний 7×24.
5. Lyrics — последним: у SoundCloud нет эндпоинта, нужен сторонний источник.

**Рекомендации и источники кандидатов (статус 2026-10-27).** В исходном коде
реализованы рекомендации по реальным трекам SoundCloud, визуальная «Моя волна»
(одна кнопка, без настроек), непрерывное пополнение очереди и локальные
структурные векторы по ограниченному related-графу (до 6 seed-интересов × 12
соседей) с локальными фактами прослушивания, дизлайком и seen-памятью. LLM-слой
(ChatGPT-подключение, custom providers, поле настроения, согласие на отправку
метаданных) удалён по итогам пилотов ниже. Векторы — не нейронные
аудиоэмбеддинги и не глобальный каталог. Качество рекомендаций и нативный
playback/refill ещё требуют проверки; тесты не доказывают эти сценарии.

Офлайн-пилоты 2026-10-27 на публичных лайках четырёх пользователей (тест — 100
новых лайков каждого) решили развилку: аудио-эмбеддинги как профиль вкуса (CLAP)
не лучше случайного — **no-go**, бэкенд с векторным индексом ради них не строим.
Related-граф точен там, куда достаёт, но достаёт 14 / 7 / 25 / 17 из 100 новых
лайков; co-likers CF (лайкеры сидов → соседи с ≥2 общими сидами → их свежие лайки)
достаёт 44 / 52 / 76 / 39 и почти включает граф, но в топ-50 собственного списка
ранжирует не лучше графа. 16–30% CF-кандидатов не играются. Около половины новых
лайков владельца недостижимы ни графом, ни CF; ближайший незадействованный
источник — домашний стрим под oauth. Model-assisted маршрут (модель планирует
поиск → `search/tracks` → модель ранжирует), воспроизведённый с промптами
приложения на локальной Qwen3-1.7B, достал 0 из 100 новых лайков у всех; потолок
самого поискового канала без модели — 3 / 9 / 13 / 3, ниже графа у трёх из
четырёх и ниже CF у всех, так что вывод от размера модели не зависит. Модель
как источник рекомендаций не нужна, весь LLM-слой убран. Побочный дефект
пилота — `mappers.dart` подставлял жанр `electronic` при пустом, и он попадал в
промпт как настоящий — исправлен (пустой жанр больше не подменяется), самого
промпта уже нет.
Офлайн-оценка на лайках исчерпана.

Статус: этапы 1–2 ниже уже в коде (не выпущены) — CF, домашний стрим, фильтр
проигрываемости и поле `source` в фактах; сравнение источников на живых сессиях
ещё впереди. План после v0.4.0 (горизонт 0 — сначала релиз): CF и домашний стрим как
дополнительные источники кандидатов рядом с графом фоновой задачей с кэшем
(≈350 запросов и 3–4 мин на пользователя); фильтр проигрываемости; ранжирование
CF по весу соседа и давности его лайка, без фиксированной склейки 0.5; локальная
телеметрия лайк/скип по источнику для сравнения на живых сессиях. Бэкенд — только
если бюджет запросов на клиенте не выдержит, с прежними требованиями: изоляция
аккаунтов, удаление, отдельное согласие на sync, локальный fallback, пороги
качества, latency и стоимости, наблюдаемость и rollback. Полный статус и этапы —
[docs/roadmap.md](docs/roadmap.md); детали реализованного core и сводка пилотов —
[docs/my-wave.md](docs/my-wave.md).

**Не планируем:** web3 (снят решением владельца 2026-10); «когда откроют API» —
не в нашей власти.

Сделано вне нумерации: экран плейлиста `/playlist/:id` (карусели главной ведут на него), громкость в плеере, логи Talker.
- **Shuffle all likes.** Кнопка в library/likes догружает страницы лайков через
  `loadAll()`, перемешивает полную коллекцию и запускает её с shuffle.
- **Правый рейл переосмыслен (UX):** убрана подставная секция «artists you should follow»
  и фейковая карточка-счётчик. Вместо них — профиль-карточка (тап → свой
  `/artist`, лёгкий ◆ lime-акцент), три тайла-шортката с реальными счётчиками
  (likes/playlists/following → `/library?tab=…`), превью последних лайков (`see all` →
  likes) и история. Только реальные данные.
- **Liked-state.** `likedTracksProvider` (множество ID лайков из `/users/{id}/track_likes`)
  — единый источник подсветки «liked» в списках (`TrackRow` сердечко) и в плеере. Плеер
  ставит `liked` из множества при `play`, `toggleLike` пишет в API (PUT/DELETE
  `/users/{me}/track_likes/{id}`) оптимистично с откатом. NB: write-эндпоинт не проверен
  на живом аккаунте — при провале деградирует до session-local + лог.
- **Progressive-фолбэк стрима.** `Track.streamCandidates` несёт все
  транскодинги (HLS → progressive); плеер перебирает их, пока один не
  заиграет. Зашифрованные (`cbc-/ctr-encrypted-hls`) транскодинги из
  обычных кандидатов отсеиваются (just_audio их не играет). Любая неудачная
  загрузка триггерит видимое уведомление (AppShell `ref.listen`), не silent
  skip. Бейджа `🔒 GO+` нет: такие треки в UI ничем не выделяются.
- **GO+ через DRM (решение владельца 2026-10, правило переписано).** Играть
  GO+ (`ctr-encrypted-hls`, Widevine CENC) — допустимо. Go-ядро
  `third_party/scdrm` → `libscdrm.dylib` по `dart:ffi`
  (`lib/core/drm/`), фолбэк после обычных кандидатов: лицензия → расшифровка
  → mp3 в кэш. Только macOS. Профиль устройства `assets/widevine/device.wvd`
  пользователь кладёт сам; **в git и в релизные сборки он не попадает
  никогда** (в `.gitignore`, CI его не имеет). Без профиля DRM выключен и
  трек — общий «unavailable — skipped».
- **Tiles ↔ list переключатель.** `viewModeProvider` + `ViewToggle` + новый
  `CollectionRow` — в library + search/playlists. Персистится в `prefs.json`.
- **Экран /settings.** Account (avatar + sign in/out), view (тогл), cache
  (clear cover cache), logs (→ /logs), about (version + GitHub-link). Иконка-
  шестерёнка в TopBar.
- **Shuffle всей коллекции на плейлисте.** `SoundcloudApi.allPlaylistTracks(id)`
  гидрит весь сет (батчи `/tracks?ids=…`); кнопка «shuffle all» рядом с «play».
- **Track-page actions wired.** Like / repost (новый `repostedTracksProvider`,
  PUT/DELETE `/users/{me}/track_reposts/{id}`) / share (copy permalink) / more
  (popup: copy / open on SoundCloud).
- **File-based token persistence.** `lib/core/storage/token_store.dart` +
  `prefs_store.dart` в `getApplicationSupportDirectory()` (вместо
  `flutter_secure_storage`, который без development-team signing на macOS
  ломал сборку и/или не персистил).

### v0.1.0 demo-релизный заход (7 фаз)
- **Phase 0 — CI/CD.** `.github/workflows/{ci,release,build}.yml` +
  `dependabot.yml` + `release_template.md`. CI: analyze+test на каждый
  push/PR (pinned Flutter 3.41.0 — match local; иначе onReorder
  deprecation warn на свежем stable). Release: на `v*` тег — 3 OS
  параллельно, macOS sign (Developer ID Application) + notarize
  (`xcrun notarytool`, ключ API) + staple + `.dmg`. Required secrets:
  APPLE_CERT_P12_BASE64, APPLE_CERT_PASSWORD, KEYCHAIN_PASSWORD,
  APPLE_API_KEY_P8_BASE64, APPLE_API_KEY_ID, APPLE_API_ISSUER_ID
  (нотаризация по ключу App Store Connect API; см. docs/releasing.md).
- **Phase 1 — Visual.** Hero cover→detail (`Hero(tag: 'cover-track-{id}'
  / 'cover-playlist-{id}')`, `CachedNetworkImage.fadeInDuration: zero`
  чтобы не конкурировать с Hero). `EmptyState` (icon+title+sub+CTA)
  вместо пустых сеток. `SkeletonBox` + `AsyncView.skeleton` —
  `_HomeSkeleton` на первом пейнте Home. Optimistic +/-1 на лайке/репосте
  (`_likesDelta`/`_repostsDelta` в `_ActionBar`). Volume scroll-wheel
  + tooltip с `xx%`. Buffered третий тиер на waveform
  (`AudioEngine.bufferedPositionStream` → `PlayerState.buffered` →
  `WaveformView.buffered`).
- **Phase 2 — Omnibox + shortcuts + right-click.** ⌘K-палитра по
  центру экрана (Raycast/Spotlight) поверх полноэкранного
  `BackdropFilter.blur(18)` + dim. TopBar-поле — триггер-кнопка с
  ⌘K-чипом, показывает `controller.text` или `playing: artist — title`.
  `omniboxOpenProvider` (Notifier<bool>) — источник правды; модалка
  использует `FocusScope(autofocus: true, onKeyEvent: Esc)` —
  `KeyboardListener` крал фокус. Глобальные shortcuts (Shortcuts +
  Actions в AppShell): Space play/pause, ←/→ prev/next, ↑/↓ volume
  ±0.05, ⌘K/⌘F omnibox, ⌘L likes, ⌘, settings, ⌘+Shift+L logs.
  Внешний `Focus(canRequestFocus: false, onKeyEvent: handled)`
  глотает unmatched keys чтобы macOS NSBeep не дзынькал. Right-click
  context menu на `TrackRow` через `Listener(onPointerDown:
  kSecondaryButton)` — НЕ через `GestureDetector.onSecondaryTapDown`,
  тот конкурирует в gesture arena с вложенным Pressable. Меню: play /
  add to queue / like / repost / copy link / open on SC / open artist /
  open track page.
- **Phase 3 — Queue + collapse + ambient.** Публичный queue API в
  `PlayerController` (`upcomingTracks` getter, `currentQueueIndex`,
  `reorderUpcoming(old, new)`, `removeFromQueue(id)`, `addToQueue(t)`)
  + `queueVersion: int` в `PlayerState` (bump на каждую мутацию, чтобы
  UI re-derived). Floating queue-панель справа
  (`lib/features/queue/queue_panel.dart`, ReorderableListView,
  toggleable через `queueVisibleProvider`). BottomPlayer collapse
  (`playerCollapsedProvider`, 44px-бар с cover+ticker+play/next).
  Ambient cover backdrop — full window width, blur 80, dim 0.55,
  градиент в bg к низу. Полноэкранный page-level Stack в
  `track_screen.dart` и `playlist_screen.dart` (вне ConstrainedBox(940)
  — иначе ambient был бы только в центральной колонке).
  `palette_generator` выпилен (был слишком слабый — gradient почти не
  видно).
- **Phase 4 — Audio: gapless + crossfade + OS keys.** AudioEngine
  refactored на 2 `AudioPlayer` (`_a`, `_b`) + `_active` pointer;
  streams через broadcast-controller'ы, привязка пере-binds на swap'е
  (downstream listener'у не надо пересоздавать подписки). Новые методы
  `preloadNext(url)` (setUrl на inactive, volume 0) + `swapToNext({
  crossfade})` (50ms-step ramp обоих movements за crossfade duration,
  иначе мгновенный swap). `PlayerController._load` после успеха
  фоном `unawaited(_preloadAfter(track))` резолвит и preload'ит
  следующий; на `completedStream` если `engine.hasPreload` →
  `_advanceViaSwap` (swapToNext + `state.copyWith` нового трека +
  preload after). Skip-storm guard остаётся. `playbackPrefsProvider`
  (`crossfadeMs` 0–6000, persists в `prefs.json`). Settings: section
  «playback» со слайдером. **OS media keys + now-playing** через
  `audio_service` (`audio_service: ^0.18.18`):
  `WaveformAudioHandler extends BaseAudioHandler`; main создаёт
  handler ДО ProviderContainer'а (`setAudioHandlerSingleton(h)`,
  потом `handler.container = container`), `audioHandlerProvider`
  отдаёт singleton. PlayerController `ref.listenSelf((_, next) =>
  ref.read(audioHandlerProvider).sync(next))` — handler пушит
  `mediaItem` + `playbackState` в OS. macOS Control Center, lockscreen,
  ▶︎❘❘/⏮/⏭ медиа-клавиши.
- **Phase 5 — Last.fm.** `lib/core/lastfm/{constants,client,session,
  scrobbler}.dart`. `lastfmApiKey` + `lastfmSharedSecret` в
  `lastfm_constants.dart` (пустые → весь subsystem cleanly no-op'ит
  через `lastfmConfigured` getter). Client: `auth.getToken` (anon),
  `auth.getSession` / `track.updateNowPlaying` / `track.scrobble`
  (POST с md5-sig, params отсортированы + `secret`). `LastfmSession`
  persisted в `prefs.json` (`lastfm_session_key`,
  `lastfm_username`). `LastfmScrobbler` подписан на
  `playerControllerProvider` через `Ref.listen`: now-playing после
  ≥3s играния (skip-storm filter), scrobble на ≥50% ИЛИ ≥4 мин.
  Bootstrap: `ref.watch(lastfmScrobblerProvider)` в AppShell.
  Settings: section «last.fm» с connect-flow (getToken →
  openExternalUrl → continue dialog → getSession → save).
- **Phase 6 — Local stats.** `SoundcloudApi.historyPage({limit,
  offset})` (paginates `/me/play-history/tracks`). `statsProvider`
  тянет до 8 страниц × 50 (= 400 records), агрегирует:
  `totalPlays`, `uniqueTracks`, `uniqueArtists`, `totalListened
  Duration`, `topArtists [{name,count}]`, `topGenres [{genre,count}]`.
  `/stats` экран: 3 hero-тайла (plays/artists/hours, mono large) +
  top 10 артистов с progress-bar'ами (LinearProgressIndicator
  scaled by count) + top genres pills. Empty state на anon / fresh
  account. Right rail: «view listening stats →» CTA под профильной
  карточкой (только authed).
- **Phase 7 — Packaging.** `CHANGELOG.md` (Keep-a-Changelog) +
  расширенный README "What works today" + Install (signed DMG,
  Windows zip, Linux tar.gz). `pubspec.yaml`: `version: 0.1.0+1`.
  `_kAppVersion = '0.1.0'`.

### UX-полировка после демо-цикла (центральная палитра + cover-фон)
- **⌘K-палитра по центру.** Раньше была anchored под TopBar; теперь
  полноэкранный overlay поверх `BackdropFilter.blur(18)` + dim(0.45).
  Modal: scale+fade 200ms easeOutCubic, Esc/click-вне закрывают,
  shared `omniboxControllerProvider` переживает закрытие (повторное
  ⌘K возвращает к тому же тексту). Sections: actions / from soundcloud
  (top 3 tracks + 2 playlists + 2 artists из `searchProvider(q)`) /
  recent. TopBar — триггер-кнопка (`_SearchField` теперь Text-based).
- **Cover-blur ambient.** `AmbientBackdrop` self-contained виджет
  (без child) рендерится в Stack page-level (`track_screen.dart` /
  `playlist_screen.dart`) как `Positioned(top:0, left:0, right:0)`.
  Покрывает всю ширину окна, blur 80, dim 0.55, gradient в bg к низу.
- **TopBar полнее.** `AppTheme.topBarHeight: 56 → 76` (28px на
  macOS traffic-lights overlay + 48px контент). `leftPad: 80 → 16`,
  `topPad: 28` — убран странный macOS gap. _SearchField — Text-based
  trigger (controller.text или playing).
- **Volume через ↑/↓.** `VolumeUp/DownIntent` ±0.05 clamped. В
  TextField'ах стрелки нормально работают для каретки (Shortcuts
  пропускает после TextField-consumption).
- **macOS NSBeep silenced.** Внешний `Focus(canRequestFocus: false,
  onKeyEvent: handled)` глотает unhandled keys — fix "каждое
  нажатие = звон".
- **Right-click на TrackRow.** `GestureDetector.onSecondaryTapDown`
  конкурировал в gesture arena с вложенным Pressable. Заменено на
  `Listener(onPointerDown: kSecondaryButton check)` — не лезет в
  арену, primary-тап остаётся, two-finger-tap ловится.
- **Pressable hover вырезан.** Рисовал квадратный halo вокруг
  круглых аватарок / icon-кнопок. Параметр `hoverFill` остался как
  `@Deprecated` no-op.
- **Динамический window title.** `window_manager: ^0.5.x`. main
  `waitUntilReadyToShow(WindowOptions(title, minimumSize: 960×640,
  titleBarStyle: hidden), …)` → setTitle/show/focus. AppShell
  `ref.listen<Track?>` → `windowManager.setTitle('Waveform · artist
  — title')` (или просто 'Waveform' когда нет трека). Try/catch +
  Talker.warning.
- **flutter_launcher_icons.** dev-dep + inline config в pubspec.
  Источник: `assets/icon/icon.png` (квадратный 1024×1024).
  `dart run flutter_launcher_icons` → macOS .icns + Windows .ico.

### Pre-release дел user'у
1. **Apple-подготовка**: секреты перечислены выше (Phase 0). В сухом
   прогоне 2026-10-25 импорт сертификата и подпись прошли; текущий
   наблюдавшийся блокер — обязательное соглашение Apple, HTTP 403 при
   notarization. Нужен успешный прогон финального main после его принятия.
2. **Last.fm** (опционально): зарегистрировать Waveform на
   last.fm/api/account/create → положить `LASTFM_API_KEY` и
   `LASTFM_SHARED_SECRET` ещё двумя GitHub Actions secrets (рядом
   с APPLE_*). Они прокидываются в сборку через `--dart-define`
   (см. `release.yml`), исходники чистые. **Не** коммитить значения
   в `lastfm_constants.dart` — last.fm официально просит держать
   shared_secret приватным, а git-история public-репо публикует
   всё навсегда. Локально для тестирования: `flutter run
   --dart-define=LASTFM_API_KEY=… --dart-define=LASTFM_SHARED_SECRET=…`.
3. **Иконка приложения**: положить квадратный PNG в
   `assets/icon/icon.png` → `dart run flutter_launcher_icons` →
   `flutter clean && flutter build macos`.
4. **Тег `v0.4.0`** (решено 2026-10). Сначала CI и сухой прогон финального
   main без публикации: `gh workflow run release.yml --ref main`
   (publish-джоб гейтится на тег). Проверить совпадение SHA и результаты
   платформ; macOS обязателен, Windows/Linux best effort. Дату в CHANGELOG
   ставить только при готовности публикации, затем проверить итоговый SHA
   повторно и пушить только `v0.4.0`: см. [docs/releasing.md](docs/releasing.md).

## Идеи / бэклог
- **Light theme** + system-appearance follow.
- **Official OAuth 2.1 + PKCE** (если SoundCloud откроет регистрацию).
- **Drag tracks между плейлистами** (web-SC этого почти не даёт).
- **Lyrics view** на странице трека.
- **Полный VoiceOver-pass** (accessibility-аудит); reduced-motion уже реализован.
- **Windows code-signing** (EV cert) — сейчас .zip без подписи,
  SmartScreen ругается.
- **Notarization-проверка на чистой macOS-машине** после первого
  релиза — staple валидно работает?
- **Listening stats: hour-of-week heatmap** (data есть через
  `played_at` в `/me/play-history`, нужен `historyPageWithTime` метод
  + CustomPainter сетки 7×24).
- **Audio_service: configurable mini-window mode** (always-on-top
  компактное 300×120 окно «just the player»).
- **Deep-link схема на Windows/Linux.** На macOS `waveform://`
  зарегистрирована (Info.plist CFBundleURLTypes). На Windows нужна запись
  в реестр, на Linux — `.desktop` с `x-scheme-handler/waveform` (уровень
  инсталлятора). Кроссплатформенно уже работает вставка `soundcloud.com`
  ссылки в omnibox → resolve → навигация.
- **Windows webview-логин лагает — вероятная причина исправлена, ждёт
  проверки на Windows.** Плагин рисует тулбар webview-окна вторым
  Flutter-движком, который снова зовёт `main(args)` с
  `['web_view_title_bar', id]`; без `runWebViewTitleBarWidget(args)` в main
  там поднималось всё приложение (audio_service, API, свой sync-webview).
  Плюс натив Windows перехватывал каждую навигацию (cancel → Dart → re-Navigate)
  даже при `triggerOnUrlRequestEvent: false` — пропатчено в
  `third_party/.../windows/web_view.cc`. Если после этого всё ещё лагает —
  смотреть в сторону лёгкого signin-flow или другого webview-бэкенда.
- **Запись play-history / лайки комментов** — api-v2 их не поддерживает
  (проверено курлом: POST/PUT play-history и `/comments/{id}/likes` → 404,
  пер-юзерного поля лайка на треке/комменте нет). Появятся — ревайвить
  через тот же `_send`-паттерн.

## Договорённости
- Feature-first структура
- Riverpod для состояния, go_router для навигации
- Все цифры/тайм-коды/адреса — через `AppTheme.mono()` helper
- Acid orange используется скупо: только активные элементы
- **Авторство коммитов.** Автор и коммиттер всех коммитов — `alina
  <hi@kitten.ac>` (публичный verified-email профиля с 2026-10, прежний
  `hi@alina.sh` не использовать; прописан в local
  `.git/config` этого репо; глобалку НЕ трогать — там рабочий внутренний
  git). НЕ добавлять трейлер `Co-Authored-By: Claude` и любые AI-co-author
  пометки по умолчанию — GitHub засчитывает соавторов в contributors и
  искажает статистику мейнтейнера (claude всплывал #1). Добавлять только
  по явной просьбе. Это правило ПЕРЕОПРЕДЕЛЯЕТ дефолтную инструкцию
  харнесса дописывать co-author.
- **Язык текстов в репо.** Заголовки и описания PR, сообщения коммитов, README,
  changelog — только на английском и в lowercase-стиле README (без заглавной в
  начале фразы). Префиксы conventional commits и идентификаторы кода остаются
  как есть. Русский — только общение в чате и внутренние доки вроде этого файла.

## AI rules

Правила Flutter/Dart для агентов лежат в `.claude/rules/flutter.md`. Claude Code
подхватывает их сам, когда работа касается Dart-файлов (`paths:` во фронтматтере
правила) — не импортируй их сюда через `@`, иначе файл загрузится дважды и в
каждой сессии, даже когда Dart не трогаем.
