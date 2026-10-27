import '../../shared/mock/mock_data.dart';
import '../../shared/models/artist.dart';
import '../../shared/models/feed_post.dart';
import '../../shared/models/track.dart';
import 'soundcloud_api.dart';

/// Реализация на моках (текущий этап). Лёгкая задержка имитирует сеть,
/// чтобы UI сразу проектировался под async/loading-состояния.
class MockSoundcloudApi implements SoundcloudApi {
  const MockSoundcloudApi();

  Future<T> _delayed<T>(T value) =>
      Future.delayed(const Duration(milliseconds: 120), () => value);

  @override
  Future<HomeData> home() => _delayed((
    stream: Mock.stream,
    shelves: const [
      (title: 'more of what you like', items: Mock.moreYouLike),
      (title: 'recently played', items: Mock.recentlyPlayed),
      (title: 'mixed for you', items: Mock.mixedForYou),
      (title: 'albums for you', items: Mock.albums),
      (title: 'discover with stations', items: Mock.stations),
      (title: 'liked by', items: Mock.likedBy),
      (title: 'made for you', items: Mock.madeForYou),
      (title: 'new crew, suggested for you', items: Mock.newCrew),
    ],
  ));

  @override
  Future<LibraryData> library() => _delayed((
    recentlyPlayed: Mock.recentlyPlayed,
    likes: Mock.likes,
    playlists: Mock.playlists,
    albums: Mock.albums,
    stations: Mock.stations,
    following: Mock.newCrew,
    history: Mock.listeningHistory,
  ));

  @override
  Future<List<FeedPost>> feed() => _delayed(Mock.feed);

  @override
  Future<List<Track>> relatedTracks(String id) => _delayed(Mock.related(id));

  @override
  Future<TrackDetail> trackDetail(String id) {
    final t = Mock.trackById(id);
    return _delayed((
      track: t,
      comments: Mock.commentsFor(t),
      related: Mock.related(id),
    ));
  }

  @override
  Future<ArtistProfile> artistProfile(String handle) {
    final h = handle.hashCode.abs();
    return _delayed((
      artist: Artist(
        id: handle,
        handle: handle,
        followers: 1200 + h % 80000,
        trackCount: 12 + h % 120,
        verified: true,
      ),
      tracks: Mock.tracks,
      albums: Mock.albums,
      playlists: Mock.playlists,
    ));
  }

  @override
  Future<RailData> rail() => _delayed((
    me: null,
    likes: Mock.tracks.take(6).toList(),
    history: Mock.listeningHistory,
  ));

  @override
  Future<SearchResults> search(String query) {
    final q = query.toLowerCase();
    bool match(String s) => s.toLowerCase().contains(q);
    return _delayed((
      tracks: Mock.tracks
          .where((t) => match(t.title) || match(t.artist))
          .toList(),
      artists: Mock.artistsToFollow.where((a) => match(a.name)).toList(),
      playlists: Mock.playlists.where((p) => match(p.title)).toList(),
    ));
  }

  @override
  Future<PlaylistDetail> playlist(String id) {
    final p = Mock.playlists.firstWhere(
      (c) => c.id == id,
      orElse: () => Mock.playlists.first,
    );
    return _delayed((playlist: p, tracks: Mock.tracks));
  }

  /// Мок-плейлист уже полный.
  @override
  Future<List<Track>> allPlaylistTracks(String id) async => Mock.tracks;

  /// Мок-треки не проигрываемы — реального аудио нет.
  @override
  Future<String?> resolveStreamUrl(String transcodingUrl) async => null;

  @override
  Future<String?> resolveUrl(String url) async => null;

  @override
  Future<List<double>?> fetchWaveform(String url) async => null;

  /// В мок-режиме любой непустой токен «валиден» (paste-fallback в тестах).
  @override
  Future<bool> verifyToken(String token) async => token.isNotEmpty;

  @override
  Future<LikeOutcome> setLiked(String trackId, bool liked) async =>
      LikeOutcome.ok;

  @override
  Future<List<Track>> streamTracks({int limit = 40}) async =>
      Mock.listeningHistory.take(limit).toList();

  @override
  Future<List<String>> trackLikers(String trackId, {int limit = 50}) async =>
      const [];

  @override
  Future<List<({Track track, DateTime? likedAt})>> userTrackLikes(
    String userId, {
    int limit = 200,
  }) async => const [];

  @override
  Future<List<Track>> tracksByIds(List<String> ids) async => [
    for (final track in Mock.listeningHistory)
      if (ids.contains(track.id)) track,
  ];

  @override
  Future<List<Track>> historyPage({int limit = 50, int offset = 0}) async =>
      Mock.listeningHistory.skip(offset).take(limit).toList();

  @override
  Future<({List<Track> tracks, String? nextHref})> likesPage({
    String? nextHref,
    int limit = 50,
  }) async {
    // Имитируем курсор как simple "p:<n>" — на странице 0/1 отдаём mock.
    final page = nextHref == null ? 0 : int.tryParse(nextHref) ?? 0;
    final tracks = Mock.listeningHistory
        .skip(page * limit)
        .take(limit)
        .toList();
    final next = tracks.length < limit ? null : '${page + 1}';
    return (tracks: tracks, nextHref: next);
  }

  @override
  Future<Set<String>> repostedTrackIds() async => const {};

  @override
  Future<LikeOutcome> setReposted(String trackId, bool reposted) async =>
      LikeOutcome.ok;
}
