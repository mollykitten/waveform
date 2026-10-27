import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/recommendations/co_likers_source.dart';
import 'package:waveform_app/core/recommendations/co_likers_store.dart';
import 'package:waveform_app/shared/models/track.dart';

import 'support.dart';

typedef Like = ({Track track, DateTime? likedAt});

class CfApi extends TestSoundcloud {
  List<Track> own = [for (var i = 0; i < 4; i++) realTrack('s$i')];
  final likers = <String, List<String>>{};
  final likes = <String, List<Like>>{};
  int likersCalls = 0;
  int userLikesCalls = 0;
  int hydrateCalls = 0;
  int rateLimited = 0;
  final hydrated = <String>[];

  @override
  Future<({List<Track> tracks, String? nextHref})> likesPage({
    String? nextHref,
    int limit = 50,
  }) async => (tracks: own, nextHref: null);

  @override
  Future<List<String>> trackLikers(String trackId, {int limit = 50}) async {
    likersCalls++;
    if (rateLimited > 0) {
      rateLimited--;
      throw DioException(
        requestOptions: RequestOptions(),
        response: Response(requestOptions: RequestOptions(), statusCode: 429),
      );
    }
    return likers[trackId] ?? const [];
  }

  @override
  Future<List<Like>> userTrackLikes(String userId, {int limit = 200}) async {
    userLikesCalls++;
    return likes[userId] ?? const [];
  }

  @override
  Future<List<Track>> tracksByIds(List<String> ids) async {
    hydrateCalls++;
    hydrated.addAll(ids);
    return [for (final id in ids) realTrack(id)];
  }

  int get requests => 1 + likersCalls + userLikesCalls;
}

Like like(String id, int epochSeconds) => (
  track: realTrack(id),
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
  CoLikersSource source({int maxRequests = 250}) => CoLikersSource(
    api: api,
    store: store,
    maxRequests: maxRequests,
    pause: Duration.zero,
    backoff: Duration.zero,
    now: () => now,
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

  test('a smaller budget cuts the run short but keeps what it found', () async {
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
    await run.refresh('42', isCancelled: () => false);
    expect(api.requests, 80);
    expect(run.lastRunRequests, 80);
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
}
