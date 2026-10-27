import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/recommendations/ai_client.dart';
import 'package:waveform_app/core/recommendations/listening_event.dart';
import 'package:waveform_app/core/recommendations/listening_store.dart';
import 'package:waveform_app/core/recommendations/models.dart';
import 'package:waveform_app/core/recommendations/seen_store.dart';
import 'package:waveform_app/core/recommendations/recommendation_service.dart';
import 'package:waveform_app/core/recommendations/vector_engine.dart';
import 'package:waveform_app/core/recommendations/vector_store.dart';
import 'package:waveform_app/shared/models/track.dart';

import 'support.dart';

class GraphApi extends TestSoundcloud {
  final neighborhoods = <String, List<Track>>{};
  final relatedCalls = <String>[];
  Completer<List<Track>>? pending;
  bool failRelated = false;

  @override
  Future<List<Track>> relatedTracks(String id) async {
    relatedCalls.add(id);
    if (failRelated) throw StateError('transport details');
    return pending?.future ?? neighborhoods[id] ?? [];
  }
}

class CleanupFailureFile implements File {
  CleanupFailureFile(this.delegate);
  final File delegate;
  @override
  String get path => delegate.path;
  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => delegate.writeAsString(
    contents,
    mode: mode,
    encoding: encoding,
    flush: flush,
  );
  @override
  Future<File> rename(String newPath) => delegate.rename(newPath);
  @override
  Future<bool> exists() => throw const FileSystemException('cleanup failed');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final now = DateTime.utc(2026, 10, 25);
ListeningEvent event(
  String track, {
  String identity = '1',
  String session = 'session',
  ListeningTransitionCause cause = ListeningTransitionCause.naturalCompletion,
  int heard = 100000,
  int seeks = 0,
  int daysAgo = 0,
}) => ListeningEvent(
  sessionId: session,
  identity: identity,
  trackId: track,
  durationMs: 120000,
  heardMs: heard,
  finalPositionMs: heard,
  seekCount: seeks,
  startedAt: now.subtract(Duration(days: daysAgo, minutes: 2)),
  endedAt: now.subtract(Duration(days: daysAgo)),
  cause: cause,
);

void main() {
  late Directory directory;
  late GraphApi api;
  late ListeningStore facts;
  late VectorStore store;
  late VectorEngine engine;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('waveform-vectors-');
    api = GraphApi();
    facts = ListeningStore(directory: () async => directory);
    store = VectorStore(directory: () async => directory);
    engine = VectorEngine(
      api: api,
      store: store,
      listening: facts,
      now: () => now,
    );
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'unknown graph context keeps direct self-seed listening evidence',
    () async {
      await facts.append(event('x'));
      api.neighborhoods['seedB'] = [realTrack('b')];
      await engine.generate(
        seeds: [realTrack('seedB')],
        identity: '1',
        excludedTrackIds: {},
        check: () {},
      );
      final old = await store.readSnapshot('1');
      // A heard track is itself a seed now, so its own interest is known.
      expect(old.attributions['session']!.weights, {'x': 1.0});
      api.neighborhoods['x'] = [realTrack('a')];
      await engine.generate(
        seeds: [
          realTrack('x', artist: 'x artist'),
          realTrack('seedB', artist: 'b artist'),
        ],
        identity: '1',
        excludedTrackIds: {},
        check: () {},
      );
      final snapshot = await store.readSnapshot('1');
      final profiles = engine.interests(
        ['x', 'seedB'],
        snapshot.vectors,
        await facts.read('1'),
        '1',
        attributions: snapshot.attributions,
      );
      expect(snapshot.attributions['session']!.weights, {'x': 1.0});
      expect(profiles.map((p) => p.support), [2, 1]);
      final selfAttributed = engine.interests(
        ['x', 'seedB'],
        snapshot.vectors,
        await facts.read('1'),
        '1',
        attributions: {
          'session': VectorProvenance({'x': 1}, now),
        },
      );
      expect(selfAttributed.map((p) => p.support), [2, 1]);
    },
  );

  test(
    'a pending related response cannot invent earlier session context',
    () async {
      var clock = now.subtract(const Duration(minutes: 3));
      engine = VectorEngine(
        api: api,
        store: store,
        listening: facts,
        now: () => clock,
      );
      api.pending = Completer<List<Track>>();
      Future<List<Recommendation>> batch() => engine.generate(
        seeds: [realTrack('seed')],
        identity: '1',
        excludedTrackIds: {},
        check: () {},
      );
      final pending = batch();
      while (api.relatedCalls.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      // This session began two minutes ago, after request start but before
      // the first observation of x in the delayed response one minute ago.
      final earlierSession = event(
        'x',
        session: 'during_request',
        heard: 10000,
        cause: ListeningTransitionCause.manualNext,
      );
      clock = now.subtract(const Duration(minutes: 1));
      api.pending!.complete([realTrack('x')]);
      await pending;
      clock = now;
      await facts.append(earlierSession);
      api.pending = null;
      api.neighborhoods['seed'] = [realTrack('x')];
      await batch();
      final snapshot = await store.readSnapshot('1');
      expect(snapshot.attributions['during_request']!.weights, isEmpty);
      final profile = engine.interests(
        ['seed'],
        snapshot.vectors,
        await facts.read('1'),
        '1',
        attributions: snapshot.attributions,
      );
      expect(profile.single.support, 1);
    },
  );

  for (final activeDuringRefresh in [false, true]) {
    test('immutable feedback attribution across three generations and reload '
        '(active during refresh: $activeDuringRefresh)', () async {
      var clock = now.subtract(const Duration(minutes: 10));
      engine = VectorEngine(
        api: api,
        store: store,
        listening: facts,
        now: () => clock,
      );
      final seeds = [
        realTrack('seedA', artist: 'seed artist A'),
        realTrack('seedB', artist: 'seed artist B'),
      ];
      api.neighborhoods['seedA'] = [realTrack('x'), realTrack('a')];
      api.neighborhoods['seedB'] = [realTrack('b')];
      Future<List<Recommendation>> batch(VectorEngine value) => value.generate(
        seeds: seeds,
        identity: '1',
        excludedTrackIds: {},
        check: () {},
      );
      await batch(engine);
      final skipped = event(
        'x',
        session: 'skip',
        heard: 10000,
        cause: ListeningTransitionCause.manualNext,
      );
      final unknown = event(
        'y',
        session: 'unknown',
        heard: 10000,
        cause: ListeningTransitionCause.manualNext,
      );
      if (!activeDuringRefresh) {
        await facts.append(skipped);
        await facts.append(unknown);
      }
      api.neighborhoods['seedA'] = [realTrack('a')];
      api.neighborhoods['seedB'] = [
        realTrack('x'),
        realTrack('b'),
        realTrack('y'),
      ];
      clock = activeDuringRefresh
          ? now.subtract(const Duration(minutes: 1))
          : now.add(const Duration(minutes: 1));
      await batch(engine);
      if (activeDuringRefresh) {
        await facts.append(skipped);
        await facts.append(unknown);
      }
      clock = now.add(const Duration(minutes: 2));
      await batch(engine);
      final restored = VectorEngine(
        api: api,
        store: VectorStore(directory: () async => directory),
        listening: ListeningStore(directory: () async => directory),
        now: () => clock,
      );
      final result = await batch(restored);
      final snapshot = await restored.store.readSnapshot('1');
      // A skipped track sits out its cooldown, so its vector stays frozen.
      expect(
        snapshot.vectors['x']!.weights.keys,
        activeDuringRefresh ? ['seedB'] : ['seedA'],
      );
      expect(snapshot.attributions['skip']!.weights.keys, ['seedA']);
      expect(snapshot.attributions['unknown']!.weights, isEmpty);
      final profiles = restored.interests(
        ['seedA', 'seedB'],
        snapshot.vectors,
        await facts.read('1'),
        '1',
        attributions: snapshot.attributions,
      );
      expect(profiles.first.support, .1);
      expect(profiles.last.support, 1);
      expect(result.first.track.id, 'b');
      expect(await restored.store.read('2'), isEmpty);
    });
  }

  test(
    'temporary cleanup failure preserves a successfully replaced cache',
    () async {
      final errors = <String>[];
      final cache = VectorStore(
        directory: () async => directory,
        onFailure: errors.add,
      );
      final target = File('${directory.path}/related-vectors-v1-1.json');
      final temporary = File('${target.path}.tmp');
      await IOOverrides.runZoned(
        () => cache.write('1', {
          'saved': VectorProvenance({'seed': 1}, now),
        }, check: () {}),
        createFile: (path) =>
            path.endsWith('.tmp') ? CleanupFailureFile(temporary) : target,
      );
      expect((await cache.read('1')).keys, ['saved']);
      expect(errors, ['local vector cache unavailable']);
    },
  );

  test(
    'real edge coordinates normalize and overlapping neighborhoods agree',
    () {
      final shared = StructuralVector({'seedA': 1, 'seedB': .5});
      expect(shared.weights.keys, ['seedA', 'seedB']);
      expect(
        shared.weights.values.fold<double>(0, (s, v) => s + v * v),
        closeTo(1, 1e-9),
      );
      expect(
        shared.cosine(StructuralVector({'seedA': 1})),
        closeTo(1 / math.sqrt(1.25), 1e-9),
      );
      expect(shared.cosine(StructuralVector({'unrelated': 1})), 0);
      expect(shared.cosine(shared), closeTo(1, 1e-9));
    },
  );

  test(
    'replayed feedback boosts one interest, suppresses skips, keeps diversity',
    () {
      final provenance = {
        'a': VectorProvenance({'seedA': 1}, now),
        'b': VectorProvenance({'seedB': 1}, now),
      };
      final positive = event('b', session: 'positive');
      final skip = event(
        'a',
        session: 'skip',
        cause: ListeningTransitionCause.manualNext,
        heard: 10000,
      );
      final profiles = engine.interests(
        ['seedA', 'seedB'],
        provenance,
        [positive, positive, skip],
        '1',
      );
      expect(profiles.first.support, .1);
      expect(profiles.last.support, 2);
      expect(profiles.last.observations, 1);
      final tracks = [
        for (var i = 0; i < 12; i++)
          realTrack('${i < 6 ? 'a' : 'b'}$i', artist: 'artist$i'),
      ];
      final vectors = {
        for (final t in tracks)
          t.id: StructuralVector({t.id.startsWith('a') ? 'seedA' : 'seedB': 1}),
      };
      final ranked = engine.rank(tracks, vectors, profiles);
      expect(ranked.first.id, startsWith('b'));
      expect(ranked.where((t) => t.id.startsWith('a')), isNotEmpty);
      expect(
        ranked.take(4).where((t) => t.id.startsWith('b')).length,
        greaterThan(ranked.take(4).where((t) => t.id.startsWith('a')).length),
      );
      final neutral = engine.interests(
        ['seedA', 'seedB'],
        provenance,
        [
          event('a', cause: ListeningTransitionCause.unplayable, heard: 10000),
          event(
            'b',
            session: 'seek',
            cause: ListeningTransitionCause.manualNext,
            heard: 10000,
            seeks: 1,
          ),
        ],
        '1',
      );
      expect(neutral.map((p) => p.support), [1.0, 1.0]);
      final old = engine.interests(
        ['seedB'],
        provenance,
        [event('b', daysAgo: 30)],
        '1',
      );
      expect(old.single.support, closeTo(1.5, .001));
    },
  );

  test(
    'cold start caps retrieval, merges overlap, excludes ids and artists',
    () async {
      final seeds = [
        for (var i = 0; i < 20; i++)
          realTrack('seed$i', artist: 'seedartist$i'),
      ];
      for (final seed in seeds) {
        api.neighborhoods[seed.id] = [
          realTrack('shared', artist: 'shared'),
          realTrack('excluded'),
          realTrack('blocked', blocked: true),
          for (var i = 0; i < 20; i++)
            realTrack('${seed.id}_$i', artist: 'duplicate'),
        ];
      }
      final result = await engine.generate(
        seeds: seeds,
        identity: '1',
        excludedTrackIds: {'excluded'},
        check: () {},
      );
      expect(api.relatedCalls.length, 6);
      expect(result.map((r) => r.track.id).toSet().length, result.length);
      expect(
        result.any((r) => ['excluded', 'blocked'].contains(r.track.id)),
        isFalse,
      );
      expect(result.where((r) => r.track.artist == 'duplicate').length, 2);
      final cached = await store.read('1');
      expect(
        cached['shared']!.weights.keys.toSet(),
        seeds.take(6).map((t) => t.id).toSet(),
      );
      expect(cached.keys.any((id) => id.endsWith('_19')), isFalse);
      expect(cached.containsKey('excluded'), isFalse);
    },
  );

  test(
    'account partitions, bounded files and corruption fail closed',
    () async {
      final bounded = VectorStore(
        directory: () async => directory,
        maxRecords: 2,
        maxBytes: 500,
      );
      await bounded.write('1', {
        for (var i = 0; i < 10; i++)
          'track$i': VectorProvenance({
            'seed': 1,
          }, now.subtract(Duration(days: i))),
      }, check: () {});
      expect((await bounded.read('1')).keys, ['track0', 'track1']);
      expect(await bounded.read('2'), isEmpty);
      expect(await bounded.read('unknown'), isEmpty);
      await bounded.write('unknown', {
        'x': VectorProvenance({'s': 1}, now),
      }, check: () {});
      final file = File('${directory.path}/related-vectors-v1-1.json');
      expect(await file.length(), lessThanOrEqualTo(500));
      final raw = await file.readAsString();
      expect(raw, isNot(contains('stream')));
      expect((jsonDecode(raw) as Map)['identity'], '1');
      await file.writeAsString('{broken');
      expect(await bounded.read('1'), isEmpty);
    },
  );

  test(
    'reloaded profiles do not double count already observed sessions',
    () async {
      await store.write('1', {
        'played': VectorProvenance({'seed': 1}, now),
      }, check: () {});
      await facts.append(event('played'));
      final profile = engine.interests(
        ['seed'],
        await store.read('1'),
        await facts.read('1'),
        '1',
      );
      final restored = VectorEngine(
        api: api,
        store: VectorStore(directory: () async => directory),
        listening: ListeningStore(directory: () async => directory),
        now: () => now,
      );
      final after = restored.interests(
        ['seed'],
        await restored.store.read('1'),
        await restored.listening.read('1'),
        '1',
      );
      expect(after.single.support, profile.single.support);
      expect(after.single.support, 2);
      expect(
        engine
            .interests(
              ['seed'],
              await store.read('1'),
              await facts.read('1'),
              '2',
            )
            .single
            .support,
        1,
      );
    },
  );

  test(
    'cancellation during related request cannot persist stale provenance',
    () async {
      api.pending = Completer<List<Track>>();
      var cancelled = false;
      final future = engine.generate(
        seeds: [realTrack('seed')],
        identity: '1',
        excludedTrackIds: {},
        check: () {
          if (cancelled) throw AiFailure.cancelled;
        },
      );
      while (api.relatedCalls.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      cancelled = true;
      api.pending!.complete([realTrack('candidate')]);
      await expectLater(future, throwsA(AiFailure.cancelled));
      expect(await store.read('1'), isEmpty);
      expect(await store.read('2'), isEmpty);
    },
  );

  test(
    'cancellation before atomic replacement preserves previous valid file',
    () async {
      await store.write('1', {
        'old': VectorProvenance({'seed': 1}, now),
      }, check: () {});
      var calls = 0;
      await expectLater(
        store.write(
          '1',
          {
            'new': VectorProvenance({'seed': 1}, now),
          },
          check: () {
            if (++calls >= 3) throw AiFailure.cancelled;
          },
        ),
        throwsA(AiFailure.cancelled),
      );
      expect((await store.read('1')).keys, ['old']);
      expect(
        await File('${directory.path}/related-vectors-v1-1.json.tmp').exists(),
        isFalse,
      );
    },
  );

  test(
    'empty mood uses real graph without model; mood still uses model',
    () async {
      api.neighborhoods['seed'] = [realTrack('local')];
      final client = ScriptedAi();
      final service = RecommendationService(
        api: api,
        client: client,
        vectorEngine: engine,
      );
      Future<List<Recommendation>> generate(String mood) => service.generate(
        config: testConfig.withConsent(true),
        consent: AiConsent(
          destination: testConfig.destination,
          listening: true,
        ),
        apiKey: '',
        mood: mood,
        useListening: true,
        cancelToken: CancelToken(),
        listeningIdentity: '1',
        currentTrack: realTrack('seed'),
      );
      final local = await generate('');
      expect(local.first.track.id, 'local');
      expect(client.payloads, isEmpty);
      api.relatedCalls.clear();
      final mood = await generate('quiet evening');
      expect(mood.single.track.id, '2');
      expect(client.payloads.length, 2);
      expect(api.relatedCalls, isEmpty);
      expect(client.payloads.join(), isNot(contains('session_id')));
    },
  );

  test(
    'graph failure widens by genre search and never calls the model',
    () async {
      api.failRelated = true;
      final client = ScriptedAi();
      final result =
          await RecommendationService(
            api: api,
            client: client,
            vectorEngine: engine,
          ).generate(
            config: testConfig.withConsent(true),
            consent: AiConsent(
              destination: testConfig.destination,
              listening: true,
            ),
            apiKey: '',
            mood: '',
            useListening: true,
            cancelToken: CancelToken(),
            listeningIdentity: '1',
            currentTrack: realTrack('seed'),
          );
      expect(result.map((r) => r.track.id), containsAll(['1', '2']));
      expect(api.relatedCalls.length, 6);
      expect(api.relatedCalls.toSet().length, 6);
      expect(api.searches, ['ambient']);
      expect(client.payloads, isEmpty);
    },
  );

  test('an empty local pool fails visibly without calling the model', () async {
    api.failRelated = true;
    api.tracks = [];
    final client = ScriptedAi();
    final service = RecommendationService(
      api: api,
      client: client,
      vectorEngine: engine,
    );
    expect(
      service.generate(
        config: testConfig.withConsent(true),
        consent: AiConsent(
          destination: testConfig.destination,
          listening: true,
        ),
        apiKey: '',
        mood: '',
        useListening: true,
        cancelToken: CancelToken(),
        listeningIdentity: '1',
        currentTrack: realTrack('seed'),
      ),
      throwsA(AiFailure.noTracks),
    );
    await pumpEventQueueSafe();
    expect(client.payloads, isEmpty);
  });

  group('seen memory and pool stages', () {
    late SeenStore seen;
    setUp(() {
      api.tracks = [];
      seen = SeenStore(directory: () async => directory);
      engine = VectorEngine(
        api: api,
        store: store,
        listening: facts,
        seen: seen,
        now: () => now,
      );
    });
    Future<List<Recommendation>> run(
      VectorEngine value, {
      Set<String> excluded = const {},
      int limit = 10,
    }) => value.generate(
      seeds: [realTrack('s', artist: 'sa')],
      identity: '1',
      excludedTrackIds: excluded,
      check: () {},
      limit: limit,
    );
    List<String> ids(List<Recommendation> r) =>
        r.map((e) => e.track.id).toList();

    test('heard, skipped and liked tracks never reach the output', () async {
      api.neighborhoods['s'] = [
        for (var i = 0; i < 8; i++) realTrack('c$i', artist: 'a$i'),
      ];
      await facts.append(event('c0', session: 'a'));
      await facts.append(
        event(
          'c1',
          session: 'b',
          heard: 10000,
          cause: ListeningTransitionCause.manualNext,
        ),
      );
      final result = await run(engine, excluded: {'c2'});
      expect(ids(result), isNot(containsAll(['c0'])));
      expect(ids(result).toSet().intersection({'c0', 'c1', 'c2'}), isEmpty);
      expect(ids(result), hasLength(5));
    });

    test('exclusions survive a restart with fresh store instances', () async {
      api.neighborhoods['s'] = [
        for (var i = 0; i < 6; i++) realTrack('c$i', artist: 'a$i'),
      ];
      final first = await run(engine);
      expect(first, hasLength(6));
      // The wave marks what it really queued as shown.
      await seen.record('1', SeenKind.shown, ids(first), now);
      final restarted = VectorEngine(
        api: api,
        store: VectorStore(directory: () async => directory),
        listening: ListeningStore(directory: () async => directory),
        seen: SeenStore(directory: () async => directory),
        now: () => now.add(const Duration(days: 1)),
      );
      expect(ids(await run(restarted)), isEmpty);
      final later = VectorEngine(
        api: api,
        store: VectorStore(directory: () async => directory),
        listening: ListeningStore(directory: () async => directory),
        seen: SeenStore(directory: () async => directory),
        now: () => now.add(const Duration(days: 8)),
      );
      expect(ids(await run(later)), hasLength(6));
    });

    test(
      'a heard track stays excluded after the fact log forgets it',
      () async {
        api.neighborhoods['s'] = [
          for (var i = 0; i < 3; i++) realTrack('c$i', artist: 'a$i'),
        ];
        await facts.append(event('c0', session: 'a'));
        await run(engine);
        await File('${directory.path}/${ListeningStore.fileName}').delete();
        final again = await run(engine);
        // c0 stays out; unqueued candidates are not penalised.
        expect(ids(again).toSet(), {'c1', 'c2'});
        expect((await seen.read('1'))['c0']!.kind, SeenKind.played);
      },
    );

    test('the memory stays bounded and keeps the newest entries', () async {
      final small = SeenStore(directory: () async => directory, maxRecords: 3);
      for (var i = 0; i < 5; i++) {
        await small.record('1', SeenKind.played, [
          't$i',
        ], now.add(Duration(minutes: i)));
      }
      expect((await small.read('1')).keys.toSet(), {'t2', 't3', 't4'});
    });

    test('memory is per account and forget drops only that account', () async {
      await seen.record('1', SeenKind.played, ['c0'], now);
      await seen.record('2', SeenKind.played, ['c9'], now);
      expect(await seen.excluded('2', now), {'c9'});
      await seen.forget('2');
      expect(await seen.excluded('2', now), isEmpty);
      expect(await seen.excluded('1', now), {'c0'});
    });

    test('a corrupt file is kept as .bak and the memory restarts', () async {
      final file = File('${directory.path}/seen-tracks-v1-1.json');
      await file.writeAsString('{not json');
      expect(await seen.read('1'), isEmpty);
      expect(await File('${file.path}.bak').exists(), isTrue);
      await seen.record('1', SeenKind.played, ['c0'], now);
      expect(await seen.excluded('1', now), {'c0'});
    });

    test('one unreadable row does not discard the others', () async {
      final file = File('${directory.path}/seen-tracks-v1-1.json');
      await file.writeAsString(
        jsonEncode({
          'version': 1,
          'identity': '1',
          'entries': [
            {'id': 'good', 'kind': 'played', 'at': now.toIso8601String()},
            {'id': 'odd', 'kind': 'mystery', 'at': now.toIso8601String()},
            {'id': 'late', 'kind': 'played', 'at': 'not a date'},
            {'id': 'ok2', 'kind': 'skipped', 'at': now.toIso8601String()},
          ],
        }),
      );
      expect((await seen.read('1')).keys.toSet(), {'good', 'ok2'});
      expect(await File('${file.path}.bak').exists(), isFalse);
    });

    test('a failed read never overwrites the file', () async {
      final blocked = SeenStore(
        directory: () async => Directory('${directory.path}/missing/x'),
      );
      await Directory('${directory.path}/missing').create();
      await File('${directory.path}/missing/x').writeAsString('plain file');
      await blocked.record('1', SeenKind.played, ['c0'], now);
      expect(
        await File('${directory.path}/missing/x').readAsString(),
        'plain file',
      );
    });

    test('maxBytes truncates the oldest entries', () async {
      final tiny = SeenStore(directory: () async => directory, maxBytes: 400);
      for (var i = 0; i < 20; i++) {
        await tiny.record('1', SeenKind.played, [
          'track$i',
        ], now.add(Duration(minutes: i)));
      }
      final kept = (await tiny.read('1')).keys.toSet();
      expect(kept, contains('track19'));
      expect(kept, isNot(contains('track0')));
      expect(
        await File('${directory.path}/seen-tracks-v1-1.json').length(),
        lessThanOrEqualTo(400),
      );
    });

    test('mood mode drops heard and liked tracks after a restart', () async {
      api.tracks = [
        for (var i = 0; i < 4; i++) realTrack('m$i', artist: 'm$i'),
      ];
      await facts.append(event('m0', session: 'a'));
      await seen.record('1', SeenKind.shown, ['m1'], now);
      final restarted = VectorEngine(
        api: api,
        store: VectorStore(directory: () async => directory),
        listening: ListeningStore(directory: () async => directory),
        seen: SeenStore(directory: () async => directory),
        now: () => now,
      );
      final client = ScriptedAi()
        ..replies.clear()
        ..replies.addAll([
          '{"queries":["ambient"]}',
          '{"recommendations":[{"id":"m2","reason":"fit"}]}',
        ]);
      final result =
          await RecommendationService(
            api: api,
            client: client,
            vectorEngine: restarted,
          ).generate(
            config: testConfig.withConsent(true),
            consent: AiConsent(
              destination: testConfig.destination,
              listening: true,
            ),
            apiKey: '',
            mood: 'quiet',
            useListening: true,
            cancelToken: CancelToken(),
            listeningIdentity: '1',
            localExcludedTrackIds: {'m3'},
          );
      expect(result.single.track.id, 'm2');
      final sent = client.payloads.last;
      for (final hidden in ['m0', 'm1', 'm3']) {
        expect(sent, isNot(contains('"id":"$hidden"')));
      }
      expect(client.payloads.first, isNot(contains('m0')));
    });

    group('dislikes', () {
      Future<void> dislike(String id, {String artist = 'bad', int mins = 0}) =>
          seen.dislike('1', id, artist, now.add(Duration(minutes: mins)));

      Future<List<Recommendation>> value(VectorEngine v, List<Track> seeds) =>
          v.generate(
            seeds: seeds,
            identity: '1',
            excludedTrackIds: {},
            check: () {},
          );

      Future<List<Recommendation>> two(VectorEngine value) => value.generate(
        seeds: [
          realTrack('sA', artist: 'artist a'),
          realTrack('sB', artist: 'artist b'),
        ],
        identity: '1',
        excludedTrackIds: {},
        check: () {},
      );

      void graph() {
        api.neighborhoods['sA'] = [realTrack('cA', artist: 'x1')];
        api.neighborhoods['sB'] = [realTrack('cB', artist: 'x2')];
      }

      test(
        'a disliked track is excluded after a restart; undo restores',
        () async {
          api.neighborhoods['s'] = [
            realTrack('d', artist: 'bad'),
            realTrack('ok', artist: 'good'),
          ];
          await dislike('d');
          VectorEngine fresh() => VectorEngine(
            api: api,
            store: VectorStore(directory: () async => directory),
            listening: ListeningStore(directory: () async => directory),
            seen: SeenStore(directory: () async => directory),
            now: () => now.add(const Duration(days: 200)),
          );
          expect(ids(await run(fresh())), ['ok']);
          await SeenStore(directory: () async => directory).undislike('1', 'd');
          expect(ids(await run(fresh())).toSet(), {'d', 'ok'});
        },
      );

      test(
        'a dislike weakens the interest it came from, not to zero',
        () async {
          final provenance = {
            'd': VectorProvenance({'sA': 1.0}, now),
          };
          final dislikes = [VectorDislike('d', now, 'bad')];
          List<double> support(List<VectorDislike> d) => engine
              .interests(['sA', 'sB'], provenance, [], '1', dislikes: d)
              .map((p) => p.support)
              .toList();
          final plain = support([]);
          final hurt = support(dislikes);
          expect(hurt[0], lessThan(plain[0]));
          expect(hurt[0], greaterThan(plain[0] * .39));
          expect(hurt[1], plain[1]);
          // many dislikes are capped
          final many = support([for (var i = 0; i < 20; i++) dislikes.first]);
          expect(many[0], greaterThanOrEqualTo(plain[0] * .4 - 1e-9));
        },
      );

      test('similar candidates rank lower but stay in the pool', () async {
        graph();
        api.tracks = [];
        expect(ids(await two(engine)), ['cA', 'cB']);
        await store.write('1', {
          'd': VectorProvenance({'sA': 1.0}, now),
        }, check: () {});
        await dislike('d', artist: 'unrelated');
        expect(ids(await two(engine)), ['cB', 'cA']);
      });

      test('the artist penalty is soft', () async {
        api.tracks = [];
        api.neighborhoods['sA'] = [
          realTrack('cA', artist: 'bad'),
          realTrack('cB', artist: 'good'),
        ];
        expect(ids(await two(engine)), ['cA', 'cB']);
        await dislike('gone', artist: 'bad');
        expect(ids(await two(engine)), ['cB', 'cA']);
      });

      test(
        'mood mode drops disliked tracks and sends no dislike data',
        () async {
          api.tracks = [
            for (var i = 0; i < 3; i++) realTrack('m$i', artist: 'bad'),
          ];
          await dislike('m0', artist: 'bad');
          final client = ScriptedAi()
            ..replies.clear()
            ..replies.addAll([
              '{"queries":["ambient"]}',
              '{"recommendations":[{"id":"m1","reason":"fit"}]}',
            ]);
          final result =
              await RecommendationService(
                api: api,
                client: client,
                vectorEngine: engine,
              ).generate(
                config: testConfig.withConsent(true),
                consent: AiConsent(
                  destination: testConfig.destination,
                  listening: true,
                ),
                apiKey: '',
                mood: 'quiet',
                useListening: true,
                cancelToken: CancelToken(),
                listeningIdentity: '1',
              );
          expect(result.single.track.id, 'm1');
          final sent = client.payloads.join();
          expect(sent, isNot(contains('"id":"m0"')));
          expect(sent, isNot(contains('dislike')));
        },
      );

      test(
        'the dislike transition is neutral: no skip, no play, no double count',
        () async {
          api.tracks = [];
          api.neighborhoods['s'] = [
            realTrack('d', artist: 'bad'),
            realTrack('ok', artist: 'good'),
          ];
          // a short dislike-skip would be a -1.5 skip, a long one a positive play
          await facts.append(
            event(
              'd',
              session: 'short',
              heard: 10000,
              cause: ListeningTransitionCause.dislike,
            ),
          );
          await facts.append(
            event(
              'd',
              session: 'long',
              heard: 100000,
              cause: ListeningTransitionCause.dislike,
            ),
          );
          for (final e in await facts.read('1')) {
            expect(e.evidence, ListeningEvidence.neutral);
          }
          await dislike('d');
          await run(engine);
          final kinds = await seen.read('1');
          expect(kinds['d']!.kind, SeenKind.disliked);
          // undo leaves no skipped/played residue behind
          await seen.undislike('1', 'd');
          expect(await seen.read('1'), isNot(contains('d')));
          await run(engine);
          expect(await seen.read('1'), isNot(contains('d')));
          expect(ids(await run(engine)).toSet(), {'d', 'ok'});
          final plain = engine.interests(['s'], {}, await facts.read('1'), '1');
          expect(plain.single.support, 1.0);
        },
      );

      test('an old dislike stays excluded and never becomes a seed', () async {
        api.tracks = [];
        api.neighborhoods['d'] = [realTrack('viaD', artist: 'v')];
        api.neighborhoods['s'] = [realTrack('ok', artist: 'good')];
        await facts.append(event('d', session: 'old', daysAgo: 3));
        await dislike('d');
        // many newer dislikes push d out of the ranking window
        for (var i = 0; i < 30; i++) {
          await dislike('n$i', artist: 'a$i', mins: i + 1);
        }
        final result = await value(engine, [
          realTrack('s', artist: 'sa'),
          realTrack('d', artist: 'bad'),
        ]);
        expect(ids(result), ['ok']);
        expect(api.relatedCalls, isNot(contains('d')));
        expect((await seen.read('1'))['d']!.kind, SeenKind.disliked);
      });

      test('the penalty changes the order using real provenance', () async {
        api.tracks = [];
        api.neighborhoods['sA'] = [
          realTrack('d', artist: 'u'),
          realTrack('aa', artist: 'x1'),
        ];
        api.neighborhoods['sB'] = [realTrack('cb', artist: 'x2')];
        final first = ids(await two(engine));
        expect(first.toSet(), {'d', 'aa', 'cb'});
        await dislike('d', artist: 'unrelated');
        // d now has stored provenance {sA}; its siblings under sA sink
        expect(ids(await two(engine)), ['cb', 'aa']);
      });

      test('dislikes outlast ordinary entries under the size limit', () async {
        final tiny = SeenStore(directory: () async => directory, maxRecords: 3);
        await tiny.dislike('1', 'bad1', 'a', now);
        for (var i = 0; i < 5; i++) {
          await tiny.record('1', SeenKind.played, [
            'p$i',
          ], now.add(Duration(minutes: i + 1)));
        }
        final kept = (await tiny.read('1')).keys.toSet();
        expect(kept, contains('bad1'));
        expect(kept, hasLength(3));
      });
    });

    test('a small pool widens to second level, then genre search', () async {
      api.neighborhoods['s'] = [realTrack('c0', artist: 'a0')];
      api.neighborhoods['c0'] = [
        realTrack('d0', artist: 'b0'),
        realTrack('d1', artist: 'b1'),
      ];
      api.tracks = [
        realTrack('g0', artist: 'g0'),
        realTrack('g1', artist: 'g1'),
      ];
      final result = await run(engine);
      expect(api.relatedCalls, ['s', 'c0']);
      expect(api.searches, ['ambient']);
      expect(ids(result).toSet(), {'c0', 'd0', 'd1', 'g0', 'g1'});
    });

    test('request budget is a hard ceiling', () async {
      final capped = VectorEngine(
        api: api,
        store: store,
        listening: facts,
        seen: seen,
        maxRequests: 4,
        now: () => now,
      );
      api.neighborhoods['s'] = [realTrack('c0', artist: 'a0')];
      final seeds = [
        for (var i = 0; i < 8; i++) realTrack('r$i', artist: 'ra$i'),
      ];
      for (final seed in seeds) {
        api.neighborhoods[seed.id] = [
          realTrack('x${seed.id}', artist: seed.id),
        ];
      }
      await capped.generate(
        seeds: seeds,
        identity: '1',
        excludedTrackIds: {},
        check: () {},
      );
      expect(api.relatedCalls.length + api.searches.length, 4);
    });

    test('seeds rotate between consecutive generations', () async {
      final seeds = [
        for (var i = 0; i < 12; i++) realTrack('r$i', artist: 'artist $i'),
      ];
      Future<void> go() => engine.generate(
        seeds: seeds,
        identity: '1',
        excludedTrackIds: {},
        check: () {},
      );
      await go();
      final first = api.relatedCalls.toSet();
      api.relatedCalls.clear();
      await go();
      expect(first, hasLength(6));
      expect(api.relatedCalls.toSet().intersection(first), isEmpty);
    });

    test('recent positive listens become seeds', () async {
      await facts.append(event('heard1', session: 'a'));
      await run(engine);
      expect(api.relatedCalls, containsAll(['s', 'heard1']));
    });
  });
}

Future<void> pumpEventQueueSafe() => Future<void>.delayed(Duration.zero);
