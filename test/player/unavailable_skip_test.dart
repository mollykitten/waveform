import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/api/liked_tracks.dart';
import 'package:waveform_app/core/api/mock_soundcloud_api.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/audio/audio_engine.dart';
import 'package:waveform_app/features/player/player_controller.dart';
import 'package:waveform_app/shared/models/track.dart';

import '../support/fake_audio_engine.dart';
import '../support/stub_liked_tracks.dart';

class PlayableApi extends MockSoundcloudApi {
  @override
  Future<String?> resolveStreamUrl(String transcodingUrl) async =>
      transcodingUrl;
}

Track t(String id, {bool blocked = false, bool playable = false}) => Track(
  id: id,
  title: 'T$id',
  artist: 'A',
  durationMs: 100000,
  likes: 0,
  reposts: 0,
  plays: 0,
  waveform: const <double>[],
  blocked: blocked,
  streamCandidates: playable ? ['https://example.com/$id'] : const [],
);

ProviderContainer harness(FakeAudioEngine engine) => ProviderContainer(
  overrides: [
    audioEngineProvider.overrideWithValue(engine),
    likedTracksProvider.overrideWith(StubLikedTracks.new),
    soundcloudApiProvider.overrideWithValue(PlayableApi()),
  ],
);

void main() {
  test('unavailable track is reported and skipped, not hung on', () {
    final engine = FakeAudioEngine();
    final c = harness(engine);
    addTearDown(c.dispose);
    final pc = c.read(playerControllerProvider.notifier);

    pc.play(t('1', blocked: true), queue: [t('1', blocked: true), t('2')]);

    final s = c.read(playerControllerProvider);
    expect(s.track?.id, '2');
    expect(s.unplayable?.title, 'T1');
  });

  test('early completion advances after the five-second guard', () async {
    final engine = FakeAudioEngine();
    final c = harness(engine);
    addTearDown(c.dispose);
    final pc = c.read(playerControllerProvider.notifier);
    final first = t('1', playable: true);
    pc.play(first, queue: [first, t('2')]);
    await pumpEventQueue();
    engine.emitCompleted();
    await pumpEventQueue();
    expect(c.read(playerControllerProvider).track?.id, '1');
    await Future<void>.delayed(const Duration(milliseconds: 5100));
    engine.emitPosition(const Duration(seconds: 30));
    engine.emitCompleted();
    await pumpEventQueue();
    expect(c.read(playerControllerProvider).track?.id, '2');
  });

  test('a chain of blocked tracks stops after the dead-skip limit', () {
    final engine = FakeAudioEngine();
    final c = harness(engine);
    addTearDown(c.dispose);
    final pc = c.read(playerControllerProvider.notifier);
    final q = [for (var i = 1; i <= 6; i++) t('$i', blocked: true)];

    pc.play(q.first, queue: q);

    final s = c.read(playerControllerProvider);
    expect(s.track?.id, '3');
    expect(s.isPlaying, false);
  });
}
