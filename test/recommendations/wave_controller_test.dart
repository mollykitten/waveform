import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:waveform_app/core/api/liked_tracks.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/api/soundcloud_auth.dart';
import 'package:waveform_app/core/audio/audio_engine.dart';
import 'package:waveform_app/core/log/talker.dart';
import 'package:waveform_app/core/recommendations/ai_config.dart';
import 'package:waveform_app/core/recommendations/ai_client.dart';
import 'package:waveform_app/core/recommendations/models.dart';
import 'package:waveform_app/core/recommendations/recommendation_service.dart';
import 'package:waveform_app/core/recommendations/seen_store.dart';
import 'package:waveform_app/shared/models/track.dart';
import 'package:waveform_app/core/recommendations/providers.dart';
import 'package:waveform_app/features/player/player_controller.dart';
import 'package:waveform_app/features/player/player_ui_state.dart';
import 'package:waveform_app/features/player/widgets/bottom_player.dart';
import 'package:waveform_app/features/recommendations/wave_controller.dart';

import '../support/fake_audio_engine.dart';
import '../support/stub_liked_tracks.dart';
import 'support.dart';
import 'ui_test_support.dart';

void main() {
  late ProviderContainer container;
  late WaveTestSettings settings;
  late ScriptedAi client;
  late TestSoundcloud api;
  late FakeAudioEngine engine;
  String? userToken;
  late Directory seenDirectory;
  Future<void> flush() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  void batch(List<String> ids) {
    client.replies.addAll([
      '{"queries":["ambient"]}',
      jsonEncode({
        'recommendations': [
          for (final id in ids) {'id': id, 'reason': 'a possible fit'},
        ],
      }),
    ]);
  }

  setUp(() {
    seenDirectory = Directory.systemTemp.createTempSync('waveform-seen-');
    userToken = null;
    settings = WaveTestSettings(
      initial: const AiSettingsState(
        ready: true,
        chatGptConnected: true,
        config: AiConfig(backend: AiBackend.chatGpt, listeningConsent: true),
      ),
    );
    client = ScriptedAi()..replies.clear();
    api = TestSoundcloud()
      ..tracks = List.generate(12, (i) => realTrack('${i + 1}'));
    engine = FakeAudioEngine();
    container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWithBuild(
          (ref, notifier) =>
              SoundcloudAuth(clientId: 'test', userToken: userToken),
        ),
        waveRetryDelayProvider.overrideWithValue(Duration.zero),
        aiSettingsProvider.overrideWith(() => settings),
        aiListeningIdentityProvider.overrideWith((ref) async => 'test-profile'),
        aiClientProvider.overrideWithValue(client),
        soundcloudApiProvider.overrideWithValue(api),
        audioEngineProvider.overrideWithValue(engine),
        likedTracksProvider.overrideWith(StubLikedTracks.new),
        talkerProvider.overrideWithValue(Talker()),
      ],
    );
  });
  tearDown(() {
    seenDirectory.deleteSync(recursive: true);
    container.dispose();
    engine.dispose();
  });

  ProviderContainer containerWith(
    RecommendationService service, {
    SeenStore? seen,
  }) {
    final other = ProviderContainer(
      overrides: [
        waveRetryDelayProvider.overrideWithValue(Duration.zero),
        authControllerProvider.overrideWithBuild(
          (ref, notifier) => const SoundcloudAuth(clientId: 'test'),
        ),
        aiSettingsProvider.overrideWith(() => settings),
        aiListeningIdentityProvider.overrideWith((ref) async => 'test-profile'),
        aiClientProvider.overrideWithValue(client),
        recommendationServiceProvider.overrideWithValue(service),
        seenStoreProvider.overrideWithValue(
          seen ?? SeenStore(directory: () async => seenDirectory),
        ),
        soundcloudApiProvider.overrideWithValue(api),
        audioEngineProvider.overrideWithValue(engine),
        likedTracksProvider.overrideWith(StubLikedTracks.new),
        talkerProvider.overrideWithValue(Talker()),
      ],
    );
    addTearDown(other.dispose);
    return other;
  }

  test('a late initial result cannot replace a newly selected track', () async {
    final pending = Completer<String>();
    client.pending = pending;
    final request = container
        .read(waveControllerProvider.notifier)
        .start('ambient');
    await flush();
    final other = realTrack('other');
    container.read(playerControllerProvider.notifier).play(other);
    client.pending = null;
    client.replies.add('{"recommendations":[{"id":"1","reason":"fit"}]}');
    pending.complete('{"queries":["ambient"]}');
    await request;
    await flush();
    expect(container.read(playerControllerProvider).track, same(other));
    expect(container.read(waveControllerProvider).active, isFalse);
    expect(
      container.read(playerControllerProvider.notifier).upcomingTracks,
      isEmpty,
    );
  });

  test(
    'one initial result prefetches one unique batch without a refill loop',
    () async {
      batch(['1']);
      batch(['2', '3', '4']);
      await container.read(waveControllerProvider.notifier).start('ambient');
      await flush();
      expect(client.payloads, hasLength(4));
      expect(container.read(playerControllerProvider).track?.id, '1');
      expect(
        container
            .read(playerControllerProvider.notifier)
            .upcomingTracks
            .map((t) => t.id),
        ['2', '3', '4'],
      );
      expect(container.read(waveControllerProvider).active, isTrue);
      await flush();
      expect(client.payloads, hasLength(4));
    },
  );

  test(
    'late refill cannot append to an unrelated queue with a wave track',
    () async {
      batch(['1', '2', '3', '4']);
      await container.read(waveControllerProvider.notifier).start('ambient');
      final pending = Completer<String>();
      client.pending = pending;
      final player = container.read(playerControllerProvider.notifier);
      player.next();
      await flush();
      expect(container.read(waveControllerProvider).discovering, isTrue);
      player.play(api.tracks[1], queue: [api.tracks[1], realTrack('outside')]);
      client.pending = null;
      pending.complete('{"queries":["ambient"]}');
      await flush();
      expect(player.upcomingTracks.map((t) => t.id), ['outside']);
      expect(container.read(waveControllerProvider).active, isFalse);
    },
  );

  test(
    'exhausted candidates retry, then stop with a visible message',
    () async {
      final service = PoolService(api, client)..scripted = [4];
      final other = containerWith(service);
      await other.read(waveControllerProvider.notifier).start('');
      final player = other.read(playerControllerProvider.notifier);
      player.next();
      await pumpEventQueue();
      expect(other.read(waveControllerProvider).active, isFalse);
      expect(other.read(recommendationsProvider).error, AiFailure.noTracks);
      final calls = service.calls;
      expect(calls, 1 + WaveController.maxRetries + 1);
      for (var i = 0; i < 3; i++) {
        player.next();
        await pumpEventQueue();
      }
      expect(service.calls, calls);
    },
  );

  test('a failing search is retried and its error stays visible', () async {
    final service = PoolService(api, client)..scripted = [4];
    final other = containerWith(service);
    await other.read(waveControllerProvider.notifier).start('');
    service.failure = AiFailure.network;
    other.read(playerControllerProvider.notifier).next();
    await pumpEventQueue();
    expect(other.read(waveControllerProvider).active, isFalse);
    expect(other.read(recommendationsProvider).error, AiFailure.network);
    expect(service.calls, 1 + WaveController.maxRetries + 1);
  });

  test('a user-fixable error is shown at once without retries', () async {
    final service = PoolService(api, client)..scripted = [4];
    final other = containerWith(service);
    await other.read(waveControllerProvider.notifier).start('');
    service.failure = AiFailure.credentials;
    other.read(playerControllerProvider.notifier).next();
    await pumpEventQueue();
    expect(other.read(waveControllerProvider).active, isFalse);
    expect(other.read(recommendationsProvider).error, AiFailure.credentials);
    expect(service.calls, 2);
  });

  test('an empty refill keeps the wave searching and recovers', () async {
    final service = PoolService(api, client)..scripted = [4, 0, 2];
    final other = containerWith(service);
    await other.read(waveControllerProvider.notifier).start('');
    final player = other.read(playerControllerProvider.notifier);
    player.next();
    await pumpEventQueue();
    expect(service.calls, 3);
    expect(other.read(waveControllerProvider).active, isTrue);
    expect(other.read(waveControllerProvider).discovering, isFalse);
    expect(other.read(recommendationsProvider).error, isNull);
  });

  testWidgets('dislike button shows for wave tracks, skips and can undo', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final memory = MemorySeenStore();
    final other = containerWith(PoolService(api, client), seen: memory);
    await other.read(waveControllerProvider.notifier).start('');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: other,
        child: const MaterialApp(
          home: Scaffold(body: Column(children: [Spacer(), BottomPlayer()])),
        ),
      ),
    );
    const label = 'dislike, do not suggest again';
    expect(find.byTooltip(label), findsOneWidget);
    expect(other.read(playerControllerProvider).track?.id, 't1');

    await tester.tap(find.byTooltip(label));
    await tester.pump();
    await tester.pump();
    expect(other.read(playerControllerProvider).track?.id, 't2');
    expect(find.text("won't suggest this again"), findsOneWidget);
    expect(memory.kinds['t1'], SeenKind.disliked);

    await tester.tap(find.text('undo'));
    await tester.pump();
    await tester.pump();
    expect(memory.kinds.containsKey('t1'), isFalse);

    other.read(playerCollapsedProvider.notifier).collapse();
    await tester.pump();
    expect(find.byTooltip(label), findsOneWidget);

    other.read(playerControllerProvider.notifier).play(realTrack('foreign'));
    await tester.pump(const Duration(seconds: 5));
    expect(find.byTooltip(label), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final change in ['disconnect', 'config', 'logout', 'cancel']) {
    test(
      '$change aborts a pending refill and does not change the queue',
      () async {
        batch(['1', '2', '3', '4']);
        await container.read(waveControllerProvider.notifier).start('ambient');
        final pending = Completer<String>();
        client.pending = pending;
        final player = container.read(playerControllerProvider.notifier);
        player.next();
        await flush();
        switch (change) {
          case 'disconnect':
            await settings.disconnectChatGpt();
          case 'config':
            await settings.save(testConfig);
          case 'logout':
            userToken = 'another-account';
            container.invalidate(authControllerProvider);
            await flush();
          case 'cancel':
            container.read(waveControllerProvider.notifier).cancel();
        }
        final queued = player.upcomingTracks.map((t) => t.id).toList();
        client.pending = null;
        pending.complete('{"queries":["ambient"]}');
        await flush();
        expect(container.read(waveControllerProvider).active, isFalse);
        expect(container.read(waveControllerProvider).discovering, isFalse);
        expect(player.upcomingTracks.map((t) => t.id), queued);
      },
    );
  }
}

/// Returns twenty fresh candidates on the first call and records limits.
class PoolService extends RecommendationService {
  PoolService(TestSoundcloud api, ScriptedAi client)
    : super(api: api, client: client);
  int calls = 0;
  int issued = 0;

  /// Sizes of successive answers; afterwards every answer is empty.
  List<int>? scripted;
  AiFailure? failure;
  final limits = <int>[];

  @override
  Future<List<Recommendation>> generate({
    required AiConfig config,
    required AiConsent consent,
    required String apiKey,
    required String mood,
    required bool useListening,
    required CancelToken cancelToken,
    Track? currentTrack,
    Set<String> excludedTrackIds = const {},
    Set<String> localExcludedTrackIds = const {},
    String? listeningIdentity,
    void Function()? checkCurrent,
    int limit = 10,
  }) async {
    calls++;
    limits.add(limit);
    if (failure != null) throw failure!;
    if (scripted != null) {
      final size = scripted!.isEmpty ? 0 : scripted!.removeAt(0);
      return [
        for (var i = 0; i < size; i++)
          Recommendation(realTrack('t${++issued}'), 'a possible fit'),
      ];
    }
    return [
      for (var i = 0; i < 20; i++)
        Recommendation(realTrack('t${i + 1}'), 'a possible fit'),
    ];
  }
}

/// In-memory stand-in so widget tests need no file IO.
class MemorySeenStore extends SeenStore {
  final kinds = <String, SeenKind>{};

  @override
  Future<void> dislike(
    String identity,
    String trackId,
    String artist,
    DateTime at,
  ) async => kinds[trackId] = SeenKind.disliked;

  @override
  Future<void> undislike(String identity, String trackId) async =>
      kinds.remove(trackId);

  @override
  Future<void> record(
    String identity,
    SeenKind kind,
    Iterable<String> ids,
    DateTime at,
  ) async {
    for (final id in ids) {
      kinds.putIfAbsent(id, () => kind);
    }
  }
}
