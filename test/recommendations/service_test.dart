import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/recommendations/co_likers_source.dart';
import 'package:waveform_app/core/recommendations/co_likers_store.dart';
import 'package:waveform_app/core/recommendations/listening_event.dart';
import 'package:waveform_app/core/recommendations/listening_store.dart';
import 'package:waveform_app/core/recommendations/models.dart';
import 'package:waveform_app/core/recommendations/recommendation_service.dart';
import 'package:waveform_app/core/recommendations/stream_source.dart';
import 'package:waveform_app/core/recommendations/vector_engine.dart';
import 'package:waveform_app/core/recommendations/vector_store.dart';
import 'package:waveform_app/shared/models/track.dart';

import 'support.dart';

class ServiceApi extends TestSoundcloud {
  final related = <String, List<Track>>{};
  final warnings = <String>[];
  bool failLikes = false;
  List<Track> likes = [for (var i = 0; i < 30; i++) realTrack('like$i')];
  String? likesNext;
  List<Track> stream = [];
  bool failStream = false;
  int streamCalls = 0;
  int likesCalls2 = 0;

  @override
  Future<List<Track>> relatedTracks(String id) async => related[id] ?? [];

  @override
  Future<List<Track>> streamTracks({int limit = 40}) async {
    streamCalls++;
    if (failStream) throw StateError('PRIVATE STREAM ERROR');
    return stream.take(limit).toList();
  }

  @override
  Future<List<Track>> tracksByIds(List<String> ids) async => [
    for (final id in ids)
      if (!id.startsWith('hidden')) realTrack(id, artist: 'cf-$id'),
  ];

  @override
  Future<({List<Track> tracks, String? nextHref})> likesPage({
    String? nextHref,
    int limit = 50,
  }) async {
    likesCalls2++;
    if (failLikes) throw StateError('PRIVATE TRANSPORT ERROR');
    return (tracks: likes, nextHref: nextHref == null ? likesNext : null);
  }
}

void main() {
  late Directory directory;
  late ServiceApi api;
  late RecommendationService service;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('waveform-service');
    api = ServiceApi()..tracks = [];
    service = RecommendationService(
      api: api,
      onWarning: api.warnings.add,
      vectorEngine: VectorEngine(
        api: api,
        store: VectorStore(directory: () async => directory),
        listening: ListeningStore(directory: () async => directory),
      ),
    );
  });
  tearDown(() async => directory.delete(recursive: true));

  Future<List<Recommendation>> generate({
    CancelToken? token,
    Set<String> excluded = const {},
  }) => service.generate(
    listeningIdentity: '1',
    cancelToken: token ?? CancelToken(),
    currentTrack: realTrack('current'),
    excludedTrackIds: excluded,
  );

  test('ranks only real related tracks', () async {
    api.related['current'] = [realTrack('a'), realTrack('b')];
    final result = await generate();
    expect(result.map((r) => r.track.id), unorderedEquals(['a', 'b']));
  });

  test('blocked tracks never reach the wave', () async {
    api.related['current'] = [realTrack('blocked', blocked: true)];
    api.related['like0'] = [realTrack('ok')];
    final result = await generate();
    expect(result.map((r) => r.track.id), ['ok']);
  });

  test('liked, given and queued tracks are excluded', () async {
    api.related['current'] = [
      realTrack('like5'),
      realTrack('queued'),
      realTrack('fresh'),
    ];
    final result = await generate(excluded: {'queued'});
    expect(result.map((r) => r.track.id), ['fresh']);
  });

  test('later like pages are drained for exclusion once per window', () async {
    api.likesNext = 'next';
    api.related['current'] = [realTrack('a')];
    await generate();
    final first = api.likesCalls2;
    expect(first, 2);
    // the cached set is reused; only the first page is fetched again
    await generate().then((_) {}, onError: (_) {});
    expect(api.likesCalls2, first + 1);
  });

  test('a cancelled token stops before any request', () async {
    final token = CancelToken()..cancel();
    await expectLater(generate(token: token), throwsA(WaveFailure.cancelled));
    expect(api.likesCalls2, 0);
  });

  test('source errors are safe', () async {
    api.failLikes = true;
    await expectLater(generate(), throwsA(WaveFailure.source));
  });

  test('an empty pool fails visibly', () async {
    api.tracks = [];
    await expectLater(generate(), throwsA(WaveFailure.noTracks));
  });

  group('three sources', () {
    late CoLikersStore cfStore;
    late RecommendationService full;
    setUp(() async {
      cfStore = CoLikersStore(directory: () async => directory);
      await cfStore.write('1', DateTime.now(), [
        for (var i = 0; i < 12; i++) CoLikerCandidate('c$i', 20.0 - i, 100 - i),
      ]);
      api.related['current'] = [
        for (var i = 0; i < 12; i++) realTrack('r$i', artist: 'rel$i'),
      ];
      api.stream = [
        for (var i = 0; i < 12; i++) realTrack('s$i', artist: 'str$i'),
      ];
      full = RecommendationService(
        api: api,
        onWarning: api.warnings.add,
        streamSource: StreamSource(api: api),
        coLikers: CoLikersSource(api: api, store: cfStore),
        vectorEngine: VectorEngine(
          api: api,
          store: VectorStore(directory: () async => directory),
          listening: ListeningStore(directory: () async => directory),
        ),
      );
    });

    Future<List<Recommendation>> batch({int limit = 20}) => full.generate(
      listeningIdentity: '1',
      cancelToken: CancelToken(),
      currentTrack: realTrack('current'),
      limit: limit,
    );

    Map<WaveSource, int> counts(List<Recommendation> items) => {
      for (final s in WaveSource.values)
        s: items.where((i) => i.source == s).length,
    };

    test('related, stream and co-likers share a batch by quota', () async {
      final result = await batch();
      expect(result, hasLength(20));
      final c = counts(result.take(8).toList());
      expect(c[WaveSource.related], 4);
      expect(c[WaveSource.stream], 2);
      expect(c[WaveSource.coLikers], 2);
      for (final item in result) {
        expect(item.reason, item.source.reason);
      }
    });

    test('likes, seeds, unplayable and blocked tracks are dropped', () async {
      api.stream = [
        realTrack('like3', artist: 'a1'),
        realTrack('current', artist: 'a2'),
        realTrack('s-blocked', blocked: true, artist: 'a3'),
        realTrack('s-encrypted', playable: false, artist: 'a4'),
        realTrack('s-ok', artist: 'a5'),
      ];
      await cfStore.write('1', DateTime.now(), [
        const CoLikerCandidate('like4', 50, 1),
        const CoLikerCandidate('hidden-cf', 40, 1),
        const CoLikerCandidate('c-ok', 30, 1),
      ]);
      final result = await batch();
      final streamIds = [
        for (final r in result)
          if (r.source == WaveSource.stream) r.track.id,
      ];
      expect(streamIds, ['s-ok']);
      final coIds = [
        for (final r in result)
          if (r.source == WaveSource.coLikers) r.track.id,
      ];
      expect(coIds, ['c-ok']);
    });

    test('a failing stream never fails the wave', () async {
      api.failStream = true;
      final result = await batch();
      expect(counts(result)[WaveSource.stream], 0);
      expect(counts(result)[WaveSource.related], greaterThan(0));
      expect(api.warnings.join(), isNot(contains('PRIVATE')));
    });

    test('no cached co-likers yet: related and stream still play', () async {
      await cfStore.forget('1');
      final fresh = RecommendationService(
        api: api,
        streamSource: StreamSource(api: api),
        coLikers: CoLikersSource(api: api, store: cfStore),
        vectorEngine: VectorEngine(
          api: api,
          store: VectorStore(directory: () async => directory),
          listening: ListeningStore(directory: () async => directory),
        ),
      );
      final result = await fresh.generate(
        listeningIdentity: '1',
        cancelToken: CancelToken(),
        currentTrack: realTrack('current'),
      );
      expect(counts(result)[WaveSource.coLikers], 0);
      expect(counts(result)[WaveSource.stream], greaterThan(0));
    });

    test('a failing stream is not retried on every refill', () async {
      api.failStream = true;
      await batch();
      await batch();
      expect(api.streamCalls, 1);
    });

    test('the stream is fetched once for repeated refills', () async {
      await batch();
      await batch();
      expect(api.streamCalls, 1);
    });

    test('obscure tracks: demoted a few places, never dropped', () {
      Recommendation rec(String id, {int plays = 1000}) => Recommendation(
        realTrack(id, plays: plays, likes: 0),
        'r',
        source: WaveSource.stream,
      );
      final ids = RecommendationService.demoteObscure([
        rec('1', plays: 15),
        rec('2'),
        rec('3', plays: 40),
        rec('4'),
      ]).map((r) => r.track.id);
      expect(ids, ['2', '4', '1', '3']);
    });

    test('obscure penalty grows with skipped obscure tracks only', () {
      ListeningEvent event(String id, int heardMs, bool obscure) =>
          ListeningEvent(
            sessionId: 's$id',
            identity: 'anonymous',
            trackId: id,
            durationMs: 200000,
            heardMs: heardMs,
            finalPositionMs: heardMs,
            seekCount: 0,
            startedAt: DateTime.utc(2026),
            endedAt: DateTime.utc(2026),
            cause: ListeningTransitionCause.manualNext,
            obscure: obscure,
          );
      expect(VectorEngine.obscurePenalty(const []), closeTo(.85, 1e-9));
      final skips = [for (var i = 0; i < 6; i++) event('$i', 8000, true)];
      expect(VectorEngine.obscurePenalty(skips), lessThan(.55));
      final ordinary = [for (var i = 0; i < 6; i++) event('$i', 8000, false)];
      expect(VectorEngine.obscurePenalty(ordinary), closeTo(.85, 1e-9));
    });

    test('playability: only a playable, unblocked track is eligible', () {
      expect(VectorEngine.eligible(realTrack('1')), isTrue);
      expect(VectorEngine.eligible(realTrack('1', blocked: true)), isFalse);
      expect(VectorEngine.eligible(realTrack('1', playable: false)), isFalse);
    });
  });
}
