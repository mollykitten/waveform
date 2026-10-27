import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/api/soundcloud_auth.dart';
import 'package:waveform_app/core/log/talker.dart';
import 'package:waveform_app/core/recommendations/listening_store.dart';
import 'package:waveform_app/core/recommendations/listening_event.dart';
import 'package:waveform_app/core/recommendations/listening_providers.dart';
import 'package:waveform_app/core/recommendations/models.dart';
import 'package:waveform_app/core/recommendations/providers.dart';
import 'package:waveform_app/core/recommendations/recommendation_service.dart';
import 'package:waveform_app/core/recommendations/seen_store.dart';
import 'package:waveform_app/core/recommendations/vector_engine.dart';
import 'package:waveform_app/core/recommendations/vector_store.dart';
import 'package:waveform_app/shared/models/track.dart';

import 'support.dart';

class PagedLikesApi extends TestSoundcloud {
  final pages = <String?>[];
  Completer<void>? hold;
  VoidCallback? onSecondPage;

  @override
  Future<List<Track>> relatedTracks(String id) async => [
    for (final track in tracks) track,
  ];

  @override
  Future<({List<Track> tracks, String? nextHref})> likesPage({
    String? nextHref,
    int limit = 50,
  }) async {
    likesCalls++;
    pages.add(nextHref);
    switch (nextHref) {
      case null:
        return (tracks: [realTrack('like-first')], nextHref: 'p2');
      case 'p2':
        onSecondPage?.call();
        if (hold != null) await hold!.future;
        return (tracks: [realTrack('like-late')], nextHref: 'p3');
      default:
        return (tracks: [realTrack('like-last')], nextHref: null);
    }
  }
}

typedef VoidCallback = void Function();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PagedLikesApi api;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('waveform-lifecycle-');
    api = PagedLikesApi()
      ..tracks = [
        for (final id in ['like-late', 'like-last', 'heard', 'fresh'])
          realTrack(id, artist: id),
      ];
  });
  tearDown(() => directory.deleteSync(recursive: true));

  VectorEngine engineWithMemory(SeenStore seen) => VectorEngine(
    api: api,
    store: VectorStore(directory: () async => directory),
    listening: ListeningStore(directory: () async => directory),
    seen: seen,
  );

  RecommendationService service({SeenStore? seen, TestSoundcloud? source}) =>
      RecommendationService(
        api: source ?? api,
        vectorEngine: engineWithMemory(
          seen ?? SeenStore(directory: () async => directory),
        ),
      );

  Future<List<Recommendation>> wave(
    RecommendationService value, {
    CancelToken? token,
  }) => value.generate(
    cancelToken: token ?? CancelToken(),
    listeningIdentity: '42',
  );

  test('the wave filters liked and remembered ids', () async {
    final seen = SeenStore(directory: () async => directory);
    await seen.record('42', SeenKind.played, ['heard'], DateTime.now());
    final result = await wave(service(seen: seen));
    expect(result.single.track.id, 'fresh');
    expect(api.pages, [null, 'p2', 'p3']);
  });

  test('the liked set is cached between generations', () async {
    final value = service();
    await wave(value);
    expect(api.likesCalls, 3);
    await wave(value).then((_) {}, onError: (_) {});
    // only the first page again, for seeds
    expect(api.likesCalls, 4);
  });

  test('cancelling stops the liked walk and late pages add nothing', () async {
    final token = CancelToken();
    api.onSecondPage = token.cancel;
    final value = service();
    await expectLater(
      wave(value, token: token),
      throwsA(WaveFailure.cancelled),
    );
    expect(api.pages, [null, 'p2']);
  });

  test('a failing liked page keeps the partial set and warns', () async {
    final warnings = <String>[];
    final failing = FailingLikes()
      ..tracks = [realTrack('fresh', artist: 'fresh')];
    final value = RecommendationService(
      api: failing,
      onWarning: warnings.add,
      vectorEngine: VectorEngine(
        api: failing,
        store: VectorStore(directory: () async => directory),
        listening: ListeningStore(directory: () async => directory),
      ),
    );
    final result = await wave(value);
    expect(result.single.track.id, 'fresh');
    expect(warnings, hasLength(1));
  });

  group('seen store robustness', () {
    test('invalid utf-8 is kept as .bak and does not throw', () async {
      final seen = SeenStore(directory: () async => directory);
      final file = File('${directory.path}/seen-tracks-v1-42.json');
      await file.writeAsBytes([0xff, 0xfe, 0xfd]);
      expect(await seen.read('42'), isEmpty);
      expect(File('${file.path}.bak').existsSync(), isTrue);
    });

    test('an unusable directory never throws', () async {
      final seen = SeenStore(directory: () async => throw StateError('no dir'));
      expect(await seen.read('42'), isEmpty);
      await seen.record('42', SeenKind.played, ['a'], DateTime.now());
      await seen.forget('42');
    });

    test('a late write after forget does not recreate the file', () async {
      final seen = SeenStore(directory: () async => directory);
      final file = File('${directory.path}/seen-tracks-v1-42.json');
      await seen.record('42', SeenKind.played, ['a'], DateTime.now());
      final queued = seen.record('42', SeenKind.played, ['b'], DateTime.now());
      final forgotten = seen.forget('42');
      final late = seen.dislike('42', 'c', 'x', DateTime.now());
      expect(await queued, isFalse);
      await forgotten;
      expect(await late, isFalse);
      expect(file.existsSync(), isFalse);
      seen.reopen('42');
      expect(
        await seen.record('42', SeenKind.played, ['d'], DateTime.now()),
        isTrue,
      );
      expect(file.existsSync(), isTrue);
    });

    test('a failed dislike write is reported', () async {
      final seen = SeenStore(directory: () async => throw StateError('no'));
      expect(await seen.dislike('42', 'a', 'x', DateTime.now()), isFalse);
    });

    test('dislikes past 365 days stop counting and are pruned', () async {
      final seen = SeenStore(directory: () async => directory);
      final now = DateTime.utc(2026, 10, 25);
      await seen.dislike(
        '42',
        'old',
        'x',
        now.subtract(const Duration(days: 400)),
      );
      await seen.dislike(
        '42',
        'new',
        'y',
        now.subtract(const Duration(days: 10)),
      );
      final rows = await seen.dislikes('42', 50, now: now);
      expect(rows.map((r) => r.id), ['new']);
      expect(await seen.excluded('42', now), {'new'});
      // the next write drops the expired entry from the file itself
      await seen.record('42', SeenKind.played, ['p'], now);
      expect((await seen.read('42')).keys, isNot(contains('old')));
    });

    test('forget removes the file, .bak and .tmp of one account', () async {
      final seen = SeenStore(directory: () async => directory);
      await seen.record('42', SeenKind.played, ['a'], DateTime.now());
      await seen.record('43', SeenKind.played, ['b'], DateTime.now());
      final base = '${directory.path}/seen-tracks-v1-42.json';
      File('$base.bak').writeAsStringSync('x');
      File('$base.tmp').writeAsStringSync('x');
      await seen.forget('42');
      expect(File(base).existsSync(), isFalse);
      expect(File('$base.bak').existsSync(), isFalse);
      expect(File('$base.tmp').existsSync(), isFalse);
      expect(
        File('${directory.path}/seen-tracks-v1-43.json').existsSync(),
        isTrue,
      );
    });
  });

  test('a listening row with an unknown cause is skipped, not fatal', () async {
    final good = ListeningEvent(
      sessionId: 'good',
      identity: '42',
      trackId: 't',
      durationMs: 100000,
      heardMs: 90000,
      finalPositionMs: 90000,
      seekCount: 0,
      startedAt: DateTime.utc(2026, 10, 25),
      endedAt: DateTime.utc(2026, 10, 25, 0, 2),
      cause: ListeningTransitionCause.dislike,
    );
    final future = {
      ...good.toJson(),
      'session_id': 'future',
      'cause': 'beamUp',
    };
    File('${directory.path}/${ListeningStore.fileName}').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'events': [future, good.toJson()],
      }),
    );
    final store = ListeningStore(directory: () async => directory);
    final read = await store.read('42');
    expect(read.map((e) => e.sessionId), ['good']);
    expect(read.single.cause, ListeningTransitionCause.dislike);
  });

  test('logging out through the auth controller deletes that memory', () async {
    final seen = SeenStore(directory: () async => directory);
    final container = ProviderContainer(
      overrides: [
        listeningIdentityProvider.overrideWith((ref) async {
          final auth = ref.watch(authControllerProvider);
          await Future<void>.delayed(Duration.zero);
          return auth.isAuthenticated ? '42' : 'anonymous';
        }),
        seenStoreProvider.overrideWithValue(seen),
        listeningStoreProvider.overrideWithValue(
          ListeningStore(directory: () async => directory),
        ),
        soundcloudApiProvider.overrideWithValue(api),
        talkerProvider.overrideWithValue(Talker()),
      ],
    );
    addTearDown(container.dispose);
    // AppShell reads this provider; the recommendations screen is never opened.
    container.read(listeningFeedbackProvider);
    container.read(authControllerProvider.notifier).signIn('2-token');
    expect(await container.read(listeningPartitionProvider.future), '42');
    await seen.record('42', SeenKind.played, ['a'], DateTime.now());
    final base = '${directory.path}/seen-tracks-v1-42.json';
    File('$base.bak').writeAsStringSync('x');
    expect(File(base).existsSync(), isTrue);

    container.read(authControllerProvider.notifier).signOut();
    expect(
      await container.read(listeningPartitionProvider.future),
      'anonymous',
    );
    await pumpEventQueue();
    await seen.read('42');
    expect(File(base).existsSync(), isFalse);
    expect(File('$base.bak').existsSync(), isFalse);
  });
}

class FailingLikes extends TestSoundcloud {
  @override
  Future<List<Track>> relatedTracks(String id) async => tracks;

  @override
  Future<({List<Track> tracks, String? nextHref})> likesPage({
    String? nextHref,
    int limit = 50,
  }) async {
    if (nextHref != null) throw StateError('network');
    return (tracks: [realTrack('first')], nextHref: 'p2');
  }
}
