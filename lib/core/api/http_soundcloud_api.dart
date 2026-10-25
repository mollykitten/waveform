import 'package:dio/dio.dart';
import 'package:talker_flutter/talker_flutter.dart';

import '../../shared/models/artist.dart';
import '../../shared/models/collection.dart';
import '../../shared/models/comment.dart';
import '../../shared/models/feed_post.dart';
import '../../shared/models/track.dart';
import 'client_id_resolver.dart';
import 'dto/comment_dto.dart';
import 'dto/json.dart';
import 'dto/page_dto.dart';
import 'dto/playlist_dto.dart';
import 'dto/track_dto.dart';
import 'dto/user_dto.dart';
import 'mappers.dart';
import 'soundcloud_api.dart';
import 'soundcloud_auth.dart';
import 'webview_executor.dart';

/// Живой клиент api-v2 (порт логики yt-dlp). Анонимно — по client_id;
/// персональные ручки (личный stream/likes) — с userToken (OAuth Bearer).
///
/// Курируемые секции (recentlyPlayed/likedBy/...) анонимно недоступны как
/// персонализированные — аппроксимируем чартами/поиском (TODO:auth).
class HttpSoundcloudApi implements SoundcloudApi {
  HttpSoundcloudApi(
    this._dio,
    this._ids, {
    this.auth,
    this.executor,
    required Talker talker,
  }) : _log = talker;

  final Dio _dio;
  final ClientIdResolver _ids;
  final SoundcloudAuth? auth;
  final WebviewApiExecutor? executor;
  final Talker _log;

  static const _base = 'https://api-v2.soundcloud.com';

  Options? get _authOptions => auth?.isAuthenticated == true
      ? Options(headers: {'Authorization': 'OAuth ${auth!.userToken}'})
      : null;

  /// GET с client_id; при 401 — рефреш client_id и одна повторная попытка.
  ///
  /// [authed] добавляет OAuth-заголовок — ТОЛЬКО для личных ручек (`/me*`,
  /// `/stream`). Анонимные эндпоинты (треки/поиск/подборки) никогда не несут
  /// токен: иначе невалидный токен ронял бы 400 вообще всё приложение.
  Future<dynamic> _get(
    String path, [
    Map<String, dynamic>? query,
    bool authed = false,
  ]) async {
    Future<Response<dynamic>> call() async {
      final cid = await _ids.get();
      return _dio.get(
        '$_base$path',
        queryParameters: {'client_id': cid, ...?query},
        options: authed ? _authOptions : null,
      );
    }

    try {
      return (await call()).data;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        await _ids.refresh();
        return (await call()).data;
      }
      rethrow;
    }
  }

  /// PUT/DELETE на личную ручку (лайк/репост). Если есть webview-executor —
  /// гоним через него (обходит DataDome-403); иначе/при сбое — Dio-фолбэк.
  Future<LikeOutcome> writeOutcome(String method, String path) async {
    final ex = executor;
    if (ex != null) {
      try {
        final status = await ex.send(method: method, path: path);
        if (status == 200 || status == 201) return LikeOutcome.ok;
        if (status == 401 || status == 403 || status == 429) {
          return LikeOutcome.blocked;
        }
        return LikeOutcome.failed;
      } catch (e, st) {
        _log.warning('executor write failed → dio fallback', e, st);
      }
    }
    try {
      final cid = await _ids.get();
      await _dio.request(
        '$_base$path',
        queryParameters: {'client_id': cid},
        options: Options(method: method, headers: _authOptions?.headers),
      );
      return LikeOutcome.ok;
    } on DioException catch (e, st) {
      _log.warning('$method $path failed', e, st);
      final code = e.response?.statusCode ?? 0;
      return (code == 401 || code == 403 || code == 429)
          ? LikeOutcome.blocked
          : LikeOutcome.failed;
    } catch (e, st) {
      _log.warning('$method $path failed', e, st);
      return LikeOutcome.failed;
    }
  }

  PageDto<T> _page<T>(dynamic data, T Function(Map<String, dynamic>) item) =>
      PageDto.parse(asMap(data), item);

  bool get _authed => auth?.isAuthenticated == true;

  /// Если залогинены — пробуем персональную ручку; при ошибке/анониме —
  /// анонимный фоллбек (чтобы UI не падал на закрытых эндпоинтах).
  Future<T> _tryAuthed<T>(
    Future<T> Function() authed,
    Future<T> Function() anon,
  ) async {
    if (_authed) {
      try {
        return await authed();
      } catch (e, st) {
        // Личная ручка не отдала данные — видно в логах вместе с Dio-ошибкой.
        _log.warning('authed call failed → fallback', e, st);
      }
    }
    return anon();
  }

  // Треки как обложечные карточки. target=track → тап ведёт на /track/{id}
  // (а не играет случайный трек из чужой очереди, как было).
  List<Collection> _cards(List<Track> tracks) => [
    for (final t in tracks)
      Collection(
        id: t.id,
        title: t.title,
        subtitle: t.artist,
        kind: CollectionKind.playlist,
        target: CollectionTarget.track,
        coverUrl: t.coverUrl,
      ),
  ];

  /// Личный стрим подписок (только треки) — требует userToken.
  Future<List<Track>> _streamTracks(int limit) async {
    final data = await _get('/stream', {'limit': limit}, true);
    return _page(data, StreamItemDto.fromJson).collection
        .where((e) => e.isTrack && e.track != null)
        .map((e) => e.track!.toDomain())
        .toList();
  }

  // ── Запросы-кирпичики (реальные ручки api-v2) ───────────────────────────────
  // Реальные жанровые слаги SoundCloud (не произвольные слова).
  static const _genres = [
    'all-music',
    'electronic',
    'house',
    'hiphoprap',
    'ambient',
    'indie',
  ];

  /// Курированные полки домашней SoundCloud (реальные заголовки + плейлисты).
  Future<List<Shelf>> _mixedShelves() async {
    final data = await _get('/mixed-selections', {'limit': 12});
    final shelves = <Shelf>[];
    for (final sel in asMapList(asMap(data)['collection'])) {
      final items = asMapList(asMap(sel['items'])['collection'])
          .where((m) => m.containsKey('title'))
          .map((m) {
            final p = PlaylistDto.fromJson(m);
            return Collection(
              id: '${p.id}',
              title: p.title,
              subtitle: p.user.username.isEmpty
                  ? 'SoundCloud'
                  : p.user.username,
              kind: p.isAlbum ? CollectionKind.album : CollectionKind.playlist,
              coverUrl: hiResArtwork(p.artworkUrl),
              trackCount: p.trackCount,
            );
          })
          .toList();
      if (items.isNotEmpty) {
        shelves.add((
          title: '${sel['title'] ?? 'selection'}'.toLowerCase(),
          items: items,
        ));
      }
    }
    return shelves;
  }

  Future<List<Collection>> _searchPlaylists(
    String genre, {
    bool albums = false,
  }) async {
    final data = await _get(albums ? '/search/albums' : '/search/playlists', {
      'q': genre,
      'limit': 12,
    });
    return _page(data, PlaylistDto.fromJson).mapList((d) => d.toDomain());
  }

  Future<List<Collection>> _genreStations(String genre) async {
    final data = await _get('/search/users', {'q': genre, 'limit': 10});
    return _page(data, UserDto.fromJson).mapList(
      (u) => Collection(
        id: '${u.id}',
        title: u.username,
        subtitle: 'artist station',
        kind: CollectionKind.station,
        target: CollectionTarget.artist,
        handle: u.permalink,
        coverUrl: hiResArtwork(u.avatarUrl),
      ),
    );
  }

  // Личные коллекции в api-v2 — по /users/{id}/…, а НЕ /me/… (последние 404).
  // Исключения, которые реально работают как /me/…: /me и /me/play-history.
  Future<String?>? _meIdFuture;
  Future<String?> _meId() => _meIdFuture ??= _fetchMeId();
  Future<String?> _fetchMeId() async {
    try {
      final id = asMap(await _get('/me', null, true))['id'];
      return id == null ? null : '$id';
    } catch (e, st) {
      _log.warning('failed to resolve /me id', e, st);
      return null;
    }
  }

  // /users/{id}/track_likes отдаёт обёртки `{created_at, track:{…}}`.
  Future<List<Track>> _meLikes([int limit = 50]) async {
    final id = await _meId();
    if (id == null) return const [];
    return _page(
      await _get('/users/$id/track_likes', {'limit': limit}, true),
      (j) => TrackDto.fromJson(asMap(j['track'] ?? j)),
    ).mapList((d) => d.toDomain());
  }

  Future<List<Collection>> _mePlaylists() async {
    final id = await _meId();
    if (id == null) return const [];
    return _page(
      await _get('/users/$id/playlists_without_albums', {'limit': 40}, true),
      (j) => PlaylistDto.fromJson(asMap(j['playlist'] ?? j)),
    ).mapList((d) => d.toDomain());
  }

  Future<List<Track>> _playHistory([int limit = 12]) async => _page(
    await _get('/me/play-history/tracks', {'limit': limit}, true),
    (j) => TrackDto.fromJson(asMap(j['track'] ?? j)),
  ).mapList((d) => d.toDomain());

  @override
  Future<List<Track>> historyPage({int limit = 50, int offset = 0}) async {
    return _tryAuthed(() async {
      final data = await _get('/me/play-history/tracks', {
        'limit': limit,
        'offset': offset,
      }, true);
      return _page(
        data,
        (j) => TrackDto.fromJson(asMap(j['track'] ?? j)),
      ).mapList((d) => d.toDomain());
    }, () async => const <Track>[]);
  }

  @override
  Future<({List<Track> tracks, String? nextHref})> likesPage({
    String? nextHref,
    int limit = 50,
  }) async {
    return _tryAuthed<({List<Track> tracks, String? nextHref})>(() async {
      late final dynamic data;
      if (nextHref != null) {
        // Cursor-страница: SC возвращает полный URL уже с offset=<курсор>;
        // достаточно подмешать наш свежий client_id и токен.
        data = await _getUrl(nextHref, true);
      } else {
        final id = await _meId();
        if (id == null) {
          return (tracks: <Track>[], nextHref: null);
        }
        data = await _get('/users/$id/track_likes', {'limit': limit}, true);
      }
      final page = _page(
        data,
        (j) => TrackDto.fromJson(asMap(j['track'] ?? j)),
      );
      return (
        tracks: page.mapList((d) => d.toDomain()),
        nextHref: page.nextHref,
      );
    }, () async => (tracks: <Track>[], nextHref: null));
  }

  /// GET абсолютного URL (для next_href пагинации). Подмешиваем свежий
  /// client_id поверх собственных query-параметров SC, 401 → refresh + retry.
  Future<dynamic> _getUrl(String url, bool authed) async {
    Future<Response<dynamic>> call() async {
      final cid = await _ids.get();
      final uri = Uri.parse(url);
      final query = {...uri.queryParameters, 'client_id': cid};
      final full = uri.replace(queryParameters: query).toString();
      return _dio.get(full, options: authed ? _authOptions : null);
    }

    try {
      return (await call()).data;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        await _ids.refresh();
        return (await call()).data;
      }
      rethrow;
    }
  }

  Future<Artist?> _meProfile() async {
    try {
      return UserDto.fromJson(asMap(await _get('/me', null, true))).toDomain();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<double>?> fetchWaveform(String url) => _waveform(url);

  Future<List<double>?> _waveform(String? url) async {
    if (url == null) return null;
    try {
      final data = asMap((await _dio.get(url)).data);
      final samples = (data['samples'] as List?)?.cast<num>() ?? const [];
      if (samples.isEmpty) return null;
      final max = samples.reduce((a, b) => a > b ? a : b).toDouble();
      return [
        for (final s in samples) (max == 0 ? 0.0 : s / max).clamp(0.04, 1.0),
      ];
    } catch (_) {
      return null;
    }
  }

  Future<UserDto> _resolveUser(String handle) async => UserDto.fromJson(
    asMap(await _get('/resolve', {'url': 'https://soundcloud.com/$handle'})),
  );

  /// Реальные плейлисты/альбомы конкретного пользователя (НЕ глобальный поиск
  /// по нику — тот выдавал чужие коллекции). Анонимные публичные ручки.
  Future<List<Collection>> _userPlaylists(
    int userId, {
    bool albums = false,
  }) async {
    final path = albums
        ? '/users/$userId/albums'
        : '/users/$userId/playlists_without_albums';
    try {
      return _page(
        await _get(path, {'limit': 20}),
        (j) => PlaylistDto.fromJson(asMap(j['playlist'] ?? j)),
      ).mapList((d) => d.toDomain());
    } catch (e, st) {
      _log.warning('user playlists ($path) failed', e, st);
      return const [];
    }
  }

  // ── Агрегаты под экраны ─────────────────────────────────────────────────────
  @override
  Future<HomeData> home() async {
    // Личный стрим — только залогиненным; анонимам секции не будет.
    final stream = _tryAuthed(
      () => _streamTracks(12),
      () => Future.value(<Track>[]),
    );
    List<Shelf> shelves;
    try {
      shelves = await _mixedShelves();
    } catch (_) {
      shelves = const [];
    }
    // Фоллбек на полки по реальным жанрам, если курированная домашняя пуста.
    if (shelves.isEmpty) {
      shelves = [
        for (final g in _genres.skip(1).take(4))
          (title: g, items: await _searchPlaylists(g)),
      ];
    }
    return (stream: await stream, shelves: shelves);
  }

  @override
  Future<LibraryData> library() async {
    // «Recently played» = реальная история прослушивания (а не дискавери).
    final recent = _tryAuthed(
      () async => _cards(await _playHistory(16)),
      () async => const <Collection>[],
    );
    // Личные секции: при отсутствии/провале авторизации — пусто, НЕ чужой контент.
    final likes = _tryAuthed(
      () async => _cards(await _meLikes()),
      () async => const <Collection>[],
    );
    final playlists = _tryAuthed(
      () => _mePlaylists(),
      () async => const <Collection>[],
    );
    final albums = _searchPlaylists(_genres[0], albums: true);
    final stations = _genreStations(_genres[1]);
    final following = _tryAuthed(
      () => _meFollowings(),
      () async => const <Collection>[],
    );
    final history = _tryAuthed(
      () => _playHistory(),
      () async => const <Track>[],
    );
    return (
      recentlyPlayed: await recent,
      likes: await likes,
      playlists: await playlists,
      albums: await albums,
      stations: await stations,
      following: await following,
      history: await history,
    );
  }

  Future<List<Collection>> _meFollowings() async {
    final id = await _meId();
    if (id == null) return const [];
    return _page(
      await _get('/users/$id/followings', {'limit': 40}, true),
      UserDto.fromJson,
    ).mapList(
      (u) => Collection(
        id: '${u.id}',
        title: u.username,
        subtitle: 'following',
        kind: CollectionKind.station,
        target: CollectionTarget.artist,
        handle: u.permalink,
        coverUrl: hiResArtwork(u.avatarUrl),
      ),
    );
  }

  @override
  Future<List<FeedPost>> feed() => _tryAuthed(
    () async {
      final data = await _get('/stream', {'limit': 20}, true);
      return _page(
        data,
        StreamItemDto.fromJson,
      ).collection.map((e) => e.toFeedPost()).whereType<FeedPost>().toList();
    },
    // Лента — личная: без рабочего токена пусто, не подменяем дискавери.
    () async => const <FeedPost>[],
  );

  @override
  Future<RailData> rail() async {
    final me = _authed ? _meProfile() : Future<Artist?>.value(null);
    // Превью последних лайков и история — личные; анонимам пусто (секции скроются).
    final likes = _tryAuthed(() => _meLikes(6), () => Future.value(<Track>[]));
    final history = _tryAuthed(
      () => _playHistory(),
      () => Future.value(<Track>[]),
    );
    return (me: await me, likes: await likes, history: await history);
  }

  @override
  Future<TrackDetail> trackDetail(String id) async {
    // Только сам трек обязателен — комменты/related не должны ронять страницу.
    final commentsF = _trackComments(id);
    final relatedF = relatedTracks(id);

    final dto = TrackDto.fromJson(asMap(await _get('/tracks/$id')));
    final wave = await _waveform(dto.waveformUrl);
    final track = wave == null
        ? dto.toDomain()
        : dto.toDomain().copyWith(waveform: wave);

    return (track: track, comments: await commentsF, related: await relatedF);
  }

  Future<List<Comment>> _trackComments(String id) async {
    try {
      final data = await _get('/tracks/$id/comments', {
        'threaded': 0,
        'filter_replies': 1,
        'limit': 40,
      });
      return _page(data, CommentDto.fromJson).mapList((d) => d.toDomain());
    } catch (e, st) {
      _log.warning('comments failed for $id', e, st);
      return const [];
    }
  }

  @override
  Future<List<Track>> relatedTracks(String id) async {
    try {
      final data = await _get('/tracks/$id/related', {'limit': 12});
      return _page(data, TrackDto.fromJson).mapList((d) => d.toDomain());
    } catch (e, st) {
      _log.warning('related failed for $id', e, st);
      return const [];
    }
  }

  @override
  Future<ArtistProfile> artistProfile(String handle) async {
    final user = await _resolveUser(handle);
    final tracks = _page(
      await _get('/users/${user.id}/tracks', {'limit': 20}),
      TrackDto.fromJson,
    ).mapList((d) => d.toDomain());
    // Альбомы/плейлисты — реальные коллекции этого артиста по /users/{id}/…
    final albums = await _userPlaylists(user.id, albums: true);
    final playlists = await _userPlaylists(user.id);
    return (
      artist: user.toDomain(),
      tracks: tracks,
      albums: albums,
      playlists: playlists,
    );
  }

  @override
  Future<SearchResults> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      return (
        tracks: const <Track>[],
        artists: const <Artist>[],
        playlists: const <Collection>[],
      );
    }
    final tracksF = _get('/search/tracks', {'q': q, 'limit': 20});
    final usersF = _get('/search/users', {'q': q, 'limit': 15});
    final playlistsF = _get('/search/playlists', {'q': q, 'limit': 15});
    return (
      tracks: _page(
        await tracksF,
        TrackDto.fromJson,
      ).mapList((d) => d.toDomain()),
      artists: _page(
        await usersF,
        UserDto.fromJson,
      ).mapList((u) => u.toDomain()),
      playlists: _page(
        await playlistsF,
        PlaylistDto.fromJson,
      ).mapList((d) => d.toDomain()),
    );
  }

  /// Hydrate-весь плейлист: оставляем порядок из `tracks[]` ответа, для огрызков
  /// (без `title`) батчами тянем `/tracks?ids=…` (api-v2 принимает CSV id).
  @override
  Future<List<Track>> allPlaylistTracks(String id) async {
    final raw = asMap(await _get('/playlists/$id'));
    final tracksJson = asMapList(raw['tracks']);
    // Восстановим порядок плейлиста через map trackId → index.
    final order = <int, int>{};
    final hydrated = <Track>[];
    final missing = <int>[];
    for (var i = 0; i < tracksJson.length; i++) {
      final m = tracksJson[i];
      final tid = asInt(m['id']);
      order[tid] = i;
      if (m.containsKey('title')) {
        hydrated.add(TrackDto.fromJson(m).toDomain());
      } else {
        missing.add(tid);
      }
    }
    // Батчим запрос недостающих треков. 50 — обычный безопасный размер.
    const batch = 50;
    final fetched = <Track>[];
    for (var i = 0; i < missing.length; i += batch) {
      final ids = missing.skip(i).take(batch).join(',');
      try {
        final data = await _get('/tracks', {'ids': ids});
        if (data is List) {
          for (final t in data) {
            final m = asMap(t);
            if (m.containsKey('title')) {
              fetched.add(TrackDto.fromJson(m).toDomain());
            }
          }
        }
      } catch (e, st) {
        _log.warning('hydrate batch ($i+) failed', e, st);
      }
    }
    final all = [...hydrated, ...fetched];
    all.sort((a, b) {
      final ia = order[int.tryParse(a.id) ?? -1] ?? 1 << 30;
      final ib = order[int.tryParse(b.id) ?? -1] ?? 1 << 30;
      return ia.compareTo(ib);
    });
    return all;
  }

  @override
  Future<PlaylistDetail> playlist(String id) async {
    final dto = PlaylistDto.fromJson(asMap(await _get('/playlists/$id')));
    return (
      playlist: dto.toDomain(),
      tracks: [for (final t in dto.tracks) t.toDomain()],
    );
  }

  /// Транскодинг api-v2 — это указатель: GET по нему (с client_id) возвращает
  /// `{"url": "<playable m3u8/mp3>"}`. Этот URL и скармливаем just_audio.
  @override
  Future<String?> resolveStreamUrl(String transcodingUrl) async {
    Future<Response<dynamic>> call() async {
      final cid = await _ids.get();
      // Анонимный резолв (client_id) — без OAuth, чтобы плохой токен не ронял стрим.
      return _dio.get(transcodingUrl, queryParameters: {'client_id': cid});
    }

    try {
      Response<dynamic> res;
      try {
        res = await call();
      } on DioException catch (e) {
        if (e.response?.statusCode == 401) {
          await _ids.refresh();
          res = await call();
        } else {
          rethrow;
        }
      }
      final url = asMap(res.data)['url'];
      return (url is String && url.isNotEmpty) ? url : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> resolveUrl(String url) async {
    // Нормализуем: принимаем полные ссылки и голые soundcloud.com/… пути.
    var u = url.trim();
    if (u.isEmpty) return null;
    if (!u.startsWith('http')) {
      u = u.startsWith('soundcloud.com') ? 'https://$u' : u;
    }
    try {
      final data = asMap(await _get('/resolve', {'url': u}));
      final kind = data['kind'] as String?;
      switch (kind) {
        case 'track':
          return '/track/${data['id']}';
        case 'playlist':
        case 'system-playlist':
          return '/playlist/${data['id']}';
        case 'user':
          final permalink = data['permalink'] as String?;
          return (permalink == null || permalink.isEmpty)
              ? null
              : '/artist/${Uri.encodeComponent(permalink)}';
      }
    } catch (e, st) {
      _log.warning('resolveUrl failed: $u', e, st);
    }
    return null;
  }

  /// `/me` с переданным токеном: 200 + наличие `id` ⇒ токен пользовательский.
  @override
  Future<bool> verifyToken(String token) async {
    try {
      final cid = await _ids.get();
      final res = await _dio.get(
        '$_base/me',
        queryParameters: {'client_id': cid},
        options: Options(headers: {'Authorization': 'OAuth $token'}),
      );
      return asMap(res.data)['id'] != null;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<LikeOutcome> setLiked(String trackId, bool liked) async {
    if (!_authed) return LikeOutcome.failed;
    final id = await _meId();
    if (id == null) return LikeOutcome.failed;
    return writeOutcome(
      liked ? 'PUT' : 'DELETE',
      '/users/$id/track_likes/$trackId',
    );
  }

  // /users/{id}/track_reposts отдаёт обёртки `{created_at, track:{…}}`.
  Future<List<Track>> _meReposts([int limit = 200]) async {
    final id = await _meId();
    if (id == null) return const [];
    return _page(
      await _get('/users/$id/track_reposts', {'limit': limit}, true),
      (j) => TrackDto.fromJson(asMap(j['track'] ?? j)),
    ).mapList((d) => d.toDomain());
  }

  @override
  Future<Set<String>> repostedTrackIds() async {
    final tracks = await _tryAuthed(
      () => _meReposts(),
      () async => const <Track>[],
    );
    return {for (final t in tracks) t.id};
  }

  @override
  Future<LikeOutcome> setReposted(String trackId, bool reposted) async {
    if (!_authed) return LikeOutcome.failed;
    final id = await _meId();
    if (id == null) return LikeOutcome.failed;
    return writeOutcome(
      reposted ? 'PUT' : 'DELETE',
      '/users/$id/track_reposts/$trackId',
    );
  }
}
