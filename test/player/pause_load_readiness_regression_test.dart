import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:waveform_app/core/api/liked_tracks.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/audio/audio_engine.dart';
import 'package:waveform_app/core/recommendations/listening_event.dart';
import 'package:waveform_app/core/recommendations/listening_providers.dart';
import 'package:waveform_app/core/recommendations/listening_tracker.dart';
import 'package:waveform_app/features/player/player_controller.dart';

import '../recommendations/support.dart';
import '../support/stub_liked_tracks.dart';

class _Api extends TestSoundcloud {
  @override
  Future<String?> resolveStreamUrl(String url) async => url;
}

class _Player implements AudioPlayer {
  final positions = StreamController<Duration>.broadcast();
  final buffers = StreamController<Duration>.broadcast();
  final playingEvents = StreamController<bool>.broadcast();
  final states = StreamController<ProcessingState>.broadcast();
  final urls = <String>[];
  Future<void> Function()? onPause;

  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<Duration> get bufferedPositionStream => buffers.stream;
  @override
  Stream<bool> get playingStream => playingEvents.stream;
  @override
  Stream<ProcessingState> get processingStateStream => states.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #setUrl:
        urls.add(invocation.positionalArguments.first as String);
        return Future<Duration?>.value(const Duration(seconds: 120));
      case #play:
        playingEvents.add(true);
        return Completer<void>().future;
      case #pause:
      case #stop:
        playingEvents.add(false);
        return onPause?.call() ?? Future<void>.value();
      case #setVolume:
      case #seek:
        return Future<void>.value();
      case #dispose:
        unawaited(positions.close());
        unawaited(buffers.close());
        unawaited(playingEvents.close());
        unawaited(states.close());
        return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final checkListening in [false, true]) {
    test(
      checkListening
          ? 'cancelled load cannot count outgoing source as incoming listening'
          : 'pause during incoming load preserves the selected audio source',
      () async {
        final players = <_Player>[];
        final engine = JustAudioEngine(
          Talker(),
          createPlayer: () {
            final player = _Player();
            players.add(player);
            return player;
          },
        );
        var now = 0;
        final events = <ListeningEvent>[];
        final tracker = ListeningTracker(
          onEvent: events.add,
          monotonicMs: () => now,
        )..setIdentity('123');
        final container = ProviderContainer(
          overrides: [
            audioEngineProvider.overrideWithValue(engine),
            soundcloudApiProvider.overrideWithValue(_Api()),
            likedTracksProvider.overrideWith(StubLikedTracks.new),
            listeningTrackerProvider.overrideWithValue(tracker),
          ],
        );
        addTearDown(() {
          container.dispose();
          engine.dispose();
        });
        final controller = container.read(playerControllerProvider.notifier);
        final first = realTrack('a');
        final incoming = realTrack('b');
        controller.play(first);
        await pumpEventQueue();
        expect(players.first.urls.last, first.streamCandidates.single);

        final cleanupStarted = Completer<void>();
        final cleanup = Completer<void>();
        players[1].onPause = () {
          if (cleanupStarted.isCompleted) return Future<void>.value();
          cleanupStarted.complete();
          return cleanup.future;
        };
        controller.play(incoming);
        await cleanupStarted.future;
        controller.toggle();
        await pumpEventQueue();
        cleanup.complete();
        await pumpEventQueue();
        controller.toggle();
        await pumpEventQueue();

        if (!checkListening) {
          expect(container.read(playerControllerProvider).track?.id, 'b');
          expect(players.first.urls.last, incoming.streamCandidates.single);
          return;
        }
        final incomingWasLoaded =
            players.first.urls.last == incoming.streamCandidates.single;
        for (var second = 1; second <= 6; second++) {
          now += 1000;
          players.first.positions.add(Duration(seconds: second));
          await pumpEventQueue(times: 1);
        }
        controller.play(realTrack('c'));
        await pumpEventQueue();
        final observed = events.singleWhere((event) => event.trackId == 'b');
        expect(
          observed.heardMs,
          incomingWasLoaded ? 6000 : 0,
          reason: 'incoming metadata must never inherit outgoing source audio',
        );
      },
    );
  }
}
