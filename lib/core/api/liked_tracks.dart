import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'me_likes.dart';
import '../../shared/models/track.dart';
import 'providers.dart';
import 'soundcloud_api.dart';
import 'soundcloud_auth.dart';

/// Множество ID треков, лайкнутых текущим пользователем. Единый источник правды
/// для подсветки «liked» в списках и в плеере. Перезагружается при смене логина.
class LikedTracksController extends Notifier<Set<String>> {
  /// Токен текущей загрузки — отбрасываем результаты устаревшей (login/logout
  /// сменился до завершения пагинации).
  int _loadToken = 0;

  /// Правки (id → liked), сделанные во время тихого [reload]: накладываются
  /// на результат, иначе оптимистичный лайк потерялся бы при финальной записи.
  Map<String, bool>? _overlay;

  @override
  Set<String> build() {
    ref.watch(authControllerProvider); // перезагрузка при login/logout
    _load();
    return const {};
  }

  /// Прогрессивная загрузка: api-v2 не даёт точечного «лайкнут ли трек», только
  /// полный список. Грузим постранично и обновляем state ПОСЛЕ КАЖДОЙ страницы
  /// — свежие лайки (первая страница) подсвечиваются мгновенно, остальные
  /// дотекают в фоне. Потолок против бесконечного цикла.
  ///
  /// [silent] — копить ID и подменить state один раз в конце (для ручного
  /// reload: сердца не мигают).
  Future<void> _load({bool silent = false}) async {
    final token = ++_loadToken;
    _overlay = silent ? {} : null;
    final api = ref.read(soundcloudApiProvider);
    final acc = <String>{};
    String? cursor;
    const maxPages = 40; // 40 × 50 = 2000 лайков
    for (var page = 0; page < maxPages; page++) {
      final res = await api.likesPage(nextHref: cursor, limit: 50);
      if (token != _loadToken) return; // логин сменился — бросаем устаревшее
      if (res.tracks.isEmpty) break;
      acc.addAll(res.tracks.map((t) => t.id));
      if (!silent) {
        state = {
          ...acc,
        }; // новый инстанс — слушатели (TrackRow/плеер) ре-derive
      }
      cursor = res.nextHref;
      if (cursor == null) break;
    }
    if (silent) {
      final overlay = _overlay ?? const <String, bool>{};
      _overlay = null;
      overlay.forEach((id, liked) => liked ? acc.add(id) : acc.remove(id));
      state = {...acc};
    }
  }

  /// Полная тихая перезагрузка множества лайков (кнопка refresh): подхватывает
  /// и лайки, и анлайки, сделанные вне приложения.
  Future<void> reload() async {
    try {
      await _load(silent: true);
    } catch (_) {
      _overlay = null;
      rethrow;
    }
  }

  /// Дешёвая синхронизация (фокус окна, открытие library): добавляет в
  /// множество ID из первой страницы лайков, ничего не убирая.
  Future<void> syncRecent() async {
    final token = _loadToken;
    try {
      final res = await ref.read(soundcloudApiProvider).likesPage(limit: 50);
      if (token != _loadToken || res.tracks.isEmpty) return;
      final ids = res.tracks.map((t) => t.id);
      if (state.containsAll(ids)) return;
      state = {...state, ...ids};
    } catch (_) {
      // best-effort
    }
  }

  bool isLiked(String id) => state.contains(id);

  /// Оптимистично переключаем и пишем в API; при провале (нет авторизации /
  /// блокировка/капча) — откат к прежнему состоянию. Возвращает исход, чтобы UI
  /// мог показать предложение верификации при [LikeOutcome.blocked].
  ///
  /// [track] нужен, чтобы сразу показать новый лайк в library > likes без
  /// похода в сеть.
  Future<LikeOutcome> toggle(String trackId, {Track? track}) async {
    final like = !state.contains(trackId);
    _overlay?[trackId] = like;
    state = like ? {...state, trackId} : ({...state}..remove(trackId));
    final outcome = await ref
        .read(soundcloudApiProvider)
        .setLiked(trackId, like);
    if (outcome != LikeOutcome.ok) {
      _overlay?[trackId] = !like;
      state = like ? ({...state}..remove(trackId)) : {...state, trackId};
    } else if (ref.exists(meLikesPagedProvider)) {
      // Список library > likes держит свою копию страниц — правим её локально
      // (api-v2 может отдать список с задержкой, поэтому без refresh).
      ref
          .read(meLikesPagedProvider.notifier)
          .applyLocal(trackId: trackId, liked: like ? track : null);
    }
    return outcome;
  }
}

final likedTracksProvider =
    NotifierProvider<LikedTracksController, Set<String>>(
      LikedTracksController.new,
    );
