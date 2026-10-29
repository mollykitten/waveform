import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/models/track.dart';
import 'providers.dart';

/// Состояние paginated-лайков: накопленный список + флаги загрузки + курсор.
/// SC api-v2 использует cursor-пагинацию (timestamp+type+id в `next_href`),
/// не числовой offset — отсюда [_nextHref] вместо `offset`.
class LikesPageState {
  const LikesPageState({
    this.tracks = const [],
    this.isInitial = true,
    this.isLoadingMore = false,
    this.nextHref,
    this.error,
  });

  final List<Track> tracks;
  final bool isInitial;
  final bool isLoadingMore;
  final String? nextHref;
  final Object? error;

  /// Есть ли смысл звать `loadNext()` ещё раз. На первой загрузке — да
  /// (nextHref ещё null, но isInitial=true). Позже nextHref=null означает
  /// «всё дочитано».
  bool get hasMore => isInitial || nextHref != null;

  LikesPageState copyWith({
    List<Track>? tracks,
    bool? isInitial,
    bool? isLoadingMore,
    String? nextHref,
    bool clearNextHref = false,
    Object? error,
    bool clearError = false,
  }) => LikesPageState(
    tracks: tracks ?? this.tracks,
    isInitial: isInitial ?? this.isInitial,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
    nextHref: clearNextHref ? null : (nextHref ?? this.nextHref),
    error: clearError ? null : (error ?? this.error),
  );
}

class MeLikesPageController extends Notifier<LikesPageState> {
  static const _pageSize = 50;

  @override
  LikesPageState build() {
    Future.microtask(loadNext);
    return const LikesPageState();
  }

  /// Поколение загрузок: [reset] увеличивает его, и запросы, стартовавшие
  /// раньше, молча отбрасываются (не затирают свежее состояние).
  int _gen = 0;

  Future<void> loadNext() async {
    if (state.isLoadingMore || !state.hasMore) return;
    final gen = _gen;
    final api = ref.read(soundcloudApiProvider);
    state = state.copyWith(isLoadingMore: true, clearError: true);
    try {
      final result = await api.likesPage(
        nextHref: state.nextHref,
        limit: _pageSize,
      );
      if (gen != _gen) return;
      // Дедуп на случай пересечений между страницами (или повторов от SC).
      final seen = {for (final t in state.tracks) t.id};
      final fresh = [
        for (final t in result.tracks)
          if (!seen.contains(t.id)) t,
      ];
      state = state.copyWith(
        tracks: [...state.tracks, ...fresh],
        isInitial: false,
        isLoadingMore: false,
        nextHref: result.nextHref,
        clearNextHref: result.nextHref == null,
      );
    } catch (e) {
      if (gen != _gen) return;
      state = state.copyWith(isInitial: false, isLoadingMore: false, error: e);
    }
  }

  /// Полный сброс — для retry после ошибки.
  Future<void> reset() async {
    _gen++;
    _refreshToken++;
    state = const LikesPageState();
    await loadNext();
  }

  int _refreshToken = 0;

  /// Тихое обновление «головы» списка: свежая первая страница вливается в
  /// начало уже загруженного списка (новые лайки сверху, снятые пропадают),
  /// хвост и курсор дальних страниц сохраняются — скролл не прыгает. Без
  /// skeleton; при ошибке список остаётся прежним.
  Future<void> refresh() async {
    if (state.isInitial) return; // первая загрузка ещё не завершилась
    final token = ++_refreshToken;
    final gen = _gen;
    try {
      final result = await ref
          .read(soundcloudApiProvider)
          .likesPage(limit: _pageSize);
      if (token != _refreshToken || gen != _gen) return;
      state = _mergeHead(result.tracks, result.nextHref);
    } catch (_) {
      // best-effort: оставляем текущий список.
    }
  }

  LikesPageState _mergeHead(List<Track> fresh, String? freshNext) {
    final existing = state.tracks;
    if (freshNext == null) {
      // Вся коллекция уместилась в одну страницу — она и есть истина.
      return state.copyWith(
        tracks: fresh,
        clearNextHref: true,
        clearError: true,
      );
    }
    final freshIds = {for (final t in fresh) t.id};
    final cut = fresh.isEmpty
        ? -1
        : existing.indexWhere((t) => t.id == fresh.last.id);
    // Голова существующего списка до границы свежей страницы заменяется ею.
    final tail = [
      for (final t in existing.skip(cut + 1))
        if (!freshIds.contains(t.id)) t,
    ];
    // Курсор дальних страниц сохраняем (в т.ч. null = «всё дочитано»); свежий
    // берём, только если список был пуст.
    final keepCursor = existing.isNotEmpty;
    return state.copyWith(
      tracks: [...fresh, ...tail],
      nextHref: keepCursor ? state.nextHref : freshNext,
      clearNextHref: keepCursor && state.nextHref == null,
      clearError: true,
    );
  }

  /// Локальная правка после успешного like/unlike: без похода в сеть (api-v2
  /// может отдавать список с задержкой).
  void applyLocal({required String trackId, Track? liked}) {
    final rest = [
      for (final t in state.tracks)
        if (t.id != trackId) t,
    ];
    state = state.copyWith(tracks: [?liked, ...rest]);
  }

  bool _draining = false;

  /// Догрузить ВСЕ оставшиеся страницы лайков — чтобы поиск шёл по всем лайкам,
  /// а не только по подгруженным (и для «shuffle all»). Идемпотентно: повторный
  /// вызов во время загрузки — no-op. Кап в 200 страниц (≈10k треков) —
  /// страховка от бесконечного цикла.
  Future<void> loadAll() async {
    if (_draining) return;
    _draining = true;
    try {
      for (var i = 0; i < 200; i++) {
        if (!state.hasMore) break;
        await loadNext();
        if (state.error != null) break; // оборвалось ошибкой — выходим
      }
    } finally {
      _draining = false;
    }
  }
}

final meLikesPagedProvider =
    NotifierProvider<MeLikesPageController, LikesPageState>(
      MeLikesPageController.new,
    );
