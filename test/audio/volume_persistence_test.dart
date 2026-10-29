import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/api/liked_tracks.dart';
import 'package:waveform_app/core/audio/audio_engine.dart';
import 'package:waveform_app/core/audio/playback_prefs.dart';
import 'package:waveform_app/core/storage/prefs_store.dart';
import 'package:waveform_app/features/player/player_controller.dart';

import '../support/fake_audio_engine.dart';
import '../support/stub_liked_tracks.dart';

ProviderContainer harness(Directory dir, FakeAudioEngine engine) =>
    ProviderContainer(
      overrides: [
        audioEngineProvider.overrideWithValue(engine),
        likedTracksProvider.overrideWith(StubLikedTracks.new),
        playbackPrefsStoreProvider.overrideWithValue(
          PrefsStore(directory: () async => dir),
        ),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('volume and mute survive a restart; first launch is moderate', () async {
    final dir = await Directory.systemTemp.createTemp('vol_prefs');
    addTearDown(() => dir.delete(recursive: true));

    final first = harness(dir, FakeAudioEngine());
    await first.read(playbackPrefsProvider.notifier).restored;
    expect(first.read(playerControllerProvider).volume, 0.5);

    first.read(playerControllerProvider.notifier).setVolume(0.3);
    first.read(playerControllerProvider.notifier).toggleMute();
    first.dispose(); // flushes the debounced write

    final engine = FakeAudioEngine();
    final second = harness(dir, engine);
    addTearDown(second.dispose);
    final pc = second.read(playerControllerProvider.notifier);
    await second.read(playbackPrefsProvider.notifier).restored;
    await Future<void>.delayed(Duration.zero);
    final s = second.read(playerControllerProvider);
    expect(s.volume, 0.3);
    expect(s.muted, isTrue);
    expect(pc, isNotNull);
  });
}
