import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/api/liked_tracks.dart';
import 'package:waveform_app/core/api/mock_soundcloud_api.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/audio/audio_engine.dart';
import 'package:waveform_app/core/audio/playback_prefs.dart';
import 'package:waveform_app/features/player/player_controller.dart';
import 'package:waveform_app/shared/models/track.dart';

import '../support/fake_audio_engine.dart';
import '../support/stub_liked_tracks.dart';

class _PlayableApi extends MockSoundcloudApi {
  @override
  Future<String?> resolveStreamUrl(String transcodingUrl) async =>
      transcodingUrl;
}

Track t(String id) => Track(
  id: id,
  title: 'T$id',
  artist: 'A',
  durationMs: 100000,
  likes: 0,
  reposts: 0,
  plays: 0,
  waveform: const <double>[],
  streamCandidates: ['https://example.com/$id'],
);

ProviderContainer harness(FakeAudioEngine engine) => ProviderContainer(
  overrides: [
    audioEngineProvider.overrideWithValue(engine),
    likedTracksProvider.overrideWith(StubLikedTracks.new),
    soundcloudApiProvider.overrideWithValue(_PlayableApi()),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'crossfade starts BEFORE track end (overlap), not at completion',
    () async {
      final engine = FakeAudioEngine()..preloadReady = true;
      final c = harness(engine);
      addTearDown(c.dispose);
      final pc = c.read(playerControllerProvider.notifier);
      c.read(playbackPrefsProvider.notifier).setCrossfadeMs(3000);
      pc.play(t('1'), queue: [t('1'), t('2'), t('3')]);
      await pumpEventQueue();

      // Far from the end → no early swap.
      engine.emitPosition(const Duration(milliseconds: 50000));
      await pumpEventQueue();
      expect(engine.swapCount, 0);

      // Within crossfade window of the end (2s left ≤ 3s) → swap fires early,
      // with the user's crossfade duration.
      engine.emitPosition(const Duration(milliseconds: 98000));
      await pumpEventQueue();
      expect(engine.swapCount, 1);
      expect(engine.lastSwapCrossfade, const Duration(milliseconds: 3000));
      // Now-playing advanced to the next track at fade start.
      expect(c.read(playerControllerProvider).track?.id, '2');
    },
  );

  test(
    'no early swap when crossfade is disabled (gapless handled at completion)',
    () async {
      final engine = FakeAudioEngine()..preloadReady = true;
      final c = harness(engine);
      addTearDown(c.dispose);
      final pc = c.read(playerControllerProvider.notifier);
      // crossfade left at default 0
      pc.play(t('1'), queue: [t('1'), t('2'), t('3')]);
      await pumpEventQueue();

      engine.emitPosition(const Duration(milliseconds: 99000));
      await pumpEventQueue();
      expect(engine.swapCount, 0);
    },
  );

  test('no early swap when preload not ready', () async {
    final engine = FakeAudioEngine(); // preloadReady stays false
    final c = harness(engine);
    addTearDown(c.dispose);
    final pc = c.read(playerControllerProvider.notifier);
    c.read(playbackPrefsProvider.notifier).setCrossfadeMs(3000);
    pc.play(t('1'), queue: [t('1'), t('2'), t('3')]);
    await pumpEventQueue();

    engine.emitPosition(const Duration(milliseconds: 98000));
    await pumpEventQueue();
    expect(engine.swapCount, 0);
  });
}
