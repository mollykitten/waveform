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

Track _track(String id) => Track(
  id: id,
  title: id,
  artist: 'artist',
  durationMs: 100000,
  likes: 0,
  reposts: 0,
  plays: 0,
  waveform: const [],
  streamCandidates: ['https://example.com/$id'],
);

class _Api extends MockSoundcloudApi {
  final pending = <String, Completer<String?>>{};

  @override
  Future<String?> resolveStreamUrl(String url) async =>
      pending[url]?.future ?? Future.value(url);
}

class _Engine extends FakeAudioEngine {
  final pendingLoads = <String, Completer<void>>{};
  Completer<void>? pendingSwap;
  final playing = StreamController<bool>.broadcast();

  @override
  Stream<bool> get playingStream => playing.stream;

  @override
  Future<void> load(String url) async {
    await pendingLoads[url]?.future;
    await super.load(url);
  }

  @override
  Future<void> swapToNext({Duration crossfade = Duration.zero}) async {
    await super.swapToNext(crossfade: crossfade);
    await pendingSwap?.future;
  }

  @override
  void dispose() {
    playing.close();
    super.dispose();
  }
}

class _Harness {
  _Harness() {
    container = ProviderContainer(
      overrides: [
        audioEngineProvider.overrideWithValue(engine),
        soundcloudApiProvider.overrideWithValue(api),
        likedTracksProvider.overrideWith(StubLikedTracks.new),
        listeningTrackerProvider.overrideWithValue(
          ListeningTracker(onEvent: events.add, monotonicMs: () => now)
            ..setIdentity('123'),
        ),
      ],
    );
    player = container.read(playerControllerProvider.notifier);
    addTearDown(dispose);
  }

  final engine = _Engine();
  final api = _Api();
  final events = <ListeningEvent>[];
  int now = 0;
  late final ProviderContainer container;
  late final PlayerController player;
  bool disposed = false;

  void dispose() {
    if (disposed) return;
    disposed = true;
    container.dispose();
    engine.dispose();
  }

  Future<void> hear(int start, int end) async {
    for (var second = start; second <= end; second++) {
      now += 1000;
      engine.emitPosition(Duration(seconds: second));
      await pumpEventQueue(times: 1);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'pending resolve preserves old evidence and counts genuine next audio',
    () async {
      final h = _Harness();
      final first = _track('a');
      final second = _track('b');
      final resolve = Completer<String?>();
      h.api.pending[second.streamCandidates.single] = resolve;
      h.player.play(first, queue: [first, second, _track('c')]);
      await pumpEventQueue();
      await h.hear(1, 7);
      h.player.next();
      await h.hear(8, 16);
      h.engine.playing.add(false);
      h.engine.emitCompleted();
      await pumpEventQueue();
      expect(h.container.read(playerControllerProvider).track?.id, 'b');
      expect(h.events.single.heardMs, 7000);
      expect(h.events.single.trackId, 'a');
      resolve.complete(second.streamCandidates.single);
      await pumpEventQueue();
      h.engine.emitPosition(Duration.zero);
      await pumpEventQueue();
      await h.hear(1, 6);
      h.player.next();
      expect(h.events.last.trackId, 'b');
      expect(h.events.last.heardMs, 6000);
      expect(h.events.last.evidence, ListeningEvidence.negative);
      await pumpEventQueue();
    },
  );

  test(
    'stale load completion cannot make a superseding pending source ready',
    () async {
      final h = _Harness();
      h.player.play(_track('a'));
      await pumpEventQueue();
      final loadB = Completer<void>();
      final loadC = Completer<void>();
      h.engine.pendingLoads['https://example.com/b'] = loadB;
      h.engine.pendingLoads['https://example.com/c'] = loadC;
      h.player.play(_track('b'));
      await pumpEventQueue();
      await h.hear(1, 6);
      h.player.play(_track('c'));
      await pumpEventQueue();
      loadB.complete();
      await pumpEventQueue();
      h.engine.playing.add(true);
      await h.hear(7, 15);
      expect(h.events.last.trackId, 'b');
      expect(h.events.last.heardMs, 0);
      loadC.complete();
      await pumpEventQueue();
      h.engine.emitPosition(Duration.zero);
      await pumpEventQueue();
      await h.hear(1, 5);
      h.player.play(_track('d'));
      expect(h.events.last.trackId, 'c');
      expect(h.events.last.heardMs, 5000);
      await pumpEventQueue();
    },
  );

  test(
    'replay has a new ready generation and pause and seek remain excluded',
    () async {
      final h = _Harness();
      h.player.play(_track('a'));
      await pumpEventQueue();
      await h.hear(1, 5);
      final replay = Completer<void>();
      h.engine.pendingLoads['https://example.com/a'] = replay;
      h.player.play(_track('a'));
      await pumpEventQueue();
      await h.hear(6, 12);
      replay.complete();
      await pumpEventQueue();
      h.engine.emitPosition(Duration.zero);
      await pumpEventQueue();
      await h.hear(1, 2);
      h.player.toggle();
      await h.hear(3, 8);
      h.player.toggle();
      h.player.seekFraction(.5);
      await h.hear(51, 52);
      h.player.play(_track('b'));
      expect(h.events.map((event) => event.heardMs), [5000, 4000]);
      expect(h.events[1].seekCount, 1);
      expect(h.events[1].sessionId, isNot(h.events[0].sessionId));
      await pumpEventQueue();
    },
  );

  test(
    'pending swap ignores outgoing audio and resumes incoming observations',
    () async {
      final h = _Harness();
      h.engine.preloadReady = true;
      h.container.read(playbackPrefsProvider.notifier).setCrossfadeMs(3000);
      h.player.play(_track('a'), queue: [_track('a'), _track('b')]);
      await pumpEventQueue();
      await h.hear(1, 5);
      final swap = Completer<void>();
      h.engine.pendingSwap = swap;
      h.engine.emitPosition(const Duration(seconds: 98));
      await pumpEventQueue();
      expect(h.engine.swapCount, 1);
      await h.hear(99, 100);
      swap.complete();
      await pumpEventQueue();
      h.engine.emitPosition(Duration.zero);
      await pumpEventQueue();
      await h.hear(1, 6);
      h.player.next();
      expect(h.events[0].trackId, 'a');
      expect(h.events[0].heardMs, 5000);
      expect(h.events[0].cause, ListeningTransitionCause.crossfadeCompletion);
      expect(h.events[1].trackId, 'b');
      expect(h.events[1].heardMs, 6000);
      await pumpEventQueue();
    },
  );

  for (final loading in [false, true]) {
    for (final fails in [false, true]) {
      test(
        'disposed pending source is ignored (load: $loading, fails: $fails)',
        () async {
          final h = _Harness();
          final resolve = Completer<String?>();
          final load = Completer<void>();
          const url = 'https://example.com/a';
          if (loading) {
            h.engine.pendingLoads[url] = load;
          } else {
            h.api.pending[url] = resolve;
          }
          h.player.play(_track('a'));
          await pumpEventQueue();
          h.dispose();
          if (loading) {
            if (fails) {
              load.completeError(StateError('late load failure'));
            } else {
              load.complete();
            }
          } else if (fails) {
            resolve.completeError(StateError('late resolve failure'));
          } else {
            resolve.complete(url);
          }
          await pumpEventQueue();
          expect(h.events.single.cause, ListeningTransitionCause.disposal);
          expect(h.events.single.heardMs, 0);
          expect(h.events.single.evidence, ListeningEvidence.neutral);
        },
      );
    }
  }

  test(
    'queue append during manual-next resolve preloads the new frontier',
    () async {
      final h = _Harness();
      final resolve = Completer<String?>();
      h.api.pending['https://example.com/b'] = resolve;
      h.player.play(_track('a'), queue: [_track('a'), _track('b')]);
      await pumpEventQueue();
      h.player.next();
      h.player.addToQueue(_track('c'));
      h.player.toggleRepeat();
      h.player.toggleRepeat();
      await pumpEventQueue();
      resolve.complete('https://example.com/b');
      await pumpEventQueue();
      expect(h.container.read(playerControllerProvider).track?.id, 'b');
      expect(h.engine.lastLoadedUrl, 'https://example.com/b');
      expect(h.engine.lastPreloadUrl, 'https://example.com/c');
    },
  );
}
