import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../../core/api/feeds.dart';
import '../../core/api/providers.dart';
import '../../core/api/soundcloud_auth.dart';
import '../../core/cache/image_cache.dart';
import '../../shared/widgets/cover_art.dart';
import '../player/player_controller.dart';
import 'omnibox_providers.dart';
import 'recent_queries.dart';

/// Центральная ⌘K-палитра: большой acid-обведённый input, заголовок сверху,
/// результаты ниже. Рендерится в AppShell как overlay поверх blur-фона.
///
/// Apple/Raycast-like: scale+fade entrance (~200ms ease-out), Esc закрывает,
/// клик мимо закрывает (через scrim в AppShell). Контроллер запроса
/// переживает закрытие — повторный ⌘K возвращает к тому же тексту.
class OmniboxDropdown extends ConsumerStatefulWidget {
  const OmniboxDropdown({super.key});

  @override
  ConsumerState<OmniboxDropdown> createState() => _OmniboxDropdownState();
}

class _OmniboxDropdownState extends ConsumerState<OmniboxDropdown>
    with SingleTickerProviderStateMixin {
  Timer? _debounce;
  // Локальный FocusNode на жизнь модалки.
  final FocusNode _focus = FocusNode(debugLabel: 'omnibox-text');
  late final AnimationController _entry = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );

  // Подсветка результата для ↑/↓ + Enter. Считается от плоского списка,
  // который пересобирается каждый build (см. _buildItems).
  int _selectedIndex = 0;
  // Сюда build() кладёт текущий плоский список — используется в _onKey.
  List<_Item> _items = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctrl = ref.read(omniboxControllerProvider);
      ctrl.selection = TextSelection(
        baseOffset: 0,
        extentOffset: ctrl.text.length,
      );
      FocusScope.of(context).requestFocus(_focus);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _entry.value = 1;
    } else if (_entry.isDismissed) {
      _entry.forward();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _focus.dispose();
    _entry.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    // Пробел печатается как обычный символ: пока палитра открыта, глобальные
    // шорткаты (в т.ч. Space→play/pause) отключены на уровне AppShell, так что
    // поле получает пробел штатно.
    // Сброс подсветки на верх — иначе старый индекс может торчать за
    // пределами нового списка результатов.
    setState(() => _selectedIndex = 0);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      ref.read(omniboxQueryProvider.notifier).set(v.trim());
    });
  }

  void _close() => ref.read(omniboxOpenProvider.notifier).close();

  void _navigate(String location, {bool push = false}) {
    _close();
    if (push) {
      context.push(location);
    } else {
      context.go(location);
    }
  }

  void _submit(String value) {
    final q = value.trim();
    if (q.isEmpty) return;
    ref.read(recentQueriesProvider.notifier).add(q);
    _navigate('/search?q=${Uri.encodeQueryComponent(q)}');
  }

  /// Esc → закрыть; ↑/↓ — двигают подсветку; Enter — выполняет подсвеченный
  /// результат. Возвращаем handled, чтобы Shortcuts (VolumeUp/Down etc) не
  /// перехватывали стрелки пока модалка открыта.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (_items.isEmpty) return KeyEventResult.handled;
      setState(
        () => _selectedIndex = (_selectedIndex + 1).clamp(0, _items.length - 1),
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (_items.isEmpty) return KeyEventResult.handled;
      setState(
        () => _selectedIndex = (_selectedIndex - 1).clamp(0, _items.length - 1),
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _activateSelected();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Вызывается на Enter (через onKeyEvent или TextField.onSubmitted) — если
  /// подсвечен item, активируем его, иначе fallback на «search → /search?q=».
  void _activateSelected() {
    if (_items.isEmpty) {
      _submit(ref.read(omniboxControllerProvider).text);
      return;
    }
    final i = _selectedIndex.clamp(0, _items.length - 1);
    _items[i].onSelect();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(omniboxControllerProvider);
    final query = ref.watch(omniboxQueryProvider);
    final recents = ref.watch(recentQueriesProvider);
    final actions = _matchedActions(query);
    final track = ref.watch(playerControllerProvider).track;

    final placeholder = (controller.text.isEmpty && track != null)
        ? 'playing: ${track.artist} — ${track.title}'
        : 'search tracks, artists, playlists, or run a command…';

    // ── Сборка плоского списка секций+items для текущего query.
    // Используется и для рендера (с подсветкой), и для ↑↓Enter в _onKey.
    final scResults = query.isEmpty
        ? null
        : ref.watch(searchProvider(query)).asData?.value;
    final sections = <_ItemSection>[];

    if (query.isEmpty) {
      if (recents.isNotEmpty) {
        sections.add(
          _ItemSection('recent', [
            for (final r in recents)
              _Item(
                icon: Icons.history,
                title: r,
                onSelect: () {
                  ref.read(omniboxControllerProvider).text = r;
                  ref.read(omniboxQueryProvider.notifier).set(r);
                  _navigate('/search?q=${Uri.encodeQueryComponent(r)}');
                },
              ),
          ]),
        );
      }
    } else {
      // Вставлена ссылка soundcloud.com → топ-результат «открыть в клиенте»:
      // резолвим в маршрут и навигируем (трек/артист/плейлист).
      if (_looksLikeScUrl(query)) {
        sections.add(
          _ItemSection('link', [
            _Item(
              icon: Icons.link,
              title: 'open this SoundCloud link →',
              accent: true,
              onSelect: () async {
                final route = await ref
                    .read(soundcloudApiProvider)
                    .resolveUrl(query);
                if (!mounted) return;
                if (route != null) {
                  _navigate(route);
                } else {
                  _submit(query); // не распозналось — обычный поиск
                }
              },
            ),
          ]),
        );
      }
      if (actions.isNotEmpty) {
        sections.add(
          _ItemSection('actions', [
            for (final a in actions)
              _Item(
                icon: a.icon,
                title: a.label,
                onSelect: () {
                  a.run(context, ref);
                  _close();
                },
              ),
          ]),
        );
      }
      if (scResults != null) {
        final picks = <_Item>[];
        for (final t in scResults.tracks.take(3)) {
          picks.add(
            _Item(
              coverSeed: t.id,
              coverUrl: t.coverUrl,
              icon: Icons.music_note,
              title: t.title,
              subtitle: t.artist,
              onSelect: () => _navigate('/track/${t.id}'),
            ),
          );
        }
        for (final p in scResults.playlists.take(2)) {
          picks.add(
            _Item(
              coverSeed: p.id,
              coverUrl: p.coverUrl,
              icon: Icons.library_music_outlined,
              title: p.title,
              subtitle: p.subtitle,
              onSelect: () => _navigate('/playlist/${p.id}'),
            ),
          );
        }
        for (final a in scResults.artists.take(2)) {
          picks.add(
            _Item(
              coverSeed: a.handle,
              coverUrl: a.avatarUrl,
              coverCircular: true,
              icon: Icons.person_outline,
              title: a.name,
              subtitle: '@${a.handle}',
              onSelect: () =>
                  _navigate('/artist/${Uri.encodeComponent(a.handle)}'),
            ),
          );
        }
        if (picks.isNotEmpty) {
          sections.add(_ItemSection('from soundcloud', picks));
        }
      }
      sections.add(
        _ItemSection('', [
          _Item(
            icon: Icons.search,
            title: 'search "$query" →',
            accent: true,
            onSelect: () {
              ref.read(recentQueriesProvider.notifier).add(query);
              _navigate('/search?q=${Uri.encodeQueryComponent(query)}');
            },
          ),
        ]),
      );
    }

    _items = [for (final s in sections) ...s.items];
    if (_selectedIndex >= _items.length) _selectedIndex = 0;
    final showEmptyHint = query.isEmpty && _items.isEmpty;

    // Анимация входа: scale + fade.
    final scale = Tween<double>(
      begin: 0.96,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _entry, curve: Curves.easeOutCubic));
    final opacity = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _entry, curve: Curves.easeOutCubic));

    return FocusScope(
      autofocus: true,
      onKeyEvent: _onKey,
      child: FadeTransition(
        opacity: opacity,
        child: ScaleTransition(
          scale: scale,
          alignment: Alignment.topCenter,
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.surface.withValues(alpha: 0.94),
              borderRadius: AppTheme.borderRadius,
              border: AppTheme.border(),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.55),
                  blurRadius: 40,
                  offset: const Offset(0, 24),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            '⌘K · SEARCH WAVEFORM',
                            style: AppTheme.mono(
                              size: 10,
                              color: AppColors.textLow,
                              weight: FontWeight.w600,
                              letterSpacing: 1.6,
                            ),
                          ),
                          const Spacer(),
                          // Кнопка-крестик закрыть — для discoverability.
                          GestureDetector(
                            onTap: _close,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: AppTheme.borderRadius,
                                border: AppTheme.border(),
                              ),
                              child: Text(
                                'esc',
                                style: AppTheme.mono(
                                  size: 9,
                                  color: AppColors.textLow,
                                  weight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
                        height: 48,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        decoration: BoxDecoration(
                          color: AppColors.bg,
                          borderRadius: AppTheme.borderRadius,
                          border: Border.all(color: AppColors.acid, width: 1.0),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: controller,
                                focusNode: _focus,
                                autofocus: true,
                                onChanged: _onChanged,
                                onSubmitted: (_) => _activateSelected(),
                                textInputAction: TextInputAction.search,
                                cursorColor: AppColors.acid,
                                style: const TextStyle(
                                  fontSize: 15,
                                  color: AppColors.textHi,
                                  fontWeight: FontWeight.w500,
                                ),
                                decoration: InputDecoration(
                                  isCollapsed: true,
                                  border: InputBorder.none,
                                  hintText: placeholder,
                                  hintStyle: TextStyle(
                                    fontSize: 15,
                                    color: AppColors.textLow.withValues(
                                      alpha: 0.85,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const Icon(
                              Icons.search,
                              size: 18,
                              color: AppColors.textMid,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(
                  color: AppColors.border,
                  height: 0.5,
                  thickness: 0.5,
                ),
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 420),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: _Sections(
                        sections: sections,
                        selectedIndex: _selectedIndex,
                        showEmptyHint: showEmptyHint,
                        onTap: (i) {
                          setState(() => _selectedIndex = i);
                          _items[i].onSelect();
                        },
                        onHover: (i) {
                          if (_selectedIndex != i) {
                            setState(() => _selectedIndex = i);
                          }
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Похоже ли на публичную ссылку soundcloud.com.
  bool _looksLikeScUrl(String q) {
    final s = q.toLowerCase();
    return s.contains('soundcloud.com/') &&
        // нужен хотя бы один сегмент после домена (не голый soundcloud.com)
        s.split('soundcloud.com/').last.isNotEmpty;
  }

  /// Сматчить query на доступные actions. Простой substring + alias-набор.
  List<_OmniboxAction> _matchedActions(String q) {
    if (q.isEmpty) return const [];
    final ql = q.toLowerCase();
    bool m(List<String> aliases) => aliases.any((a) => a.contains(ql));
    return [
      if (m(const ['settings', 'set', 'prefs', 'options', 'config']))
        _OmniboxAction(
          icon: Icons.settings_outlined,
          label: 'open settings',
          run: (c, _) => c.push('/settings'),
        ),
      if (m(const ['logs', 'log', 'talker', 'debug']))
        _OmniboxAction(
          icon: Icons.terminal,
          label: 'open logs',
          run: (c, _) => c.push('/logs'),
        ),
      if (m(const ['likes', 'like', 'favorites', 'heart']))
        _OmniboxAction(
          icon: Icons.favorite_outline,
          label: 'go to library / likes',
          run: (c, _) => c.go('/library?tab=likes'),
        ),
      if (m(const ['stats', 'statistics', 'history']))
        _OmniboxAction(
          icon: Icons.bar_chart,
          label: 'view listening stats',
          run: (c, _) => c.go('/stats'),
        ),
      if (m(const ['shuffle']))
        _OmniboxAction(
          icon: Icons.shuffle,
          label: 'toggle shuffle',
          run: (_, ref) =>
              ref.read(playerControllerProvider.notifier).toggleShuffle(),
        ),
      if (m(const ['sign out', 'signout', 'logout', 'log out']))
        _OmniboxAction(
          icon: Icons.logout,
          label: 'sign out of soundcloud',
          run: (_, ref) => ref.read(authControllerProvider.notifier).signOut(),
        ),
      if (m(const ['cache', 'clear cache', 'reset cache', 'covers']))
        _OmniboxAction(
          icon: Icons.cleaning_services_outlined,
          label: 'clear cover art cache',
          run: (_, _) => waveformImageCache.emptyCache(),
        ),
    ];
  }
}

/// Один результат в палитре. Если задан [coverSeed] — рендерим CoverArt
/// (с [coverUrl] или fallback-процедурной обложкой); иначе — [icon].
class _Item {
  _Item({
    this.icon,
    this.coverSeed,
    this.coverUrl,
    this.coverCircular = false,
    required this.title,
    this.subtitle,
    this.accent = false,
    required this.onSelect,
  });
  final IconData? icon;
  final String? coverSeed;
  final String? coverUrl;
  final bool coverCircular;
  final String title;
  final String? subtitle;
  final bool accent;
  final VoidCallback onSelect;
}

class _ItemSection {
  _ItemSection(this.title, this.items);
  final String title;
  final List<_Item> items;
}

class _Sections extends StatelessWidget {
  const _Sections({
    required this.sections,
    required this.selectedIndex,
    required this.showEmptyHint,
    required this.onTap,
    required this.onHover,
  });

  final List<_ItemSection> sections;
  final int selectedIndex;
  final bool showEmptyHint;
  final void Function(int flat) onTap;
  final void Function(int flat) onHover;

  @override
  Widget build(BuildContext context) {
    if (showEmptyHint) {
      return const _EmptyHint(
        text: 'type to search SoundCloud — or try "settings", "logs", "stats"',
      );
    }
    final children = <Widget>[];
    var flat = 0;
    for (final sec in sections) {
      if (sec.title.isNotEmpty) {
        children.add(_SectionHeader(title: sec.title));
      }
      for (final item in sec.items) {
        final idx = flat;
        children.add(
          _Row(
            item: item,
            selected: idx == selectedIndex,
            onTap: () => onTap(idx),
            onHover: () => onHover(idx),
          ),
        );
        flat++;
      }
      children.add(const SizedBox(height: 4));
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

class _OmniboxAction {
  _OmniboxAction({required this.icon, required this.label, required this.run});
  final IconData icon;
  final String label;
  final void Function(BuildContext context, WidgetRef ref) run;
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});
  final String title;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: Text(
        title.toUpperCase(),
        style: AppTheme.mono(
          size: 9,
          color: AppColors.textLow,
          weight: FontWeight.w600,
          letterSpacing: 1.4,
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.item,
    required this.selected,
    required this.onTap,
    required this.onHover,
  });
  final _Item item;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onHover;

  @override
  Widget build(BuildContext context) {
    final Widget leading;
    if (item.coverSeed != null) {
      leading = CoverArt(
        seed: item.coverSeed!,
        imageUrl: item.coverUrl,
        size: 30,
        circular: item.coverCircular,
      );
    } else {
      leading = Center(
        child: Icon(
          item.icon ?? Icons.circle_outlined,
          size: 16,
          color: item.accent ? AppColors.acid : AppColors.textMid,
        ),
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onHover(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.acid.withValues(alpha: 0.10)
                : Colors.transparent,
            borderRadius: AppTheme.borderRadius,
            border: selected
                ? Border.all(
                    color: AppColors.acid.withValues(alpha: 0.45),
                    width: 0.5,
                  )
                : Border.all(color: Colors.transparent, width: 0.5),
          ),
          child: Row(
            children: [
              SizedBox(width: 30, height: 30, child: leading),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: item.accent ? AppColors.acid : AppColors.textHi,
                      ),
                    ),
                    if (item.subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        item.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.mono(
                          size: 10,
                          color: AppColors.textMid,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (selected) ...[
                const SizedBox(width: 8),
                Text(
                  '↵',
                  style: AppTheme.mono(
                    size: 11,
                    color: AppColors.acid,
                    weight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      child: Text(
        text,
        style: AppTheme.mono(size: 11, color: AppColors.textMid),
      ),
    );
  }
}
