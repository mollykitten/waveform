import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/recommendations/co_likers_source.dart';
import 'package:waveform_app/core/recommendations/co_likers_store.dart';
import 'package:waveform_app/shared/models/track.dart';

import 'support.dart';

typedef Like = ({String trackId, DateTime? likedAt});

class CfApi extends TestSoundcloud {
  List<Track> own = [for (var i = 0; i < 4; i++) realTrack('s$i')];
  final likers = <String, List<String>>{};
  final likes = <String, List<Like>>{};
  int likersCalls = 0;
  int userLikesCalls = 0;
  int hydrateCalls = 0;
  int rateLimited = 0;
  bool failUserLikes = false;
  bool failLikesPage = false;
  Set<String> failLikersFor = {};
  String? retryAfter;
  Completer<void>? gateLikes;
  Set<String> omit = {};
  final hydrated = <String>[];

  @override
  Future<({List<Track> tracks, String? nextHref})> likesPage({
    String? nextHref,
    int limit = 50,
  }) async {
    if (failLikesPage) throw StateError('network');
    final gate = gateLikes;
    if (gate != null) await gate.future;
    return (tracks: own, nextHref: null);
  }

  @override
  Future<List<String>> trackLikers(String trackId, {int limit = 50}) async {
    likersCalls++;
    if (rateLimited > 0) {
      rateLimited--;
      throw DioException(
        requestOptions: RequestOptions(),
        response: Response(
          requestOptions: RequestOptions(),
          statusCode: 429,
          headers: Headers.fromMap({
            if (retryAfter != null) 'retry-after': [retryAfter!],
          }),
        ),
      );
    }
    if (failLikersFor.contains(trackId)) throw StateError('network');
    return likers[trackId] ?? const [];
  }

  @override
  Future<List<Like>> userTrackLikes(String userId, {int limit = 200}) async {
    userLikesCalls++;
    if (failUserLikes) throw StateError('network');
    return likes[userId] ?? const [];
  }

  @override
  Future<List<Track>> tracksByIds(List<String> ids) async {
    hydrateCalls++;
    hydrated.addAll(ids);
    return [
      for (final id in ids)
        if (!omit.contains(id)) realTrack(id),
    ];
  }

  int get requests => 1 + likersCalls + userLikesCalls;
}

Like like(String id, int epochSeconds) => (
  trackId: id,
  likedAt: DateTime.fromMillisecondsSinceEpoch(
    epochSeconds * 1000,
    isUtc: true,
  ),
);

void main() {
  late Directory directory;
  late CfApi api;
  late CoLikersStore store;
  var now = DateTime.utc(2026, 10, 27, 12);
  CoLikersSource source({
    int maxRequests = 250,
    void Function(String)? onLog,
  }) => CoLikersSource(
    api: api,
    store: store,
    maxRequests: maxRequests,
    pause: Duration.zero,
    backoff: Duration.zero,
    now: () => now,
    onLog: onLog,
  );

  setUp(() async {
    now = DateTime.utc(2026, 10, 27, 12);
    directory = await Directory.systemTemp.createTemp('waveform-cf-');
    api = CfApi();
    store = CoLikersStore(directory: () async => directory);
  });
  tearDown(() async => directory.delete(recursive: true));

  void smallNeighbourhood() {
    api.likers['s0'] = ['900001', '900002', '42'];
    api.likers['s1'] = ['900001', '900002'];
    api.likers['s2'] = ['900003'];
    api.likers['s3'] = ['900001'];
    api.likes['900001'] = [like('x', 100), like('y', 50), like('s0', 70)];
    api.likes['900002'] = [like('x', 200), like('z', 10)];
    api.likes['900003'] = [like('never', 1)];
  }

  test('scores by neighbour weight, breaks ties by recency', () async {
    smallNeighbourhood();
    api.likes['900002']!.add(like('y2', 300));
    api.likes['900001']!.add(like('y2', 20));
    expect(await source().refresh('42', isCancelled: () => false), isTrue);
    final snapshot = (await store.read('42'))!;
    expect(snapshot.candidates.map((c) => c.trackId), ['y2', 'x', 'y', 'z']);
    // x and y2 both score 3 + 2; y2's newest neighbour like is later
    expect(snapshot.candidates.first.score, 5);
    expect(snapshot.candidates[1].score, 5);
    expect(snapshot.candidates.first.likedAt, 300);
    expect(snapshot.candidates[2].score, 3);
    expect(snapshot.candidates.map((c) => c.trackId), isNot(contains('s0')));
    expect(snapshot.candidates.map((c) => c.trackId), isNot(contains('never')));
  });

  test(
    'neighbours need two shared seeds; the user is not a neighbour',
    () async {
      smallNeighbourhood();
      await source().refresh('42', isCancelled: () => false);
      // 900003 shares one seed, '42' is the account itself: neither is fetched
      expect(api.userLikesCalls, 2);
    },
  );

  test('the cache holds track ids and scores, never other users', () async {
    smallNeighbourhood();
    await source().refresh('42', isCancelled: () => false);
    final raw = await File(
      '${directory.path}/co-likers-v1-42.json',
    ).readAsString();
    for (final foreign in ['900001', '900002', '900003']) {
      expect(raw, isNot(contains(foreign)));
    }
    final json = jsonDecode(raw) as Map<String, dynamic>;
    expect(
      json.keys,
      unorderedEquals(['version', 'identity', 'built_at', 'candidates']),
    );
    for (final row in json['candidates'] as List) {
      expect((row as Map).keys, unorderedEquals(['id', 'score', 't']));
    }
  });

  test('a full run stays inside the request budget', () async {
    api.own = [for (var i = 0; i < 50; i++) realTrack('s$i')];
    for (var i = 0; i < 50; i++) {
      api.likers['s$i'] = [
        for (var k = 0; k < 50; k++) '${910000 + (i * 7 + k) % 200}',
      ];
    }
    for (var u = 0; u < 200; u++) {
      api.likes['${910000 + u}'] = [
        for (var t = 0; t < 5; t++) like('c${u % 40}$t', 1000 + t),
      ];
    }
    final run = source();
    await run.refresh('42', isCancelled: () => false);
    expect(api.likersCalls, 50);
    expect(api.userLikesCalls, CoLikersSource.maxNeighbors);
    expect(api.requests, lessThanOrEqualTo(250));
    expect(run.lastRunRequests, api.requests);
    expect((await store.read('42'))!.candidates.length, lessThanOrEqualTo(300));
  });

  test('a budget too small for the run leaves the cache unwritten', () async {
    api.own = [for (var i = 0; i < 50; i++) realTrack('s$i')];
    for (var i = 0; i < 50; i++) {
      api.likers['s$i'] = [
        for (var k = 0; k < 50; k++) '${910000 + (i * 7 + k) % 200}',
      ];
    }
    for (var u = 0; u < 200; u++) {
      api.likes['${910000 + u}'] = [like('c${u % 40}', 1000)];
    }
    final run = source(maxRequests: 80);
    expect(await run.refresh('42', isCancelled: () => false), isFalse);
    expect(api.requests, 80);
    expect(run.lastRunRequests, 80);
    // a run that skipped most of its calls would be cached for a day as if
    // it were complete
    expect(await store.read('42'), isNull);
  });

  test('HTTP 429 backs off and retries, and retries are counted', () async {
    smallNeighbourhood();
    api.rateLimited = 2;
    final run = source();
    expect(await run.refresh('42', isCancelled: () => false), isTrue);
    expect(api.likersCalls, 4 + 2);
    expect(run.lastRunRequests, api.requests);
  });

  test('cancelling stops the run and writes nothing', () async {
    smallNeighbourhood();
    var polls = 0;
    final wrote = await source().refresh('42', isCancelled: () => ++polls > 4);
    expect(wrote, isFalse);
    expect(
      File('${directory.path}/co-likers-v1-42.json').existsSync(),
      isFalse,
    );
    expect(api.userLikesCalls, 0);
  });

  test('a fresh cache is reused; a stale one is refetched', () async {
    smallNeighbourhood();
    final run = source();
    await run.refresh('42', isCancelled: () => false);
    final before = api.requests;
    now = now.add(const Duration(hours: 1));
    expect(await run.refresh('42', isCancelled: () => false), isFalse);
    expect(api.requests, before);
    now = now.add(const Duration(hours: 25));
    expect(await run.refresh('42', isCancelled: () => false), isTrue);
    // a day later the neighbour data is fetched again, not rebuilt from memory
    expect(run.lastRunRequests, before);
    expect(api.likersCalls, 8);
  });

  test('a cancelled run resumes without refetching what it has', () async {
    smallNeighbourhood();
    final run = source();
    var polls = 0;
    await run.refresh('42', isCancelled: () => ++polls > 6);
    final file = File('${directory.path}/co-likers-v1-42.json');
    expect(file.existsSync(), isFalse);
    expect(api.likersCalls, greaterThan(0));
    await run.refresh('42', isCancelled: () => false);
    // the likers already fetched are not requested again
    expect(api.likersCalls, 4);
    expect(file.existsSync(), isTrue);
  });

  test('candidates hydrate once and skip excluded ids', () async {
    smallNeighbourhood();
    final run = source();
    await run.refresh('42', isCancelled: () => false);
    final tracks = await run.candidates('42', excluded: {'x'}, want: 10);
    expect(tracks.map((t) => t.id), ['y', 'z']);
    expect(api.hydrated, ['y', 'z']);
    await run.candidates('42', excluded: {'x'}, want: 10);
    expect(api.hydrateCalls, 1);
  });

  test('forget deletes one account cache', () async {
    smallNeighbourhood();
    await source().refresh('42', isCancelled: () => false);
    await store.forget('42');
    expect(await store.read('42'), isNull);
  });

  test('anonymous and invalid identities never run or write', () async {
    expect(
      await source().refresh('anonymous', isCancelled: () => false),
      isFalse,
    );
    expect(await source().refresh('../x', isCancelled: () => false), isFalse);
    expect(directory.listSync(), isEmpty);
    expect(api.likersCalls, 0);
  });

  test('a like without a timestamp still scores and loses ties', () async {
    smallNeighbourhood();
    api.likes['900001']!.add((trackId: 'undated', likedAt: null));
    expect(await source().refresh('42', isCancelled: () => false), isTrue);
    final ids = (await store.read(
      '42',
    ))!.candidates.map((c) => c.trackId).toList();
    // scored like any other like, but it loses every tie on recency
    expect(ids.indexOf('undated'), greaterThan(ids.indexOf('y')));
  });

  test('failed neighbour reads keep the previous cache', () async {
    smallNeighbourhood();
    final run = source();
    await run.refresh('42', isCancelled: () => false);
    final first = (await store.read('42'))!;
    now = now.add(const Duration(hours: 25));
    api.failUserLikes = true;
    expect(await run.refresh('42', isCancelled: () => false), isFalse);
    expect((await store.read('42'))!.builtAt, first.builtAt);
    expect((await store.read('42'))!.candidates, isNotEmpty);
    // not hammered again right away, retried once the pause has passed
    final calls = api.likersCalls;
    expect(await run.refresh('42', isCancelled: () => false), isFalse);
    expect(api.likersCalls, calls);
    api.failUserLikes = false;
    now = now.add(const Duration(minutes: 11));
    expect(await run.refresh('42', isCancelled: () => false), isTrue);
  });

  test('unplayable top candidates do not block the rest', () async {
    await store.write('42', now, [
      for (var i = 0; i < 8; i++) CoLikerCandidate('bad$i', 100.0 - i, 1),
      for (var i = 0; i < 4; i++) CoLikerCandidate('good$i', 50.0 - i, 1),
    ]);
    final run = source();
    bool usable(Track t) => !t.id.startsWith('bad');
    final first = await run.candidates('42', want: 3, usable: usable);
    expect(first.map((t) => t.id), ['good0', 'good1', 'good2']);
    final hydratedBefore = api.hydrated.length;
    final second = await run.candidates('42', want: 3, usable: usable);
    expect(second.map((t) => t.id), ['good0', 'good1', 'good2']);
    // the rejected ids are remembered, not hydrated again
    expect(api.hydrated.length, hydratedBefore);
    expect(api.hydrated.where((id) => id == 'bad0'), hasLength(1));
  });

  test('ids the api does not return are skipped from then on', () async {
    await store.write('42', now, [
      const CoLikerCandidate('hidden-1', 9, 1),
      const CoLikerCandidate('ok', 8, 1),
    ]);
    api.omit = {'hidden-1'};
    final run = source();
    expect((await run.candidates('42', want: 5)).map((t) => t.id), ['ok']);
    expect((await run.candidates('42', want: 5)).map((t) => t.id), ['ok']);
    expect(api.hydrated.where((id) => id == 'hidden-1'), hasLength(1));
  });

  test('429 that never lifts aborts the run and writes nothing', () async {
    smallNeighbourhood();
    api.rateLimited = 1000;
    final run = source();
    expect(await run.refresh('42', isCancelled: () => false), isFalse);
    // one call, retried the permitted number of times, then the run stops
    expect(api.likersCalls, CoLikersSource.maxRetries + 1);
    expect(api.userLikesCalls, 0);
    expect(run.lastRunRequests, 1 + CoLikersSource.maxRetries + 1);
    expect(await store.read('42'), isNull);
  });

  test('a skipped or aborted run leaves a log line', () async {
    smallNeighbourhood();
    final logs = <String>[];
    api.rateLimited = 1000;
    await source(onLog: logs.add).refresh('42', isCancelled: () => false);
    expect(logs.single, contains('run skipped (rate limited)'));

    logs.clear();
    api.rateLimited = 0;
    api.failLikersFor = {'s2', 's3'};
    await source(onLog: logs.add).refresh('42', isCancelled: () => false);
    expect(logs.single, contains('calls failed'));
    expect(logs.single, contains('previous cache kept'));

    logs.clear();
    api.failLikersFor = {};
    await source(
      onLog: logs.add,
    ).refresh('42', isCancelled: () => api.likersCalls > 0);
    expect(logs.single, contains('run cancelled'));
  });

  test('a Retry-After hint replaces the exponential wait', () async {
    smallNeighbourhood();
    api.rateLimited = 1;
    api.retryAfter = '0';
    final slow = CoLikersSource(
      api: api,
      store: store,
      pause: Duration.zero,
      backoff: const Duration(hours: 1),
      now: () => now,
    );
    expect(await slow.refresh('42', isCancelled: () => false), isTrue);
  });

  test('too many failed calls: no cache, retried after a pause', () async {
    smallNeighbourhood();
    api.failLikersFor = {'s2', 's3'};
    final run = source();
    expect(await run.refresh('42', isCancelled: () => false), isFalse);
    expect(await store.read('42'), isNull);
    final calls = api.requests;
    expect(await run.refresh('42', isCancelled: () => false), isFalse);
    expect(api.requests, calls);
    api.failLikersFor = {};
    now = now.add(const Duration(minutes: 11));
    expect(await run.refresh('42', isCancelled: () => false), isTrue);
  });

  test('a single failed call is tolerated', () async {
    api.own = [for (var i = 0; i < 10; i++) realTrack('s$i')];
    for (var i = 0; i < 10; i++) {
      api.likers['s$i'] = ['900001', '900002'];
    }
    api.likes['900001'] = [like('x', 1)];
    api.likes['900002'] = [like('x', 2)];
    api.failLikersFor = {'s4'};
    expect(await source().refresh('42', isCancelled: () => false), isTrue);
    expect((await store.read('42'))!.candidates.single.trackId, 'x');
  });

  test('a like missing a timestamp on every neighbour still builds', () async {
    api.own = [for (var i = 0; i < 3; i++) realTrack('s$i')];
    for (var i = 0; i < 3; i++) {
      api.likers['s$i'] = ['900001', '900002'];
    }
    api.likes['900001'] = [(trackId: 'q', likedAt: null)];
    api.likes['900002'] = [(trackId: 'q', likedAt: null)];
    expect(await source().refresh('42', isCancelled: () => false), isTrue);
    final row = (await store.read('42'))!.candidates.single;
    expect((row.trackId, row.score, row.likedAt), ('q', 6.0, 0));
  });

  test('cancelling once the write has begun removes the cache', () async {
    smallNeighbourhood();
    final late = _LateCancelStore(directory);
    final run = CoLikersSource(
      api: api,
      store: late,
      pause: Duration.zero,
      backoff: Duration.zero,
      now: () => now,
    );
    expect(await run.refresh('42', isCancelled: () => late.written), isFalse);
    expect(late.written, isTrue);
    expect(await store.read('42'), isNull);
  });

  test(
    'switching account mid-run ends it without touching the new one',
    () async {
      smallNeighbourhood();
      await store.write('43', now, [const CoLikerCandidate('mine', 4, 1)]);
      final gate = api.gateLikes = Completer<void>();
      final run = source();
      final first = run.refresh('42', isCancelled: () => false);
      await Future<void>.delayed(Duration.zero);
      // the app moves to another account while the first run waits on a request
      final other = await run.candidates('43', want: 5);
      gate.complete();
      expect(await first, isFalse);
      expect(other.map((t) => t.id), ['mine']);
      expect(await store.read('42'), isNull);
      // nothing of account 42 leaked into 43's session memory
      expect((await run.candidates('43', want: 5)).map((t) => t.id), ['mine']);
      expect(api.likersCalls, lessThanOrEqualTo(1));
    },
  );

  test('a failed first page ends the run quietly', () async {
    smallNeighbourhood();
    api.failLikesPage = true;
    expect(await source().refresh('42', isCancelled: () => false), isFalse);
    expect(await store.read('42'), isNull);
  });
}

/// Reports the moment the cache write starts, to cancel right after it.
class _LateCancelStore extends CoLikersStore {
  _LateCancelStore(Directory directory)
    : super(directory: () async => directory);
  bool written = false;

  @override
  Future<void> write(
    String identity,
    DateTime builtAt,
    List<CoLikerCandidate> candidates,
  ) async {
    await super.write(identity, builtAt, candidates);
    written = true;
  }
}
