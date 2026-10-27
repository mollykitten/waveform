import 'package:dio/dio.dart';

import '../../shared/models/track.dart';
import '../api/soundcloud_api.dart';
import 'models.dart';
import 'vector_engine.dart';

/// One bounded batch of genuine SoundCloud tracks, ranked on this device from
/// the related-track graph and local listening facts.
class RecommendationService {
  RecommendationService({
    required this.api,
    required this.vectorEngine,
    this.onWarning,
  });
  final SoundcloudApi api;
  final VectorEngine vectorEngine;

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
    final picked = await vectorEngine.generate(
      seeds: seeds.values.toList(),
      identity: listeningIdentity,
      excludedTrackIds: {
        ...excludedTrackIds,
        ...localExcludedTrackIds,
        ...likedIds,
      },
      check: check,
      limit: limit,
    );
    check();
    if (picked.isEmpty) throw WaveFailure.noTracks;
    return picked;
  }

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
