import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/api/liked_tracks.dart';
import 'package:waveform_app/core/api/mock_soundcloud_api.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/audio/audio_engine.dart';
import 'package:waveform_app/core/audio/playback_prefs.dart';
import 'package:waveform_app/core/recommendations/listening_event.dart';
import 'package:waveform_app/core/recommendations/listening_providers.dart';
import 'package:waveform_app/core/recommendations/listening_tracker.dart';
import 'package:waveform_app/features/player/player_controller.dart';
import 'package:waveform_app/shared/models/track.dart';

import '../support/fake_audio_engine.dart';
import '../support/stub_liked_tracks.dart';

class PlayableApi extends MockSoundcloudApi {
  @override
  Future<String?> resolveStreamUrl(String transcodingUrl) async =>
      transcodingUrl;
}

class DeferredPlayableApi extends PlayableApi {
  final pending = Completer<String?>();

  @override
  Future<String?> resolveStreamUrl(String transcodingUrl) =>
      transcodingUrl.endsWith('/2')
      ? pending.future
      : super.resolveStreamUrl(transcodingUrl);
}

Track track(String id, {bool blocked = false, bool playable = false}) => Track(
  id: id,
  title: id,
  artist: 'artist',
  durationMs: 100000,
  likes: 0,
  reposts: 0,
  plays: 0,
  waveform: const [],
  blocked: blocked,
  streamCandidates: playable ? ['https://example.com/$id'] : const [],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'old audio while resolving next track cannot become its feedback',
    () async {
      final engine = FakeAudioEngine();
      final api = DeferredPlayableApi();
      final events = <ListeningEvent>[];
      var now = 0;
      final tracker = ListeningTracker(
        onEvent: events.add,
        monotonicMs: () => now,
      )..setIdentity('123');
      final container = ProviderContainer(
        overrides: [
          audioEngineProvider.overrideWithValue(engine),
          likedTracksProvider.overrideWith(StubLikedTracks.new),
          soundcloudApiProvider.overrideWithValue(api),
          listeningTrackerProvider.overrideWithValue(tracker),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(() async {
        api.pending.complete('https://example.com/2');
        await pumpEventQueue();
      });
      final first = track('1', playable: true);
      final second = track('2', playable: true);
      final player = container.read(playerControllerProvider.notifier);
      player.play(first, queue: [first, second, track('3')]);
      await pumpEventQueue();
      engine.emitPosition(const Duration(seconds: 60));
      await pumpEventQueue();

      player.next();
      // Resolving 2 is still pending, so every tick is from the audible track 1.
      for (var second = 61; second <= 70; second++) {
        now += 1000;
        engine.emitPosition(Duration(seconds: second));
        await pumpEventQueue(times: 1);
      }
      expect(engine.lastLoadedUrl, 'https://example.com/1');
      player.next();
      final unheard = events.singleWhere((event) => event.trackId == '2');
      expect(unheard.heardMs, 0);
      expect(unheard.evidence, ListeningEvidence.neutral);
    },
  );
  test(
    'completed stream and repeat preserve natural completion intent',
    () async {
      final engines = [FakeAudioEngine(), FakeAudioEngine()];
      final events = [<ListeningEvent>[], <ListeningEvent>[]];
      var now = 0;
      final containers = [
        for (var i = 0; i < 2; i++)
          ProviderContainer(
            overrides: [
              audioEngineProvider.overrideWithValue(engines[i]),
              likedTracksProvider.overrideWith(StubLikedTracks.new),
              soundcloudApiProvider.overrideWithValue(PlayableApi()),
              listeningTrackerProvider.overrideWithValue(
                ListeningTracker(onEvent: events[i].add, monotonicMs: () => now)
                  ..setIdentity('123'),
              ),
            ],
          ),
      ];
      for (final container in containers) {
        addTearDown(container.dispose);
      }
      final players = containers
          .map((c) => c.read(playerControllerProvider.notifier))
          .toList();
      for (final player in players) {
        final first = track('1', playable: true);
        player.play(first, queue: [first, track('2')]);
      }
      players[1].toggleRepeat();
      await pumpEventQueue();
      // Preserve the existing controller's real five-second broken-source guard.
      // Hearing itself uses the injected monotonic clock below.
      await Future<void>.delayed(const Duration(milliseconds: 5100));
      for (var second = 1; second <= 99; second++) {
        now += 1000;
        for (final engine in engines) {
          engine.emitPosition(Duration(seconds: second));
        }
        await pumpEventQueue(times: 1);
      }
      for (final engine in engines) {
        engine.emitCompleted();
      }
      await pumpEventQueue();
      expect(containers[0].read(playerControllerProvider).track?.id, '2');
      expect(containers[1].read(playerControllerProvider).track?.id, '1');
      expect(containers[1].read(playerControllerProvider).sessionVersion, 2);
      expect(engines[1].lastSeek, Duration.zero);
      for (final recorded in events) {
        expect(
          recorded.single.cause,
          ListeningTransitionCause.naturalCompletion,
        );
        expect(recorded.single.heardMs, 99000);
        expect(recorded.single.evidence, ListeningEvidence.positive);
      }
      players[0].next();
      expect(events[0].last.cause, ListeningTransitionCause.manualNext);
      engines[1].emitPosition(Duration.zero);
      await pumpEventQueue();
      now += 1000;
      engines[1].emitPosition(const Duration(seconds: 1));
      await pumpEventQueue();
      players[1].play(track('1'));
      expect(events[1].last.sessionId, isNot(events[1].first.sessionId));
      expect(events[1].last.heardMs, 1000);
    },
  );
  test('manual next and automatic unavailable skip expose distinct causes', () {
    final engine = FakeAudioEngine();
    final container = ProviderContainer(
      overrides: [
        audioEngineProvider.overrideWithValue(engine),
        likedTracksProvider.overrideWith(StubLikedTracks.new),
      ],
    );
    addTearDown(container.dispose);
    final player = container.read(playerControllerProvider.notifier);
    player.play(track('1'), queue: [track('1'), track('2')]);
    player.next();
    final manual = container.read(playerControllerProvider);
    expect(manual.transitionCause, ListeningTransitionCause.manualNext);
    player.play(
      track('3', blocked: true),
      queue: [track('3', blocked: true), track('4')],
    );
    final automatic = container.read(playerControllerProvider);
    expect(automatic.transitionCause, ListeningTransitionCause.unplayable);
  });

  test(
    'crossfade records completion and same-track direct replay is distinct',
    () async {
      final engine = FakeAudioEngine()..preloadReady = true;
      final events = <ListeningEvent>[];
      final tracker = ListeningTracker(onEvent: events.add)..setIdentity('123');
      final container = ProviderContainer(
        overrides: [
          audioEngineProvider.overrideWithValue(engine),
          likedTracksProvider.overrideWith(StubLikedTracks.new),
          soundcloudApiProvider.overrideWithValue(PlayableApi()),
          listeningTrackerProvider.overrideWithValue(tracker),
        ],
      );
      addTearDown(container.dispose);
      final player = container.read(playerControllerProvider.notifier);
      container.read(playbackPrefsProvider.notifier).setCrossfadeMs(3000);
      player.play(
        track('1', playable: true),
        queue: [track('1', playable: true), track('2', playable: true)],
      );
      await pumpEventQueue();
      engine.emitPosition(const Duration(seconds: 98));
      await pumpEventQueue();
      expect(events.single.cause, ListeningTransitionCause.crossfadeCompletion);
      expect(events.single.heardMs, 0);
      expect(events.single.finalPositionMs, 98000);
      expect(
        container.read(playerControllerProvider).transitionCause,
        ListeningTransitionCause.crossfadeCompletion,
      );
      player.play(track('2'));
      final session = container.read(playerControllerProvider).sessionVersion;
      player.play(track('2'));
      expect(
        container.read(playerControllerProvider).sessionVersion,
        session + 1,
      );
      expect(events[1].cause, ListeningTransitionCause.directSelection);
      expect(events[2].cause, ListeningTransitionCause.directSelection);
      expect(events[1].sessionId, isNot(events[2].sessionId));
      player.seekBy(const Duration(seconds: 5));
      expect(container.read(playerControllerProvider).seekVersion, 1);
      expect(
        container.read(playerControllerProvider).sessionVersion,
        session + 1,
      );
      player.previous();
      expect(
        container.read(playerControllerProvider).sessionVersion,
        session + 2,
      );
      expect(events.last.cause, ListeningTransitionCause.manualRestart);
    },
  );
}
