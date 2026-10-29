import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../../core/api/feeds.dart';
import '../../core/api/liked_tracks.dart';
import '../../core/api/me_likes.dart';
import '../../core/api/soundcloud_api.dart';
import '../../core/api/soundcloud_auth.dart';
import '../../core/log/talker.dart';
import '../player/player_controller.dart';
import '../../shared/models/collection.dart';
import '../../shared/models/track.dart';
import '../../shared/view_mode.dart';
import '../../shared/widgets/async_view.dart';
import '../../shared/widgets/collection_card.dart';
import '../../shared/widgets/collection_row.dart';
import '../../shared/widgets/cover_art.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/logged_out_view.dart';
import '../../shared/widgets/pressable.dart';
import '../../shared/widgets/section_header.dart';
import '../../shared/widgets/skeleton_box.dart';
import '../../shared/widgets/track_row.dart';
import '../../shared/widgets/view_toggle.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key, this.initialTab});

  /// Имя вкладки для deep-link (`/library?tab=likes`) — шорткаты из рейла.
  final String? initialTab;

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  static const _tabs = [
    'likes',
    'playlists',
    'albums',
    'stations',
    'following',
    'history',
  ];
  late int _tab = _tabIndexOf(widget.initialTab);
  // Per-screen фильтр. Сброс при смене вкладки — пользователь редко
  // ожидает что фильтр «likes» перетечёт в «playlists».
  String _query = '';
  final TextEditingController _queryCtl = TextEditingController();

  int _tabIndexOf(String? name) {
    final i = _tabs.indexOf(name ?? '');
    return i == -1 ? 0 : i;
  }

  @override
  void didUpdateWidget(LibraryScreen old) {
    super.didUpdateWidget(old);
    // Повторная навигация на /library?tab=… с уже открытым экраном.
    if (widget.initialTab != old.initialTab && widget.initialTab != null) {
      setState(() {
        _tab = _tabIndexOf(widget.initialTab);
        _query = '';
        _queryCtl.clear();
      });
    }
  }

  @override
  void dispose() {
    _queryCtl.dispose();
    super.dispose();
  }

  void _selectTab(int i) {
    setState(() {
      _tab = i;
      _query = '';
      _queryCtl.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final authed = ref.watch(authControllerProvider).isAuthenticated;
    if (!authed) {
      return const Padding(
        padding: EdgeInsets.only(top: AppTheme.topBarHeight),
        child: LoggedOutView(
          title: 'your library',
          subtitle: 'log in to see your likes, playlists, stations and history',
        ),
      );
    }
    final currentTab = _tabs[_tab];
    // Центрируем + ограничиваем ширину на широких экранах (без рейла —
    // чуть уже, чем home/feed).
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: AppTheme.topBarHeight),
            _TabBar(
              tabs: _tabs,
              current: _tab,
              onSelect: _selectTab,
              // На history-табе тогл tile/list упрощён (только треки).
              trailing: currentTab == 'history' ? null : const ViewToggle(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.pagePad,
                12,
                AppTheme.pagePad,
                0,
              ),
              child: _FilterField(
                controller: _queryCtl,
                hint: 'filter $currentTab…',
                onChanged: (v) => setState(() => _query = v.trim()),
              ),
            ),
            Expanded(child: _tabBody(currentTab)),
          ],
        ),
      ),
    );
  }

  Widget _tabBody(String tab) {
    if (tab == 'likes') {
      return _PaginatedLikesTab(query: _query);
    }
    final lib = ref.watch(libraryProvider);
    return AsyncView<LibraryData>(
      value: lib,
      onRetry: () => ref.invalidate(libraryProvider),
      data: (data) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.pagePad,
          16,
          AppTheme.pagePad,
          AppTheme.playerHeight + 32,
        ),
        child: _bulkBody(tab, data),
      ),
    );
  }

  Widget _bulkBody(String tab, LibraryData d) {
    EmptyState noneFor(String section, IconData icon, String subtitle) =>
        EmptyState(
          icon: icon,
          title: 'no $section yet',
          subtitle: subtitle,
          actionLabel: 'go explore →',
          onAction: () => context.go('/'),
        );

    switch (tab) {
      case 'playlists':
        final items = _filterCollections(d.playlists);
        if (items.isEmpty && _query.isEmpty) {
          return noneFor(
            'playlists',
            Icons.queue_music_outlined,
            'create a playlist on SoundCloud — it appears here',
          );
        }
        return _grid('playlists', items);
      case 'albums':
        final items = _filterCollections(d.albums);
        return items.isEmpty && _query.isEmpty
            ? noneFor(
                'albums',
                Icons.album_outlined,
                'liked albums show up here',
              )
            : _grid('albums for you', items);
      case 'stations':
        final items = _filterCollections(d.stations);
        return items.isEmpty && _query.isEmpty
            ? noneFor(
                'stations',
                Icons.radio_outlined,
                'follow artists / genres to seed personal stations',
              )
            : _grid('your stations', items);
      case 'following':
        final items = _filterCollections(d.following);
        return items.isEmpty && _query.isEmpty
            ? noneFor(
                'one followed',
                Icons.people_outline,
                'follow artists to see their releases first',
              )
            : _grid('following', items);
      case 'history':
        final items = _filterTracks(d.history);
        if (items.isEmpty && _query.isEmpty) {
          return const EmptyState(
            icon: Icons.history,
            title: 'no history yet',
            subtitle: 'tracks you played will show up here',
          );
        }
        return _TracksList(title: 'history', tracks: items);
      default:
        return const SizedBox.shrink();
    }
  }

  List<Collection> _filterCollections(List<Collection> src) {
    if (_query.isEmpty) return src;
    final q = _query.toLowerCase();
    return src
        .where(
          (c) =>
              c.title.toLowerCase().contains(q) ||
              c.subtitle.toLowerCase().contains(q),
        )
        .toList();
  }

  List<Track> _filterTracks(List<Track> src) {
    if (_query.isEmpty) return src;
    final q = _query.toLowerCase();
    return src
        .where(
          (t) =>
              t.title.toLowerCase().contains(q) ||
              t.artist.toLowerCase().contains(q),
        )
        .toList();
  }

  Widget _grid(String title, List<Collection> items) {
    final mode = ref.watch(viewModeProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: title),
        const SizedBox(height: AppTheme.headerGap),
        if (items.isEmpty)
          _EmptyFilterHint(query: _query)
        else if (mode == ViewMode.tiles)
          Wrap(
            spacing: 20,
            runSpacing: 24,
            children: [for (final item in items) CollectionCard(item: item)],
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final item in items) CollectionRow(item: item)],
          ),
      ],
    );
  }
}

/// Likes-вкладка с пагинацией и фильтром. Используется собственный
/// paginated-провайдер вместо `libraryProvider.likes` (которые ограничены 50).
class _PaginatedLikesTab extends ConsumerStatefulWidget {
  const _PaginatedLikesTab({required this.query});
  final String query;
  @override
  ConsumerState<_PaginatedLikesTab> createState() => _PaginatedLikesTabState();
}

class _PaginatedLikesTabState extends ConsumerState<_PaginatedLikesTab>
    with WidgetsBindingObserver {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    // Открытие вкладки: подтягиваем лайки, поставленные после первой загрузки.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _refresh();
    });
    // Если экран открыт уже с активным фильтром — догружаем все лайки.
    if (widget.query.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadAllForSearch());
    }
  }

  @override
  void didUpdateWidget(_PaginatedLikesTab old) {
    super.didUpdateWidget(old);
    // Пользователь начал/сменил поиск → ищем по ВСЕМ лайкам, а не только по
    // подгруженным: добираем все страницы (loadAll идемпотентен).
    if (widget.query.isNotEmpty && widget.query != old.query) {
      _loadAllForSearch();
    }
  }

  void _loadAllForSearch() => ref.read(meLikesPagedProvider.notifier).loadAll();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Возврат в окно (например, после лайка на soundcloud.com).
    if (state == AppLifecycleState.resumed) _refresh();
  }

  /// [full] — явное обновление: перечитывает и множество лайков целиком.
  void _refresh({bool full = false}) {
    final liked = ref.read(likedTracksProvider.notifier);
    final sync = full ? liked.reload() : liked.syncRecent();
    sync.catchError((Object e, StackTrace st) {
      ref.read(talkerProvider).warning('likes sync failed', e, st);
    });
    ref.read(meLikesPagedProvider.notifier).refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    // Триггерим подгрузку за 800px до конца — чтобы не было видимой паузы.
    if (position.maxScrollExtent - position.pixels < 800) {
      ref.read(meLikesPagedProvider.notifier).loadNext();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(meLikesPagedProvider);
    final mode = ref.watch(viewModeProvider);

    // Первичный загрузочный экран — skeleton-сетка.
    if (state.isInitial && state.tracks.isEmpty) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.pagePad,
          16,
          AppTheme.pagePad,
          AppTheme.playerHeight + 32,
        ),
        child: const _LikesSkeletons(rows: 8),
      );
    }
    // Ошибка на первой загрузке (пусто).
    if (state.error != null && state.tracks.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppTheme.pagePad),
        child: EmptyState(
          icon: Icons.error_outline,
          title: 'couldn’t load likes',
          subtitle: state.error.toString(),
          actionLabel: 'retry',
          onAction: () => ref.read(meLikesPagedProvider.notifier).reset(),
        ),
      );
    }
    // Пустые лайки.
    if (state.tracks.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppTheme.pagePad),
        child: EmptyState(
          icon: Icons.favorite_outline,
          title: 'no likes yet',
          subtitle: 'like tracks to build a personal collection here',
          actionLabel: 'go explore →',
          onAction: () => context.go('/'),
        ),
      );
    }

    final q = widget.query.toLowerCase();
    final tracks = q.isEmpty
        ? state.tracks
        : state.tracks
              .where(
                (t) =>
                    t.title.toLowerCase().contains(q) ||
                    t.artist.toLowerCase().contains(q),
              )
              .toList();

    // Виртуализированный список (CustomScrollView + ленивые Sliver-билдеры):
    // рендерятся только видимые ряды. Иначе после «shuffle all» (догружает все
    // лайки — у активных юзеров это сотни треков) Column/Wrap строил их разом и
    // страница люто лагала.
    const hPad = EdgeInsets.symmetric(horizontal: AppTheme.pagePad);
    return CustomScrollView(
      controller: _scroll,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.pagePad,
            16,
            AppTheme.pagePad,
            0,
          ),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionHeader(
                  title: 'likes',
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${state.tracks.length}${state.hasMore ? '+' : ''}',
                        style: AppTheme.mono(
                          size: 11,
                          color: AppColors.textLow,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Tooltip(
                        message: 'refresh',
                        child: Pressable(
                          onTap: () => _refresh(full: true),
                          child: const Icon(
                            Icons.refresh,
                            size: 16,
                            color: AppColors.textMid,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      if (state.tracks.isNotEmpty) const _ShuffleAllLikes(),
                    ],
                  ),
                ),
                const SizedBox(height: AppTheme.headerGap),
              ],
            ),
          ),
        ),
        if (tracks.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: hPad,
              // Пока добираем все страницы под поиск — не показываем «нет
              // совпадений» преждевременно: совпадение может быть на ещё не
              // загруженной странице.
              child:
                  widget.query.isNotEmpty &&
                      (state.isLoadingMore || state.hasMore)
                  ? _SearchingAllLikes(loaded: state.tracks.length)
                  : _EmptyFilterHint(query: widget.query),
            ),
          )
        else if (mode == ViewMode.tiles)
          SliverPadding(
            padding: hPad,
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 180,
                mainAxisExtent: 212,
                crossAxisSpacing: 20,
                mainAxisSpacing: 24,
              ),
              itemCount: tracks.length,
              itemBuilder: (_, i) => _LikeTile(track: tracks[i]),
            ),
          )
        else
          SliverPadding(
            padding: hPad,
            sliver: SliverList.builder(
              itemCount: tracks.length,
              itemBuilder: (_, i) =>
                  TrackRow(track: tracks[i], queue: state.tracks),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: hPad,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Подгрузка следующей страницы — три skeleton-ряда.
                if (state.isLoadingMore) ...[
                  const SizedBox(height: 4),
                  const _LikesSkeletons(rows: 3),
                ],
                // Ошибка при подгрузке (но какие-то треки уже есть) — retry-строка.
                if (state.error != null && state.tracks.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _RetryRow(
                    message: 'failed to load more — tap to retry',
                    onRetry: () =>
                        ref.read(meLikesPagedProvider.notifier).loadNext(),
                  ),
                ],
                const SizedBox(height: AppTheme.playerHeight + 32),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// «Shuffle all» для likes: догружает все страницы через `loadNext()`, потом
/// перемешивает накопленный список и запускает воспроизведение. Пока качает —
/// показывает `loading…` (плюс live-счётчик загруженных треков в SectionHeader).
class _ShuffleAllLikes extends ConsumerStatefulWidget {
  const _ShuffleAllLikes();
  @override
  ConsumerState<_ShuffleAllLikes> createState() => _ShuffleAllLikesState();
}

class _ShuffleAllLikesState extends ConsumerState<_ShuffleAllLikes> {
  bool _busy = false;
  static final _rng = Random();

  Future<void> _run() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // Догружаем все страницы лайков (общий drain — см. loadAll).
      await ref.read(meLikesPagedProvider.notifier).loadAll();
      final all = List<Track>.of(ref.read(meLikesPagedProvider).tracks);
      if (all.isEmpty) return;
      all.shuffle(_rng);
      final c = ref.read(playerControllerProvider.notifier);
      // setShuffle(true) до play — чтобы next/prev сразу шёл из shuffled
      // _order'а (он перестраивается на новый _queue).
      c.setShuffle(true);
      c.play(all.first, queue: all);
    } catch (e, st) {
      ref.read(talkerProvider).warning('shuffle-all-likes failed', e, st);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: _run,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: AppTheme.borderRadius,
          border: AppTheme.border(),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _busy ? Icons.more_horiz : Icons.shuffle,
              size: 13,
              color: AppColors.textHi,
            ),
            const SizedBox(width: 6),
            Text(
              _busy ? 'loading…' : 'shuffle all',
              style: AppTheme.mono(
                size: 11,
                color: AppColors.textHi,
                weight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Skeleton-строка под TrackRow: cover-квадратик 46×46 + 2 строки текста +
/// длинный «waveform»-прямоугольник + 3 метрики. Пульсация ~1.2 сек.
class _LikesSkeletons extends StatelessWidget {
  const _LikesSkeletons({required this.rows});
  final int rows;
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < rows; i++)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: AppTheme.borderRadius,
              border: AppTheme.border(AppColors.borderDim),
            ),
            child: Row(
              children: [
                const SkeletonBox(width: 36, height: 36, circular: true),
                const SizedBox(width: 12),
                const SkeletonBox(width: 46, height: 46),
                const SizedBox(width: 14),
                Expanded(
                  flex: 4,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      SkeletonBox(width: 180, height: 12),
                      SizedBox(height: 6),
                      SkeletonBox(width: 110, height: 10),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                const Expanded(flex: 6, child: SkeletonBox(height: 24)),
                const SizedBox(width: 16),
                const SkeletonBox(width: 36, height: 10),
                const SizedBox(width: 16),
                const SkeletonBox(width: 14, height: 14, circular: true),
                const SizedBox(width: 16),
                const SkeletonBox(width: 30, height: 10),
              ],
            ),
          ),
      ],
    );
  }
}

class _RetryRow extends StatelessWidget {
  const _RetryRow({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onRetry,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: AppTheme.borderRadius,
          border: AppTheme.border(),
        ),
        child: Row(
          children: [
            const Icon(Icons.refresh, size: 16, color: AppColors.textMid),
            const SizedBox(width: 10),
            Text(
              message,
              style: AppTheme.mono(size: 12, color: AppColors.textMid),
            ),
          ],
        ),
      ),
    );
  }
}

/// Тайл для likes-tiles-view: квадратная обложка + название + артист. Аналог
/// CollectionCard, но для трека (тапает на /track/id).
class _LikeTile extends StatelessWidget {
  const _LikeTile({required this.track});
  final Track track;
  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: () => context.push('/track/${track.id}'),
      child: SizedBox(
        width: 160,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CoverArt(seed: track.id, imageUrl: track.coverUrl, size: 160),
            const SizedBox(height: 8),
            Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textHi,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              track.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.mono(size: 11, color: AppColors.textMid),
            ),
          ],
        ),
      ),
    );
  }
}

/// Маленький поисковой инпут под TabBar — фильтр коллекций/треков на вкладке.
class _FilterField extends StatelessWidget {
  const _FilterField({
    required this.controller,
    required this.hint,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: AppTheme.borderRadius,
        border: AppTheme.border(),
      ),
      child: Row(
        children: [
          const Icon(Icons.search, size: 14, color: AppColors.textLow),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              cursorColor: AppColors.acid,
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textHi,
                fontWeight: FontWeight.w500,
              ),
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: hint,
                hintStyle: TextStyle(
                  fontSize: 13,
                  color: AppColors.textLow.withValues(alpha: 0.85),
                ),
              ),
            ),
          ),
          if (controller.text.isNotEmpty)
            Pressable(
              onTap: () {
                controller.clear();
                onChanged('');
              },
              child: const Icon(
                Icons.close,
                size: 14,
                color: AppColors.textLow,
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyFilterHint extends StatelessWidget {
  const _EmptyFilterHint({required this.query});
  final String query;
  @override
  Widget build(BuildContext context) {
    final text = query.isEmpty ? 'nothing here yet' : 'no matches for “$query”';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Text(
        text,
        style: AppTheme.mono(size: 12, color: AppColors.textMid),
      ),
    );
  }
}

/// Пока добираем все страницы лайков под поиск — спиннер + счётчик.
class _SearchingAllLikes extends StatelessWidget {
  const _SearchingAllLikes({required this.loaded});
  final int loaded;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: AppColors.textMid,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'searching all your likes… ($loaded loaded)',
            style: AppTheme.mono(size: 12, color: AppColors.textMid),
          ),
        ],
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({
    required this.tabs,
    required this.current,
    required this.onSelect,
    this.trailing,
  });

  final List<String> tabs;
  final int current;
  final ValueChanged<int> onSelect;

  /// Опциональный элемент справа (например, `ViewToggle`).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.pagePad),
      decoration: const BoxDecoration(
        border: Border(bottom: AppTheme.borderSideStatic),
      ),
      child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++)
            _Tab(
              label: tabs[i],
              active: i == current,
              onTap: () => onSelect(i),
            ),
          if (trailing != null) ...[const Spacer(), trailing!],
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.label, required this.active, required this.onTap});

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 22),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? AppColors.acid : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            color: active ? AppColors.textHi : AppColors.textMid,
          ),
        ),
      ),
    );
  }
}

/// Список треков (history, фильтрованная история) — каждый ряд как TrackRow,
/// чтобы был play, like, метрики и т.п. Если треков нет — caller подставляет
/// EmptyState/фильтр-хинт.
class _TracksList extends StatelessWidget {
  const _TracksList({required this.title, required this.tracks});

  final String title;
  final List<Track> tracks;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: title),
        const SizedBox(height: AppTheme.headerGap),
        if (tracks.isEmpty)
          const _EmptyFilterHint(query: '')
        else
          for (final t in tracks) TrackRow(track: t, queue: tracks),
      ],
    );
  }
}
