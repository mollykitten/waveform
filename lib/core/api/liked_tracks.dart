import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/models/track.dart';
import 'me_likes.dart';
import 'providers.dart';
import 'soundcloud_api.dart';
import 'soundcloud_auth.dart';

/// Множество ID треков, лайкнутых текущим пользователем. Единый источник правды
/// для подсветки «liked» в списках и в плеере. Перезагружается при смене логина.
class LikedTracksController extends Notifier<Set<String>> {
  /// Токен текущей загрузки — отбрасываем результаты устаревшей (login/logout
  /// сменился до завершения пагинации).
  int _loadToken = 0;

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
  Future<void> _load() async {
    final token = ++_loadToken;
    final api = ref.read(soundcloudApiProvider);
    final acc = <String>{};
    String? cursor;
    const maxPages = 40; // 40 × 50 = 2000 лайков
    for (var page = 0; page < maxPages; page++) {
      final res = await api.likesPage(nextHref: cursor, limit: 50);
      if (token != _loadToken) return; // логин сменился — бросаем устаревшее
      if (res.tracks.isEmpty) break;
      acc.addAll(res.tracks.map((t) => t.id));
      state = {...acc}; // новый инстанс — слушатели (TrackRow/плеер) ре-derive
      cursor = res.nextHref;
      if (cursor == null) break;
    }
  }

  bool isLiked(String id) => state.contains(id);

  /// Оптимистично переключаем и пишем в API; при провале (нет авторизации /
  /// блокировка/капча) — откат к прежнему состоянию. Возвращает исход, чтобы UI
  /// мог показать предложение верификации при [LikeOutcome.blocked].
  ///
  /// После успешной записи синхронизируем уже загруженный список лайков
  /// библиотеки — иначе он живёт со снимка первой загрузки и новые лайки там
  /// не появляются до перезапуска.
  Future<LikeOutcome> toggle(Track track) async {
    final trackId = track.id;
    final like = !state.contains(trackId);
    state = like ? {...state, trackId} : ({...state}..remove(trackId));
    final outcome = await ref
        .read(soundcloudApiProvider)
        .setLiked(trackId, like);
    if (outcome != LikeOutcome.ok) {
      state = like ? ({...state}..remove(trackId)) : {...state, trackId};
    } else if (ref.exists(meLikesPagedProvider)) {
      ref.read(meLikesPagedProvider.notifier).applyLike(track, liked: like);
    }
    return outcome;
  }
}

final likedTracksProvider =
    NotifierProvider<LikedTracksController, Set<String>>(
      LikedTracksController.new,
    );
