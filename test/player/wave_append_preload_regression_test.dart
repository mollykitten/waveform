import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/api/liked_tracks.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/audio/audio_engine.dart';
import 'package:waveform_app/core/audio/playback_prefs.dart';
import 'package:waveform_app/features/player/player_controller.dart';

import '../recommendations/support.dart';
import '../support/fake_audio_engine.dart';
import '../support/stub_liked_tracks.dart';

class _DistinctStreams extends TestSoundcloud {
  final pending = <String, Completer<String?>>{};

  @override
  Future<String?> resolveStreamUrl(String transcodingUrl) async =>
      pending[transcodingUrl]?.future ?? Future.value(transcodingUrl);
}

class _SourceTrackingEngine extends FakeAudioEngine {
  String? audibleUrl;

  @override
  Future<void> load(String url) async {
    audibleUrl = url;
    await super.load(url);
  }

  @override
  Future<void> preloadNext(String? url) async {
    await super.preloadNext(url);
    preloadReady = url != null;
  }

  @override
  Future<void> swapToNext({Duration crossfade = Duration.zero}) async {
    audibleUrl = lastPreloadUrl;
    preloadReady = false;
    await super.swapToNext(crossfade: crossfade);
  }
}

Future<void> _flush() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'late wave append keeps the next audio source aligned with metadata',
    () async {
      final engine = _SourceTrackingEngine();
      final container = ProviderContainer(
        overrides: [
          audioEngineProvider.overrideWithValue(engine),
          soundcloudApiProvider.overrideWithValue(_DistinctStreams()),
          likedTracksProvider.overrideWith(StubLikedTracks.new),
          playbackPrefsProvider.overrideWithBuild(
            (ref, notifier) => const PlaybackPrefs(crossfadeMs: 1000),
          ),
        ],
      );
      addTearDown(() {
        container.dispose();
        engine.dispose();
      });
      final first = realTrack('a');
      final last = realTrack('b');
      final appended = realTrack('c');
      final player = container.read(playerControllerProvider.notifier);
      player.play(last, queue: [first, last]);
      await _flush();
      expect(engine.lastPreloadUrl, first.streamCandidates.single);

      // WaveController uses this exact API when an asynchronous refill arrives.
      player.addToQueue(appended);
      await _flush();
      engine.emitPosition(const Duration(milliseconds: 119500));
      await _flush();

      expect(container.read(playerControllerProvider).track?.id, appended.id);
      expect(engine.swapCount, 1);
      expect(engine.audibleUrl, appended.streamCandidates.single);
    },
  );

  test(
    'queue mutation invalidates a ready preload before replacement resolves',
    () async {
      final engine = _SourceTrackingEngine();
      final api = _DistinctStreams();
      final container = ProviderContainer(
        overrides: [
          audioEngineProvider.overrideWithValue(engine),
          soundcloudApiProvider.overrideWithValue(api),
          likedTracksProvider.overrideWith(StubLikedTracks.new),
          playbackPrefsProvider.overrideWithBuild(
            (ref, notifier) => const PlaybackPrefs(crossfadeMs: 1000),
          ),
        ],
      );
      addTearDown(() {
        container.dispose();
        engine.dispose();
      });
      final first = realTrack('a');
      final last = realTrack('b');
      final appended = realTrack('c');
      final replacement = Completer<String?>();
      api.pending[appended.streamCandidates.single] = replacement;
      final player = container.read(playerControllerProvider.notifier);
      player.play(last, queue: [first, last]);
      await _flush();
      expect(engine.lastPreloadUrl, first.streamCandidates.single);
      player.addToQueue(appended);
      engine.emitPosition(const Duration(milliseconds: 119500));
      await _flush();
      expect(engine.swapCount, 0);
      expect(container.read(playerControllerProvider).track?.id, last.id);
      replacement.complete(appended.streamCandidates.single);
      await _flush();
      engine.emitPosition(const Duration(milliseconds: 119600));
      await _flush();
      expect(container.read(playerControllerProvider).track?.id, appended.id);
      expect(engine.audibleUrl, appended.streamCandidates.single);
    },
  );
}
