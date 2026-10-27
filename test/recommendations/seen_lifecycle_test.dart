import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/api/soundcloud_auth.dart';
import 'package:waveform_app/core/log/talker.dart';
import 'package:waveform_app/core/recommendations/ai_client.dart';
import 'package:waveform_app/core/recommendations/listening_store.dart';
import 'package:waveform_app/core/recommendations/listening_providers.dart';
import 'package:waveform_app/core/recommendations/models.dart';
import 'package:waveform_app/core/recommendations/providers.dart';
import 'package:waveform_app/core/recommendations/recommendation_service.dart';
import 'package:waveform_app/core/recommendations/seen_store.dart';
import 'package:waveform_app/core/recommendations/vector_engine.dart';
import 'package:waveform_app/core/recommendations/vector_store.dart';
import 'package:waveform_app/shared/models/track.dart';

import 'support.dart';
import 'ui_test_support.dart';

class PagedLikesApi extends TestSoundcloud {
  final pages = <String?>[];
  Completer<void>? hold;
  VoidCallback? onSecondPage;

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
  late ScriptedAi client;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('waveform-lifecycle-');
    api = PagedLikesApi()
      ..tracks = [
        for (final id in ['like-late', 'like-last', 'heard', 'fresh'])
          realTrack(id, artist: id),
      ];
    client = ScriptedAi()..replies.clear();
  });
  tearDown(() => directory.deleteSync(recursive: true));

  RecommendationService service({VectorEngine? engine}) =>
      RecommendationService(api: api, client: client, vectorEngine: engine);

  Future<List<Recommendation>> mood(
    RecommendationService value, {
    CancelToken? token,
  }) {
    client.replies.addAll([
      '{"queries":["ambient"]}',
      '{"recommendations":[{"id":"fresh","reason":"fit"}]}',
    ]);
    return value.generate(
      config: testConfig.withConsent(true),
      consent: AiConsent(destination: testConfig.destination, listening: true),
      apiKey: '',
      mood: 'quiet',
      useListening: true,
      cancelToken: token ?? CancelToken(),
      listeningIdentity: '42',
    );
  }

  VectorEngine engineWithMemory(SeenStore seen) => VectorEngine(
    api: api,
    store: VectorStore(directory: () async => directory),
    listening: ListeningStore(directory: () async => directory),
    seen: seen,
  );

  test(
    'mood mode filters liked and remembered ids and keeps them local',
    () async {
      final seen = SeenStore(directory: () async => directory);
      await seen.record('42', SeenKind.played, ['heard'], DateTime.now());
      final result = await mood(service(engine: engineWithMemory(seen)));
      expect(result.single.track.id, 'fresh');
      expect(api.pages, [null, 'p2', 'p3']);
      // like-first is an ordinary seed the model has always seen; the
      // drained and remembered ids must stay local. candidates sent to the model contain only the unfiltered track
      final ranking = client.payloads.last;
      expect(ranking, contains('"id":"fresh"'));
      for (final hidden in ['like-late', 'like-last', 'heard']) {
        expect(client.payloads.join(), isNot(contains(hidden)));
      }
      expect(client.payloads.join(), isNot(contains('remembered')));
      expect(client.payloads.join(), isNot(contains('liked')));
    },
  );

  test('the liked set is cached between generations', () async {
    final value = service();
    await mood(value);
    expect(api.likesCalls, 3);
    await mood(value);
    // only the first page again, for seeds
    expect(api.likesCalls, 4);
  });

  test('cancelling stops the liked walk and late pages add nothing', () async {
    final token = CancelToken();
    api.onSecondPage = token.cancel;
    final value = service();
    await expectLater(mood(value, token: token), throwsA(AiFailure.cancelled));
    expect(api.pages, [null, 'p2']);
  });

  test('a failing liked page keeps the partial set and warns', () async {
    final warnings = <String>[];
    final failing = FailingLikes()
      ..tracks = [realTrack('fresh', artist: 'fresh')];
    final value = RecommendationService(
      api: failing,
      client: client,
      onWarning: warnings.add,
    );
    final result = await mood(value);
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

  test('logging out through the auth controller deletes that memory', () async {
    final seen = SeenStore(directory: () async => directory);
    final container = ProviderContainer(
      overrides: [
        aiSettingsProvider.overrideWith(
          () => WaveTestSettings(initial: const AiSettingsState(ready: true)),
        ),
        aiListeningIdentityProvider.overrideWith((ref) async {
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
  Future<({List<Track> tracks, String? nextHref})> likesPage({
    String? nextHref,
    int limit = 50,
  }) async {
    if (nextHref != null) throw StateError('network');
    return (tracks: [realTrack('first')], nextHref: 'p2');
  }
}
