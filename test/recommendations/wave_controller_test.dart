import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:waveform_app/core/api/liked_tracks.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/api/soundcloud_auth.dart';
import 'package:waveform_app/core/audio/audio_engine.dart';
import 'package:waveform_app/core/log/talker.dart';
import 'package:waveform_app/core/recommendations/listening_event.dart';
import 'package:waveform_app/core/recommendations/models.dart';
import 'package:waveform_app/core/recommendations/wave_sources.dart';
import 'package:waveform_app/core/recommendations/recommendation_service.dart';
import 'package:waveform_app/core/recommendations/seen_store.dart';
import 'package:waveform_app/core/recommendations/providers.dart';
import 'package:waveform_app/features/player/player_controller.dart';
import 'package:waveform_app/features/player/player_ui_state.dart';
import 'package:waveform_app/features/player/widgets/bottom_player.dart';
import 'package:waveform_app/features/recommendations/wave_controller.dart';

import '../support/fake_audio_engine.dart';
import '../support/stub_liked_tracks.dart';
import 'pool_service.dart';
import 'support.dart';

void main() {
  late ProviderContainer container;
  late PoolService pool;
  late TestSoundcloud api;
  late FakeAudioEngine engine;
  String? userToken;
  late Directory seenDirectory;
  Future<void> flush() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() {
    seenDirectory = Directory.systemTemp.createTempSync('waveform-seen-');
    userToken = 'test-token';
    api = TestSoundcloud()
      ..tracks = List.generate(12, (i) => realTrack('${i + 1}'));
    pool = PoolService(api);
    engine = FakeAudioEngine();
    container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWithBuild(
          (ref, notifier) =>
              SoundcloudAuth(clientId: 'test', userToken: userToken),
        ),
        waveRetryDelayProvider.overrideWithValue(Duration.zero),
        listeningIdentityProvider.overrideWith((ref) async => '42'),
        recommendationServiceProvider.overrideWithValue(pool),
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
    String identity = '42',
    Future<String> Function()? loader,
  }) {
    final other = ProviderContainer(
      overrides: [
        waveRetryDelayProvider.overrideWithValue(Duration.zero),
        authControllerProvider.overrideWithBuild(
          (ref, notifier) =>
              SoundcloudAuth(clientId: 'test', userToken: userToken),
        ),
        listeningIdentityProvider.overrideWith(
          (ref) async => loader == null ? identity : await loader(),
        ),
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
    pool.holdFirst = Completer<void>();
    final request = container.read(waveControllerProvider.notifier).start();
    await flush();
    final other = realTrack('other');
    container.read(playerControllerProvider.notifier).play(other);
    pool.holdFirst!.complete();
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
      pool.scripted = [1, 3];
      await container.read(waveControllerProvider.notifier).start();
      await flush();
      expect(pool.calls, 2);
      expect(container.read(playerControllerProvider).track?.id, 't1');
      expect(
        container
            .read(playerControllerProvider.notifier)
            .upcomingTracks
            .map((t) => t.id),
        ['t2', 't3', 't4'],
      );
      expect(container.read(waveControllerProvider).active, isTrue);
      await flush();
      expect(pool.calls, 2);
    },
  );

  test('the wave records each queued track\'s source and clears it', () async {
    pool.sources = const [
      WaveSource.related,
      WaveSource.stream,
      WaveSource.coLikers,
    ];
    pool.scripted = [3];
    await container.read(waveControllerProvider.notifier).start();
    await flush();
    final sources = container.read(waveSourcesProvider);
    // t1, t2, t3 were issued as index 1, 2, 3 of the rotation
    expect(sources, {
      't1': WaveSource.stream,
      't2': WaveSource.coLikers,
      't3': WaveSource.related,
    });
    container.read(waveControllerProvider.notifier).cancel();
    expect(container.read(waveSourcesProvider), isEmpty);
  });

  test('a new wave starts with a clean source map', () async {
    pool.scripted = [2, 0, 2];
    final wave = container.read(waveControllerProvider.notifier);
    await wave.start();
    await flush();
    expect(container.read(waveSourcesProvider).keys, containsAll(['t1', 't2']));
    container.read(playerControllerProvider.notifier).play(realTrack('other'));
    await flush();
    expect(container.read(waveSourcesProvider), isEmpty);
  });

  test(
    'late refill cannot append to an unrelated queue with a wave track',
    () async {
      pool.scripted = [4, 4];
      await container.read(waveControllerProvider.notifier).start();
      pool.holdAfterFirst = Completer<void>();
      final player = container.read(playerControllerProvider.notifier);
      player.next();
      await flush();
      expect(container.read(waveControllerProvider).discovering, isTrue);
      final inside = realTrack('t2');
      player.play(inside, queue: [inside, realTrack('outside')]);
      pool.holdAfterFirst!.complete();
      await flush();
      expect(player.upcomingTracks.map((t) => t.id), ['outside']);
      expect(container.read(waveControllerProvider).active, isFalse);
    },
  );

  test(
    'exhausted candidates retry, then stop with a visible message',
    () async {
      final service = PoolService(api)..scripted = [4];
      final other = containerWith(service);
      await other.read(waveControllerProvider.notifier).start();
      final player = other.read(playerControllerProvider.notifier);
      player.next();
      await pumpEventQueue();
      expect(other.read(waveControllerProvider).active, isFalse);
      expect(other.read(recommendationsProvider).error, WaveFailure.noTracks);
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
    final service = PoolService(api)..scripted = [4];
    final other = containerWith(service);
    await other.read(waveControllerProvider.notifier).start();
    service.failure = WaveFailure.network;
    other.read(playerControllerProvider.notifier).next();
    await pumpEventQueue();
    expect(other.read(waveControllerProvider).active, isFalse);
    expect(other.read(recommendationsProvider).error, WaveFailure.network);
    expect(service.calls, 1 + WaveController.maxRetries + 1);
  });

  test('a user-fixable error is shown at once without retries', () async {
    final service = PoolService(api)..scripted = [4];
    final other = containerWith(service);
    await other.read(waveControllerProvider.notifier).start();
    service.failure = WaveFailure.signIn;
    other.read(playerControllerProvider.notifier).next();
    await pumpEventQueue();
    expect(other.read(waveControllerProvider).active, isFalse);
    expect(other.read(recommendationsProvider).error, WaveFailure.signIn);
    expect(service.calls, 2);
  });

  test('an empty refill keeps the wave searching and recovers', () async {
    final service = PoolService(api)..scripted = [4, 0, 2];
    final other = containerWith(service);
    await other.read(waveControllerProvider.notifier).start();
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
    final other = containerWith(PoolService(api), seen: memory);
    await other.read(waveControllerProvider.notifier).start();
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

  group('dislike races', () {
    late MemorySeenStore memory;
    late ProviderContainer wave;
    late WaveController controller;
    late PlayerController player;
    Future<void> setUpWave({String identity = '42'}) async {
      memory = MemorySeenStore();
      wave = containerWith(PoolService(api), seen: memory, identity: identity);
      controller = wave.read(waveControllerProvider.notifier);
      await controller.start();
      await wave.read(listeningIdentityProvider.future);
      player = wave.read(playerControllerProvider.notifier);
    }

    String? current() => wave.read(playerControllerProvider).track?.id;

    test('a double tap dislikes once and skips once', () async {
      await setUpWave();
      memory.gate = Completer<void>();
      final first = controller.dislikeCurrent();
      final second = controller.dislikeCurrent();
      expect(await second, isNull);
      memory.gate!.complete();
      expect((await first)?.track.id, 't1');
      expect(current(), 't2');
      expect(memory.disliked, ['t1']);
    });

    test('a track change during the write is not skipped', () async {
      await setUpWave();
      memory.gate = Completer<void>();
      final pending = controller.dislikeCurrent();
      player.next();
      expect(current(), 't2');
      memory.gate!.complete();
      final done = await pending;
      expect(done?.track.id, 't1');
      expect(memory.kinds['t1'], SeenKind.disliked);
      expect(current(), 't2');
    });

    test('previous after a dislike never replays the disliked track', () async {
      await setUpWave();
      await controller.dislikeCurrent();
      expect(current(), 't2');
      player.previous();
      expect(current(), 't2');
    });

    test('the skip carries the neutral dislike cause', () async {
      await setUpWave();
      await controller.dislikeCurrent();
      expect(
        wave.read(playerControllerProvider).transitionCause,
        ListeningTransitionCause.dislike,
      );
    });

    test('undo goes to the account the dislike was made under', () async {
      var account = '42';
      memory = MemorySeenStore();
      wave = containerWith(
        PoolService(api),
        seen: memory,
        loader: () async => account,
      );
      controller = wave.read(waveControllerProvider.notifier);
      await controller.start();
      await wave.read(listeningIdentityProvider.future);
      final done = (await controller.dislikeCurrent())!;
      account = '43';
      wave.invalidate(listeningIdentityProvider);
      await wave.read(listeningIdentityProvider.future);
      await controller.undoDislike(done);
      expect(memory.undone, [('42', 't1')]);
    });

    test('the wave waits for a loading identity, then marks land', () async {
      final identity = Completer<String>();
      memory = MemorySeenStore();
      wave = containerWith(
        PoolService(api),
        seen: memory,
        loader: () => identity.future,
      );
      final start = wave.read(waveControllerProvider.notifier).start();
      await pumpEventQueue();
      expect(memory.kinds, isEmpty);
      expect(wave.read(playerControllerProvider).track, isNull);
      identity.complete('42');
      await start;
      await pumpEventQueue();
      expect(memory.kinds['t1'], SeenKind.shown);
    });

    test(
      'an account change while the identity loads discards the wave',
      () async {
        final identity = Completer<String>();
        memory = MemorySeenStore();
        wave = containerWith(
          PoolService(api),
          seen: memory,
          loader: () => identity.future,
        );
        final start = wave.read(waveControllerProvider.notifier).start();
        await pumpEventQueue();
        userToken = 'someone-else';
        wave.invalidate(authControllerProvider);
        identity.complete('42');
        await start;
        await pumpEventQueue();
        expect(memory.kinds, isEmpty);
        expect(wave.read(playerControllerProvider).track, isNull);
      },
    );

    test('a track that is not from the wave is not disliked', () async {
      await setUpWave();
      player.play(realTrack('foreign'));
      await pumpEventQueue();
      expect(await controller.dislikeCurrent(), isNull);
      expect(memory.disliked, isEmpty);
      expect(current(), 'foreign');
    });

    test('disposing during the write neither skips nor throws', () async {
      await setUpWave();
      memory.gate = Completer<void>();
      final pending = controller.dislikeCurrent();
      wave.dispose();
      memory.gate!.complete();
      expect(await pending, isNull);
    });

    test(
      'a failed write is reported, and the track is still skipped',
      () async {
        await setUpWave();
        memory.failWrites = true;
        final done = (await controller.dislikeCurrent())!;
        expect(done.saved, isFalse);
        expect(done.skipped, isTrue);
        expect(current(), 't2');
        expect(memory.disliked, isEmpty);
      },
    );

    test('the last queued track keeps playing and asks for more', () async {
      memory = MemorySeenStore();
      final hold = Completer<void>();
      final service = PoolService(api)
        ..scripted = [1]
        ..holdAfterFirst = hold;
      wave = containerWith(service, seen: memory);
      controller = wave.read(waveControllerProvider.notifier);
      await controller.start();
      await wave.read(listeningIdentityProvider.future);
      final done = (await controller.dislikeCurrent())!;
      expect(done.saved, isTrue);
      expect(done.skipped, isFalse);
      expect(current(), 't1');
      hold.complete();
      await pumpEventQueue();
    });

    test('a new wave with the same track id is not skipped', () async {
      await setUpWave();
      final gate = memory.gate = Completer<void>();
      final pending = controller.dislikeCurrent();
      await pumpEventQueue();
      controller.cancel();
      await controller.start();
      expect(current(), 't1');
      final before = player.upcomingTracks.length;
      gate.complete();
      final done = await pending;
      expect(done?.saved, isTrue);
      expect(done?.skipped, isFalse);
      expect(current(), 't1');
      expect(player.upcomingTracks.length, before);
    });

    test('a failed new wave never replays the previous wave results', () async {
      memory = MemorySeenStore();
      final service = PoolService(api)..scripted = [4];
      wave = containerWith(service, seen: memory);
      controller = wave.read(waveControllerProvider.notifier);
      player = wave.read(playerControllerProvider.notifier);
      await controller.start();
      player.next();
      expect(current(), 't2');
      // the next wave's searches fail, leaving earlier items behind
      service.failure = WaveFailure.network;
      await controller.start();
      expect(wave.read(waveControllerProvider).active, isFalse);
      expect(wave.read(recommendationsProvider).items, isEmpty);
      expect(wave.read(recommendationsProvider).error, WaveFailure.network);
      expect(current(), 't2');
    });

    test('a disliked track cannot come back when the queue wraps', () async {
      await setUpWave();
      await controller.dislikeCurrent();
      final played = <String?>[];
      for (var i = 0; i < 25; i++) {
        player.next();
        played.add(current());
      }
      expect(played, isNot(contains('t1')));
    });

    test('anonymous accounts get no button and no dislike', () async {
      await setUpWave(identity: 'anonymous');
      await wave.read(listeningIdentityProvider.future);
      expect(wave.read(currentTrackInWaveProvider), isFalse);
      expect(await controller.dislikeCurrent(), isNull);
      expect(memory.disliked, isEmpty);
    });

    test('undo uses the identity captured at dislike time', () async {
      await setUpWave();
      final done = (await controller.dislikeCurrent())!;
      expect(done.identity, '42');
      await controller.undoDislike(done);
      expect(memory.undone, [('42', 't1')]);
      expect(memory.disliked, isEmpty);
    });
  });

  for (final change in ['logout', 'cancel']) {
    test(
      '$change aborts a pending refill and does not change the queue',
      () async {
        pool.scripted = [4, 4];
        await container.read(waveControllerProvider.notifier).start();
        pool.holdAfterFirst = Completer<void>();
        final player = container.read(playerControllerProvider.notifier);
        player.next();
        await flush();
        switch (change) {
          case 'logout':
            userToken = 'another-account';
            container.invalidate(authControllerProvider);
            await flush();
          case 'cancel':
            container.read(waveControllerProvider.notifier).cancel();
        }
        final queued = player.upcomingTracks.map((t) => t.id).toList();
        pool.holdAfterFirst!.complete();
        await flush();
        expect(container.read(waveControllerProvider).active, isFalse);
        expect(container.read(waveControllerProvider).discovering, isFalse);
        expect(player.upcomingTracks.map((t) => t.id), queued);
      },
    );
  }
}

/// In-memory stand-in so widget tests need no file IO.
class MemorySeenStore extends SeenStore {
  final kinds = <String, SeenKind>{};
  final undone = <(String, String)>[];

  List<String> get disliked => [
    for (final e in kinds.entries)
      if (e.value == SeenKind.disliked) e.key,
  ];

  /// When set, dislike writes wait for it.
  Completer<void>? gate;
  bool failWrites = false;

  @override
  Future<bool> dislike(
    String identity,
    String trackId,
    String artist,
    DateTime at,
  ) async {
    await gate?.future;
    if (failWrites) return false;
    kinds[trackId] = SeenKind.disliked;
    return true;
  }

  @override
  Future<bool> undislike(String identity, String trackId) async {
    undone.add((identity, trackId));
    kinds.remove(trackId);
    return true;
  }

  @override
  Future<bool> record(
    String identity,
    SeenKind kind,
    Iterable<String> ids,
    DateTime at,
  ) async {
    for (final id in ids) {
      kinds.putIfAbsent(id, () => kind);
    }
    return true;
  }
}
