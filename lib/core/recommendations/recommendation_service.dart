import 'package:dio/dio.dart';

import '../../shared/models/track.dart';
import '../api/soundcloud_api.dart';
import 'co_likers_source.dart';
import 'models.dart';
import 'stream_source.dart';
import 'vector_engine.dart';
import 'wave_blend.dart';

/// One bounded batch of genuine SoundCloud tracks. Candidates come from three
/// sources — the related-track graph (ranked on this device from local
/// listening facts), the home stream and co-likers — and are interleaved by
/// source rather than scored on one scale.
class RecommendationService {
  RecommendationService({
    required this.api,
    required this.vectorEngine,
    this.streamSource,
    this.coLikers,
    this.onWarning,
  });
  final SoundcloudApi api;
  final VectorEngine vectorEngine;
  final StreamSource? streamSource;
  final CoLikersSource? coLikers;

  /// Receives non-fatal notes, e.g. a partial likes load.
  final void Function(String message)? onWarning;

  /// Likes beyond 50 x this many pages are not excluded (known limit: 2000).
  static const maxLikePages = 40;

  Future<List<Recommendation>> generate({
    required String listeningIdentity,
    required CancelToken cancelToken,
    Track? currentTrack,
    Set<String> excludedTrackIds = const {},
    Set<String> localExcludedTrackIds = const {},
    void Function()? checkCurrent,
    int limit = 10,
  }) async {
    void check() {
      if (cancelToken.isCancelled) throw WaveFailure.cancelled;
      checkCurrent?.call();
    }

    check();
    final likedIds = <String>{};
    final seeds = <String, Track>{};
    void addSeeds(Iterable<Track> tracks) {
      for (final track in tracks) {
        if (seeds.length >= 30) break;
        seeds.putIfAbsent(track.id, () => track);
      }
    }

    if (currentTrack != null) addSeeds([currentTrack]);
    try {
      final likes = await api
          .likesPage(limit: 50)
          .timeout(const Duration(seconds: 25));
      check();
      likedIds.addAll(likes.tracks.map((t) => t.id));
      addSeeds(likes.tracks.take(20));
      final history = await api
          .historyPage(limit: 10)
          .timeout(const Duration(seconds: 25));
      check();
      addSeeds(history.take(10));
      await _drainLikes(listeningIdentity, likes.nextHref, likedIds, check);
    } on WaveFailure {
      rethrow;
    } catch (_) {
      throw WaveFailure.source;
    }
    check();
    if (seeds.isEmpty) throw WaveFailure.noTracks;
    final excluded = {
      ...excludedTrackIds,
      ...localExcludedTrackIds,
      ...likedIds,
    };
    final related = await vectorEngine.generate(
      seeds: seeds.values.toList(),
      identity: listeningIdentity,
      excludedTrackIds: excluded,
      check: check,
      limit: limit,
    );
    check();
    final hidden = {
      ...excluded,
      ...seeds.keys,
      ...await vectorEngine.memoryExclusions(listeningIdentity),
    };
    check();
    final stream = await _streamCandidates(listeningIdentity, hidden);
    check();
    final coLiked = await _coLikerCandidates(listeningIdentity, hidden, limit);
    check();
    final blended = blendBySource({
      WaveSource.related: related,
      WaveSource.stream: stream,
      WaveSource.coLikers: coLiked,
    }, limit: limit);
    if (blended.isEmpty) throw WaveFailure.noTracks;
    return blended;
  }

  Future<List<Recommendation>> _streamCandidates(
    String identity,
    Set<String> hidden,
  ) async => [
    for (final track in await streamSource?.candidates(identity) ?? <Track>[])
      if (VectorEngine.eligible(track) && !hidden.contains(track.id))
        Recommendation(
          track,
          WaveSource.stream.reason,
          source: WaveSource.stream,
        ),
  ];

  Future<List<Recommendation>> _coLikerCandidates(
    String identity,
    Set<String> hidden,
    int limit,
  ) async => [
    for (final track
        in await coLikers?.candidates(
              identity,
              excluded: hidden,
              want: limit * 2,
            ) ??
            <Track>[])
      if (VectorEngine.eligible(track) && !hidden.contains(track.id))
        Recommendation(
          track,
          WaveSource.coLikers.reason,
          source: WaveSource.coLikers,
        ),
  ];

  final _likesCache = <String, ({Set<String> ids, DateTime expires})>{};

  /// Collect the remaining liked ids for exclusion: at most [maxLikePages]
  /// pages and ten seconds overall. A full set is reused for 15 minutes and a
  /// partial one for 2, so refills do not repeat the walk. A timeout stops
  /// the loop; late pages are never added afterwards.
  Future<void> _drainLikes(
    String key,
    String? cursor,
    Set<String> into,
    void Function() check,
  ) async {
    final cached = _likesCache[key];
    if (cached != null && cached.expires.isAfter(DateTime.now())) {
      into.addAll(cached.ids);
      return;
    }
    final drained = <String>{};
    var stopped = false;
    var complete = true;
    Future<void> pages() async {
      var next = cursor;
      for (var page = 1; next != null && page < maxLikePages; page++) {
        if (stopped) return;
        final result = await api.likesPage(nextHref: next, limit: 50);
        if (stopped) return;
        check();
        drained.addAll(result.tracks.map((t) => t.id));
        next = result.tracks.isEmpty ? null : result.nextHref;
      }
      // Running out of pages at the cap leaves older likes unknown.
      if (next != null) complete = false;
    }

    try {
      await pages().timeout(const Duration(seconds: 10));
    } on WaveFailure {
      stopped = true;
      rethrow;
    } catch (error) {
      stopped = true;
      complete = false;
      onWarning?.call('liked tracks only partly loaded: ${error.runtimeType}');
    }
    into.addAll(drained);
    _likesCache[key] = (
      ids: Set.of(drained),
      expires: DateTime.now().add(
        complete ? const Duration(minutes: 15) : const Duration(minutes: 2),
      ),
    );
  }
}
