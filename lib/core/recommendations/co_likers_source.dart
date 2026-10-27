import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';

import '../../shared/models/track.dart';
import '../api/soundcloud_api.dart';
import 'co_likers_store.dart';
import 'listening_event.dart';

/// Co-liker collaborative filtering as a background candidate source: likers
/// of the user's freshest likes, then neighbours who share at least two of
/// those seeds, then the neighbours' recent likes. Each candidate scores the
/// sum of the weights of the neighbours who liked it, a neighbour's weight
/// being the number of seeds it shares; the newest neighbour like breaks ties.
///
/// A run is bounded ([maxRequests] in total, paced, with backoff on HTTP 429)
/// and never touches the playback path. Other users' ids live in memory only
/// for the length of the app session; the disk cache keeps track ids and
/// scores.
class CoLikersSource {
  CoLikersSource({
    required this.api,
    required this.store,
    this.maxRequests = 250,
    this.pause = const Duration(milliseconds: 150),
    this.backoff = const Duration(seconds: 1),
    this.retryAfter = const Duration(minutes: 10),
    DateTime Function()? now,
    this.onLog,
  }) : _now = now ?? DateTime.now;

  final SoundcloudApi api;
  final CoLikersStore store;

  /// Hard cap on SoundCloud requests for one run, retries included.
  final int maxRequests;

  /// Minimum gap between two requests of a run.
  final Duration pause;

  /// First wait after HTTP 429; it doubles on each further attempt.
  final Duration backoff;

  /// A run that could not fetch any neighbour data is not retried for this
  /// long; the previous cache stays in place meanwhile.
  final Duration retryAfter;
  final DateTime Function() _now;
  final void Function(String message)? onLog;

  static const seedCount = 50;
  static const likersPerSeed = 50;
  static const minSharedSeeds = 2;
  static const maxNeighbors = 150;
  static const likesPerNeighbor = 200;
  static const maxRetries = 3;

  /// Longest `Retry-After` honoured, in seconds.
  static const maxRetryAfter = 30;

  /// A run that loses more than this share of its calls is not cached.
  static const maxFailedShare = .2;

  String? _memoryIdentity;
  final _likers = <String, List<String>>{};
  final _neighborLikes = <String, List<({String id, int at})>>{};
  final _hydrated = <String, Track>{};
  CoLikersSnapshot? _snapshot;
  DateTime? _failedAt;

  /// Candidates found unplayable or missing on hydration; never looked up again
  /// until the next run replaces the cache.
  final _unusable = <String>{};

  /// Number of requests the last run made (for logs and tests).
  int lastRunRequests = 0;

  void _bind(String identity) {
    if (_memoryIdentity == identity) return;
    _memoryIdentity = identity;
    _likers.clear();
    _neighborLikes.clear();
    _hydrated.clear();
    _unusable.clear();
    _snapshot = null;
    _failedAt = null;
  }

  /// Run now unless a cached run is still fresh. Returns whether it wrote a
  /// new cache. [isCancelled] is polled before every request, so a logout or
  /// account switch stops the run and nothing is written afterwards.
  Future<bool> refresh(
    String identity, {
    required bool Function() isCancelled,
  }) async {
    if (!validListeningIdentity(identity) || identity == 'anonymous') {
      return false;
    }
    _bind(identity);
    final current = _snapshot ?? await store.read(identity);
    // The account may have changed while the file was read.
    if (_memoryIdentity != identity) return false;
    _snapshot ??= current;
    if (current != null &&
        _now().difference(current.builtAt) < CoLikersStore.ttl) {
      return false;
    }
    // A stale cache means the neighbour data is a day old: fetch it afresh.
    // Without a cache the memory only holds a cancelled run's progress, which
    // the next run resumes.
    if (current != null) {
      _likers.clear();
      _neighborLikes.clear();
    }
    final failed = _failedAt;
    if (failed != null && _now().difference(failed) < retryAfter) return false;
    // A switch to another account mid-run ends it like a cancellation, so it
    // can never fill the new account's memory.
    bool cancelled() => isCancelled() || _memoryIdentity != identity;
    final run = _Run(this, identity, cancelled);
    final built = await run.execute();
    lastRunRequests = run.requests;
    if (cancelled()) return false;
    if (built == null) {
      _failedAt = _now();
      return false;
    }
    _failedAt = null;
    _unusable.clear();
    final at = _now();
    await store.write(identity, at, built);
    if (cancelled()) {
      await store.forget(identity);
      return false;
    }
    _snapshot = CoLikersSnapshot(at, built);
    onLog?.call(
      'co-likers: ${built.length} candidates from ${run.requests} requests',
    );
    return true;
  }

  /// Cached candidate tracks, best first, hydrated to full track objects.
  /// [excluded] ids are skipped before hydration. Candidates that are missing
  /// or rejected by [usable] are remembered and skipped from then on, and the
  /// scan moves down the ranking in batches of [want] until it has [want]
  /// tracks or has looked at [scan] candidates.
  Future<List<Track>> candidates(
    String identity, {
    Set<String> excluded = const {},
    int want = 15,
    int scan = 100,
    bool Function(Track track)? usable,
  }) async {
    if (!validListeningIdentity(identity) || identity == 'anonymous') {
      return const [];
    }
    _bind(identity);
    final snapshot = _snapshot ?? await store.read(identity);
    if (_memoryIdentity != identity) return const [];
    _snapshot ??= snapshot;
    if (snapshot == null) return const [];
    final pool = [
      for (final c in snapshot.candidates)
        if (!excluded.contains(c.trackId) && !_unusable.contains(c.trackId))
          c.trackId,
    ].take(scan).toList();
    final found = <Track>[];
    for (var i = 0; i < pool.length && found.length < want; i += want) {
      final batch = pool.skip(i).take(want).toList();
      await _hydrate(batch);
      for (final id in batch) {
        final track = _hydrated[id];
        if (track == null || (usable != null && !usable(track))) {
          _unusable.add(id);
        } else {
          found.add(track);
        }
      }
    }
    return found.take(want).toList();
  }

  Future<void> _hydrate(List<String> ids) async {
    final missing = [
      for (final id in ids)
        if (!_hydrated.containsKey(id)) id,
    ];
    if (missing.isEmpty) return;
    try {
      for (final track in await api.tracksByIds(missing)) {
        _hydrated[track.id] = track;
      }
    } catch (_) {
      onLog?.call('co-likers: hydration failed');
    }
    if (_hydrated.length > 600) _hydrated.clear();
  }
}

/// One bounded pass; holds the request counter and pacing.
class _Run {
  _Run(this.source, this.identity, this.isCancelled);
  final CoLikersSource source;
  final String identity;
  final bool Function() isCancelled;
  int requests = 0;
  bool _first = true;

  /// Calls tried and calls that gave nothing back (a failure other than 429,
  /// or a spent budget). A run that loses too many is not cached.
  int attempted = 0;
  int failed = 0;

  /// Set when HTTP 429 outlasted every retry: the run ends at once instead of
  /// spending the rest of its budget on waits.
  bool rateLimited = false;

  /// One logical request with its retries. Null means "skip".
  Future<T?> _call<T>(Future<T> Function() request) async {
    attempted++;
    final result = await _attempt(request);
    if (result == null && !isCancelled() && !rateLimited) failed++;
    return result;
  }

  /// One paced, counted request, retried with backoff on HTTP 429 (honouring
  /// a short `Retry-After`). Null: spent budget, cancellation or a failure.
  Future<T?> _attempt<T>(Future<T> Function() request) async {
    var wait = source.backoff;
    for (var attempt = 0; attempt <= CoLikersSource.maxRetries; attempt++) {
      if (isCancelled() || requests >= source.maxRequests) return null;
      if (!_first) await Future<void>.delayed(source.pause);
      _first = false;
      if (isCancelled()) return null;
      requests++;
      try {
        return await request();
      } on DioException catch (error) {
        if (error.response?.statusCode != 429) return null;
        final hinted = int.tryParse(
          error.response?.headers.value('retry-after') ?? '',
        );
        await Future<void>.delayed(
          hinted == null
              ? wait
              : Duration(
                  seconds: hinted.clamp(0, CoLikersSource.maxRetryAfter),
                ),
        );
        wait *= 2;
      } catch (_) {
        return null;
      }
    }
    rateLimited = true;
    return null;
  }

  Future<List<CoLikerCandidate>?> execute() async {
    final likes = await _call(() => source.api.likesPage(limit: 50));
    if (likes == null || rateLimited) return null;
    final seeds = [
      for (final track in likes.tracks.take(CoLikersSource.seedCount)) track.id,
    ];
    if (seeds.length < CoLikersSource.minSharedSeeds) return null;
    final seedSet = seeds.toSet();
    var likersSeen = 0;
    for (final seed in seeds) {
      if (source._likers.containsKey(seed)) continue;
      final users = await _call(
        () => source.api.trackLikers(seed, limit: CoLikersSource.likersPerSeed),
      );
      if (users != null) {
        source._likers[seed] = users;
        likersSeen++;
      }
      if (isCancelled() || rateLimited) return null;
    }
    final shared = <String, int>{};
    for (final seed in seeds) {
      for (final user in (source._likers[seed] ?? const <String>[]).toSet()) {
        if (user == identity) continue;
        shared[user] = (shared[user] ?? 0) + 1;
      }
    }
    final neighbors = [
      for (final entry in shared.entries)
        if (entry.value >= CoLikersSource.minSharedSeeds) entry,
    ]..sort((a, b) => b.value.compareTo(a.value));
    final chosen = neighbors.take(CoLikersSource.maxNeighbors).toList();
    if (chosen.isEmpty && likersSeen == 0) return null;
    var neighbourData = 0;
    for (final neighbor in chosen) {
      if (source._neighborLikes.containsKey(neighbor.key)) {
        neighbourData++;
        continue;
      }
      final rows = await _call(
        () => source.api.userTrackLikes(
          neighbor.key,
          limit: CoLikersSource.likesPerNeighbor,
        ),
      );
      if (rows != null) {
        neighbourData++;
        source._neighborLikes[neighbor.key] = [
          for (final row in rows)
            (
              id: row.trackId,
              at: (row.likedAt?.millisecondsSinceEpoch ?? 0) ~/ 1000,
            ),
        ];
      }
      if (isCancelled() || rateLimited) return null;
    }
    if (source._neighborLikes.length > 600) {
      source._neighborLikes.removeWhere(
        (user, _) => !chosen.any((e) => e.key == user),
      );
    }
    // Neighbours were found but none of their likes could be read: keep the
    // previous cache rather than replace it with an empty one.
    if (chosen.isNotEmpty && neighbourData == 0) return null;
    // A patchy run would be cached for a day as if it were complete.
    if (failed > attempted * CoLikersSource.maxFailedShare) return null;
    return _score(chosen, seedSet);
  }

  List<CoLikerCandidate> _score(
    List<MapEntry<String, int>> neighbors,
    Set<String> seedSet,
  ) {
    final score = <String, double>{};
    final newest = <String, int>{};
    for (final neighbor in neighbors) {
      final likes = source._neighborLikes[neighbor.key];
      if (likes == null) continue;
      final counted = <String>{};
      for (final like in likes) {
        if (seedSet.contains(like.id) || !counted.add(like.id)) continue;
        score[like.id] = (score[like.id] ?? 0) + neighbor.value;
        // a like without a timestamp counts as the oldest
        newest[like.id] = math.max(newest[like.id] ?? 0, like.at);
      }
    }
    final ranked = score.keys.toList()
      ..sort((a, b) {
        final byScore = score[b]!.compareTo(score[a]!);
        return byScore != 0 ? byScore : newest[b]!.compareTo(newest[a]!);
      });
    return [
      for (final id in ranked.take(source.store.maxCandidates))
        CoLikerCandidate(id, score[id]!, newest[id]!),
    ];
  }
}
