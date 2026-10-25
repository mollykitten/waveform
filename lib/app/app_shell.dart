import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:window_manager/window_manager.dart';

import '../core/api/feeds.dart';
import '../core/api/providers.dart';
import '../core/api/reposted_tracks.dart';
import '../core/deeplinks/clipboard_watcher.dart';
import '../core/deeplinks/deep_links.dart';
import '../core/lastfm/scrobbler.dart';
import '../core/log/talker.dart';
import '../features/omnibox/omnibox_dropdown.dart';
import '../features/omnibox/omnibox_providers.dart';
import '../features/player/player_controller.dart';
import '../features/player/widgets/bottom_player.dart';
import '../features/queue/queue_panel.dart';
import '../features/queue/queue_visibility.dart';
import '../features/shortcuts/shortcuts_overlay.dart';
import '../shared/back_nav.dart';
import '../shared/chord_controller.dart';
import '../shared/intents.dart';
import '../shared/models/track.dart';
import '../shared/url_share.dart';
import '../shared/widgets/frosted.dart';
import '../shared/widgets/toast.dart';
import '../shared/widgets/top_bar.dart';
import 'shortcut_bindings.dart';
import 'theme/app_theme.dart';
import 'theme/colors.dart';

/// Оболочка приложения. Поверх контента — фрост-TopBar и фрост-BottomPlayer.
/// Здесь же глобальные клавиатурные шорткаты (Shortcuts + Actions),
/// центральная ⌘K-палитра поверх blur-фона, queue-панель справа.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  // Якорь для глобального focus'а: на нём сидят Shortcuts (Space/⌘K/…).
  // Когда модалка ⌘K закрывается, primaryFocus = null и Shortcuts молчат —
  // возвращаем focus сюда вручную.
  late final FocusNode _shellFocus = FocusNode(debugLabel: 'app-shell');

  final ChordController _chord = ChordController();

  /// Сфокусировано ли сейчас текстовое поле. Когда да — глобальные шорткаты
  /// ВЫКЛючаем (карта Shortcuts пустеет), иначе бэр-буквы L/R/S/… матчились бы
  /// в Intent вместо ввода. Фокус сам не триггерит rebuild, поэтому слушаем
  /// FocusManager и кешируем сюда.
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    final editing = _isEditing;
    if (editing != _editing && mounted) {
      setState(() => _editing = editing);
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusChange);
    _chord.dispose();
    _shellFocus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Навигация (push/pop/go) могла оставить primaryFocus = null → глобальные
    // шорткаты молчат и macOS звенит NSBeep на каждую клавишу. Возвращаем фокус
    // шеллу после смены маршрута, если не печатаем и не открыта модалка.
    if (oldWidget.location != widget.location) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_isEditing ||
            ref.read(omniboxOpenProvider) ||
            ref.read(shortcutsOverlayOpenProvider)) {
          return;
        }
        _shellFocus.requestFocus();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Lazy-bootstrap скробблера: provider создаст Notifier, который подпишется
    // на playerController.
    ref.watch(lastfmScrobblerProvider);
    // Lazy-bootstrap deep-link сервиса (waveform:// + soundcloud.com ссылки).
    ref.watch(deepLinkServiceProvider);
    // Lazy-bootstrap слежения за буфером (ссылки soundcloud.com → тост «открыть»).
    ref.watch(clipboardWatcherProvider);

    // Пока ⌘K-палитра открыта — глобальные шорткаты ВЫКЛючены, чтобы поле
    // ввода получало все клавиши (иначе bare `Space` матчился в PlayPause и
    // съедал пробел до текстового ввода — «вместо пробела пауза»). Сам модал
    // обрабатывает Esc/↑/↓/Enter внутри.
    final omniOpen = ref.watch(omniboxOpenProvider);
    final shortcutsOpen = ref.watch(shortcutsOverlayOpenProvider);

    // Когда модалка закрывается — возвращаем focus AppShell'у, иначе
    // primaryFocus остаётся null и Shortcuts перестают слышать клавиши.
    ref.listen<bool>(omniboxOpenProvider, (prev, next) {
      if (prev == true && next == false) {
        _shellFocus.requestFocus();
      }
    });

    // После закрытия help-оверлея возвращаем фокус шеллу — иначе primaryFocus
    // остаётся null и глобальные шорткаты молчат (как и с омнибоксом).
    ref.listen<bool>(shortcutsOverlayOpenProvider, (prev, next) {
      if (prev == true && next == false) {
        _shellFocus.requestFocus();
      }
    });

    // Динамический title окна — отражает текущий трек на desktop.
    ref.listen<Track?>(playerControllerProvider.select((s) => s.track), (
      prev,
      next,
    ) async {
      if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
        return;
      }
      final title = next == null
          ? 'Waveform'
          : 'Waveform · ${next.artist} — ${next.title}';
      try {
        await windowManager.setTitle(title);
      } catch (e, st) {
        // Логируем, чтобы видно было если плагин не настроен.
        ref.read(talkerProvider).warning('setTitle failed', e, st);
      }
    });

    ref.listen(playerControllerProvider.select((s) => s.unplayable), (
      prev,
      next,
    ) {
      if (next == null || next.seq == prev?.seq) return;
      final msg = '“${next.title}” is unavailable — skipped';
      showToast(context, msg, duration: const Duration(seconds: 3));
    });

    // Скопировал ссылку soundcloud.com → предлагаем открыть её в Waveform
    // (обход того, что ОС не отдаёт https://soundcloud.com клики в наш app).
    ref.listen<ClipboardLink?>(clipboardLinkProvider, (prev, next) {
      if (next == null || next.seq == prev?.seq) return;
      final url = next.url;
      showToast(
        context,
        'SoundCloud link copied',
        duration: const Duration(seconds: 6),
        action: (
          label: 'open in Waveform',
          onTap: () async {
            ref.read(clipboardWatcherProvider).markSeen(url);
            final route = await ref.read(soundcloudApiProvider).resolveUrl(url);
            if (!context.mounted) return;
            if (route != null) {
              context.go(route);
            } else {
              ref
                  .read(talkerProvider)
                  .warning('clipboard link not resolved: $url');
            }
          },
        ),
      );
    });

    final player = ref.read(playerControllerProvider.notifier);

    return Scaffold(
      backgroundColor: AppColors.bg,
      // Внешний Focus глотает unhandled-ключи без System-beep'а на macOS.
      // НО — символьные клавиши пропускаем (event.character != null), иначе
      // macOS подавляет доставку в NSTextInputClient → TextField не печатает.
      // NSBeep всё равно молчит на символах когда есть focused TextField.
      body: Focus(
        canRequestFocus: false,
        onKeyEvent: (_, event) {
          // MaterialApp owns Tab/Shift+Tab focus traversal above this shell.
          if (event.logicalKey == LogicalKeyboardKey.tab) {
            return KeyEventResult.ignored;
          }
          if (event.character != null && event.character!.isNotEmpty) {
            return KeyEventResult.ignored;
          }
          return KeyEventResult.handled;
        },
        child: Shortcuts(
          shortcuts: (omniOpen || shortcutsOpen || _editing)
              ? const <ShortcutActivator, Intent>{}
              : _shortcuts(),
          child: Actions(
            actions: <Type, Action<Intent>>{
              PlayPauseIntent: CallbackAction<PlayPauseIntent>(
                onInvoke: (_) {
                  player.toggle();
                  return null;
                },
              ),
              NextTrackIntent: CallbackAction<NextTrackIntent>(
                onInvoke: (_) {
                  player.next();
                  return null;
                },
              ),
              PrevTrackIntent: CallbackAction<PrevTrackIntent>(
                onInvoke: (_) {
                  player.previous();
                  return null;
                },
              ),
              VolumeUpIntent: CallbackAction<VolumeUpIntent>(
                onInvoke: (_) {
                  final cur = ref.read(playerControllerProvider).volume;
                  player.setVolume((cur + 0.05).clamp(0.0, 1.0));
                  return null;
                },
              ),
              VolumeDownIntent: CallbackAction<VolumeDownIntent>(
                onInvoke: (_) {
                  final cur = ref.read(playerControllerProvider).volume;
                  player.setVolume((cur - 0.05).clamp(0.0, 1.0));
                  return null;
                },
              ),
              FocusOmniboxIntent: CallbackAction<FocusOmniboxIntent>(
                onInvoke: (_) {
                  ref.read(omniboxOpenProvider.notifier).open();
                  return null;
                },
              ),
              JumpLikesIntent: CallbackAction<JumpLikesIntent>(
                onInvoke: (_) {
                  context.go('/library?tab=likes');
                  return null;
                },
              ),
              JumpSettingsIntent: CallbackAction<JumpSettingsIntent>(
                onInvoke: (_) {
                  context.push('/settings');
                  return null;
                },
              ),
              JumpLogsIntent: CallbackAction<JumpLogsIntent>(
                onInvoke: (_) {
                  context.push('/logs');
                  return null;
                },
              ),
              PlayPageTrackIntent: CallbackAction<PlayPageTrackIntent>(
                onInvoke: (_) {
                  _playTrackOnPage();
                  return null;
                },
              ),
              SeekForwardIntent: CallbackAction<SeekForwardIntent>(
                onInvoke: (_) {
                  player.seekBy(const Duration(seconds: 5));
                  return null;
                },
              ),
              SeekBackwardIntent: CallbackAction<SeekBackwardIntent>(
                onInvoke: (_) {
                  player.seekBy(const Duration(seconds: -5));
                  return null;
                },
              ),
              SeekToPercentIntent: CallbackAction<SeekToPercentIntent>(
                onInvoke: (i) {
                  player.seekFraction(i.tenth / 10.0);
                  return null;
                },
              ),
              MuteToggleIntent: CallbackAction<MuteToggleIntent>(
                onInvoke: (_) {
                  player.toggleMute();
                  return null;
                },
              ),
              RepeatToggleIntent: CallbackAction<RepeatToggleIntent>(
                onInvoke: (_) {
                  player.toggleRepeat();
                  return null;
                },
              ),
              ShuffleToggleIntent: CallbackAction<ShuffleToggleIntent>(
                onInvoke: (_) {
                  player.toggleShuffle();
                  return null;
                },
              ),
              LikePlayingIntent: CallbackAction<LikePlayingIntent>(
                onInvoke: (_) {
                  player.toggleLike();
                  return null;
                },
              ),
              RepostPlayingIntent: CallbackAction<RepostPlayingIntent>(
                onInvoke: (_) {
                  final id = ref.read(playerControllerProvider).track?.id;
                  if (id != null) {
                    ref.read(repostedTracksProvider.notifier).toggle(id);
                  }
                  return null;
                },
              ),
              NavigateToPlayingIntent: CallbackAction<NavigateToPlayingIntent>(
                onInvoke: (_) {
                  final id = ref.read(playerControllerProvider).track?.id;
                  if (id != null) context.push('/track/$id');
                  return null;
                },
              ),
              OpenSearchIntent: CallbackAction<OpenSearchIntent>(
                onInvoke: (_) {
                  ref.read(omniboxOpenProvider.notifier).open();
                  return null;
                },
              ),
              ToggleQueueIntent: CallbackAction<ToggleQueueIntent>(
                onInvoke: (_) {
                  ref.read(queueVisibleProvider.notifier).toggle();
                  return null;
                },
              ),
              ShowShortcutsIntent: CallbackAction<ShowShortcutsIntent>(
                onInvoke: (_) {
                  ref.read(shortcutsOverlayOpenProvider.notifier).open();
                  return null;
                },
              ),
              CopyLinkIntent: CallbackAction<CopyLinkIntent>(
                onInvoke: (_) {
                  _copyContextLink();
                  return null;
                },
              ),
            },
            child: Focus(
              focusNode: _shellFocus,
              autofocus: true,
              onKeyEvent: (node, event) => _handleChordKey(event),
              child: Consumer(
                builder: (context, ref, _) {
                  final omniOpen = ref.watch(omniboxOpenProvider);
                  final queueOpen = ref.watch(queueVisibleProvider);
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: _BackSwipe(
                          onBack: () {
                            if (context.canPop()) context.pop();
                          },
                          child: widget.child,
                        ),
                      ),
                      // Queue-панель справа.
                      if (queueOpen)
                        const Positioned(
                          top: AppTheme.topBarHeight,
                          bottom: AppTheme.playerHeight,
                          right: 0,
                          width: 320,
                          child: QueuePanel(),
                        ),
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: FrostedBar(
                          child: TopBar(location: widget.location),
                        ),
                      ),
                      const Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: FrostedBar(child: BottomPlayer()),
                      ),
                      // ⌘K-палитра: полноэкранный blur-фон + центрированная
                      // модалка. Клик мимо — закрывает. Поверх TopBar/BottomPlayer.
                      if (omniOpen) Positioned.fill(child: _OmniboxOverlay()),
                      // H — keyboard-shortcuts help overlay.
                      if (ref.watch(shortcutsOverlayOpenProvider))
                        const Positioned.fill(child: ShortcutsOverlay()),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Кросс-платформенные шорткаты: делегирует чистому билдеру [buildShortcuts].
  Map<ShortcutActivator, Intent> _shortcuts() =>
      buildShortcuts(isMac: Platform.isMacOS, location: widget.location);

  /// `G`-then-key аккорд. Текстовые поля съедают символы раньше (focus-bubbling),
  /// так что G/буквы здесь видны только когда НЕ печатаем.
  KeyEventResult _handleChordKey(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final kb = HardwareKeyboard.instance;
    final hasMod = kb.isMetaPressed || kb.isControlPressed || kb.isAltPressed;
    // Help-оверлей (клавиша H) открыт: H или Esc его закрывают. Его собственный
    // autofocus-Focus проигрывает уже сфокусированному _shellFocus и не получает
    // событие, поэтому закрываем здесь — гарантированно. Остальные клавиши
    // глотаем (оверлей модальный).
    if (ref.read(shortcutsOverlayOpenProvider)) {
      if (!hasMod &&
          (event.logicalKey == LogicalKeyboardKey.keyH ||
              event.logicalKey == LogicalKeyboardKey.escape)) {
        ref.read(shortcutsOverlayOpenProvider.notifier).close();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    // В поле ввода (или ⌘K-омнибокс / комбо с модификатором) НЕ перехватываем:
    // возвращаем `ignored`, чтобы macOS доставил символ в NSTextInputClient —
    // иначе поле перестаёт печатать (`handled` подавляет ввод). Single-letter
    // шорткаты при вводе не сработают, потому что карта Shortcuts пустеет на
    // `_editing` (см. build) — гасим на уровне карты, а не KeyEvent'а.
    if (hasMod || ref.read(omniboxOpenProvider) || _isEditing) {
      return KeyEventResult.ignored;
    }
    if (_chord.armed) {
      final target = _chord.resolve(event.logicalKey);
      if (target != null) {
        _goChord(target);
        return KeyEventResult.handled;
      }
      return KeyEventResult
          .handled; // отменённый аккорд глотает клавишу (как web SC)
    }
    if (event.logicalKey == LogicalKeyboardKey.keyG) {
      _chord.arm();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Сейчас в фокусе редактируемое текстовое поле?
  bool get _isEditing {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx != null &&
        ctx.findAncestorStateOfType<EditableTextState>() != null;
  }

  void _goChord(ChordTarget t) {
    switch (t) {
      case ChordTarget.likes:
        context.go('/library?tab=likes');
      case ChordTarget.feed:
        context.go('/feed');
      case ChordTarget.library:
        context.go('/library');
      case ChordTarget.history:
        context.go('/library?tab=history');
      case ChordTarget.profile:
        final handle = ref.read(railProvider).asData?.value.me?.handle;
        if (handle != null) {
          context.go('/artist/${Uri.encodeComponent(handle)}');
        }
    }
  }

  /// ⌘⇧C — копирует ссылку текущего контекста: трек страницы /track/:id →
  /// его permalink; артист /artist/:handle → профиль; иначе — играющий трек.
  /// markSeen внутри copyToClipboard (через ref) гасит «open in Waveform?» тост.
  void _copyContextLink() {
    String? url;
    final segs = Uri.parse(widget.location).pathSegments;
    if (segs.length >= 2 && segs[0] == 'track') {
      final id = segs[1];
      url = ref.read(trackDetailProvider(id)).asData?.value.track.permalinkUrl;
    } else if (segs.length >= 2 && segs[0] == 'artist') {
      final handle = Uri.decodeComponent(segs[1]);
      if (handle.isNotEmpty) url = 'https://soundcloud.com/$handle';
    }
    url ??= ref.read(playerControllerProvider).track?.permalinkUrl;
    if (url == null || url.isEmpty) {
      showToast(
        context,
        'nothing to copy',
        duration: const Duration(seconds: 2),
      );
      return;
    }
    copyToClipboard(context, url, message: 'link copied', ref: ref);
  }

  /// Реакция на Enter на /track/:id. Если уже играет именно этот трек —
  /// no-op (Space всё ещё toggle'ит). Если играет другой / пауза — стартуем
  /// этот, в очередь добавляем related.
  void _playTrackOnPage() {
    final segs = Uri.parse(widget.location).pathSegments;
    if (segs.length < 2 || segs[0] != 'track') return;
    final trackId = segs[1];
    final detail = ref.read(trackDetailProvider(trackId)).asData?.value;
    if (detail == null) return;
    final cur = ref.read(playerControllerProvider);
    final c = ref.read(playerControllerProvider.notifier);
    if (cur.track?.id == trackId) {
      if (!cur.isPlaying) c.toggle();
      return;
    }
    c.play(detail.track, queue: detail.related);
  }
}

/// Полноэкранный overlay: blur-фон + dim scrim + центрированная палитра.
/// Клик мимо палитры — закрытие.
class _OmniboxOverlay extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void close() => ref.read(omniboxOpenProvider.notifier).close();
    return Stack(
      children: [
        // Backdrop blur + dim. GestureDetector ловит клик мимо → close.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: close,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(color: AppColors.bg.withValues(alpha: 0.45)),
            ),
          ),
        ),
        // Центральная модалка. Останавливаем тап на ней (через AbsorbPointer
        // или GestureDetector с прозрачным behavior нельзя — нужен absorb).
        Positioned.fill(
          child: IgnorePointer(
            ignoring: false,
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).size.height * 0.14,
                  left: 24,
                  right: 24,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  // GestureDetector на модалке поглощает клик — иначе он
                  // прорывался бы к scrim'у и закрывал палитру.
                  child: GestureDetector(
                    onTap: () {},
                    behavior: HitTestBehavior.opaque,
                    child: const OmniboxDropdown(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Свайп вправо от левого края → назад. Трекпад-свайп (macOS) приходит как
/// pan-события (onPointerPanZoom*), мышь — как horizontal drag. Оба пути
/// edge-gated по позиции КУРСОРА (localPosition.dx): срабатывает только когда
/// жест начат у левого края — чтобы не конфликтовать с горизонтальными
/// каруселями в центре экрана.
class _BackSwipe extends StatefulWidget {
  const _BackSwipe({required this.child, required this.onBack});
  final Widget child;
  final VoidCallback onBack;
  @override
  State<_BackSwipe> createState() => _BackSwipeState();
}

class _BackSwipeState extends State<_BackSwipe> {
  double _startDx = 0;
  double _totalDx = 0;
  bool _panActive = false;

  bool get _canPop => GoRouter.of(context).canPop();

  void _begin(double localDx) {
    _startDx = localDx;
    _totalDx = 0;
  }

  void _accumulate(double dx) => _totalDx += dx;

  void _end() {
    if (shouldPopOnSwipe(
      canPop: _canPop,
      startDx: _startDx,
      totalDx: _totalDx,
    )) {
      widget.onBack();
    }
    _startDx = 0;
    _totalDx = 0;
    _panActive = false;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerPanZoomStart: (e) {
        _panActive = true;
        _begin(e.localPosition.dx);
      },
      onPointerPanZoomUpdate: (e) {
        if (_panActive) _accumulate(e.panDelta.dx);
      },
      onPointerPanZoomEnd: (e) {
        if (_panActive) {
          _panActive = false;
          _end();
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (d) => _begin(d.localPosition.dx),
        onHorizontalDragUpdate: (d) => _accumulate(d.delta.dx),
        onHorizontalDragEnd: (_) => _end(),
        child: widget.child,
      ),
    );
  }
}

/// Отступы контента под фрост-хрому — добавляются к скроллу каждого экрана.
const double kContentTop = AppTheme.topBarHeight;
const double kContentBottom = AppTheme.playerHeight;
