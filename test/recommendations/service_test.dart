import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/recommendations/listening_store.dart';
import 'package:waveform_app/core/recommendations/models.dart';
import 'package:waveform_app/core/recommendations/recommendation_service.dart';
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
  int likesCalls2 = 0;

  @override
  Future<List<Track>> relatedTracks(String id) async => related[id] ?? [];

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
}
