import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/api/liked_tracks.dart';
import 'package:waveform_app/core/audio/audio_engine.dart';
import 'package:waveform_app/features/player/player_controller.dart';
import 'package:waveform_app/shared/models/track.dart';

import '../support/fake_audio_engine.dart';
import '../support/stub_liked_tracks.dart';

Track t(String id) => Track(
  id: id,
  title: 'T$id',
  artist: 'A',
  durationMs: 100000,
  likes: 0,
  reposts: 0,
  plays: 0,
  waveform: const <double>[],
);

ProviderContainer harness(FakeAudioEngine engine) => ProviderContainer(
  overrides: [
    audioEngineProvider.overrideWithValue(engine),
    likedTracksProvider.overrideWith(StubLikedTracks.new),
  ],
);

void main() {
  test(
    'harness builds the controller and play() sets current without network',
    () {
      final engine = FakeAudioEngine();
      final c = harness(engine);
      addTearDown(c.dispose);
      final pc = c.read(playerControllerProvider.notifier);
      pc.play(t('1'), queue: [t('1'), t('2'), t('3')]);
      expect(c.read(playerControllerProvider).track?.id, '1');
      expect(pc.upcomingTracks.map((x) => x.id), ['2', '3']);
    },
  );

  test('playNext inserts right after current (linear)', () {
    final engine = FakeAudioEngine();
    final c = harness(engine);
    addTearDown(c.dispose);
    final pc = c.read(playerControllerProvider.notifier);
    pc.play(t('1'), queue: [t('1'), t('2'), t('3')]);
    pc.playNext(t('9'));
    expect(pc.upcomingTracks.map((x) => x.id), ['9', '2', '3']);
  });

  test('playNext de-dupes by moving an existing track to next', () {
    final engine = FakeAudioEngine();
    final c = harness(engine);
    addTearDown(c.dispose);
    final pc = c.read(playerControllerProvider.notifier);
    pc.play(t('1'), queue: [t('1'), t('2'), t('3')]);
    pc.playNext(t('3'));
    expect(pc.upcomingTracks.map((x) => x.id), ['3', '2']);
  });

  test('playNext on idle (no current track) puts it first', () {
    final engine = FakeAudioEngine();
    final c = harness(engine);
    addTearDown(c.dispose);
    final pc = c.read(playerControllerProvider.notifier);
    // no play() called → state.track is null
    pc.playNext(t('5'));
    expect(pc.upcomingTracks.map((x) => x.id), contains('5'));
  });

  test('playNext in shuffle mode puts track first in upcoming (heard next)', () {
    final engine = FakeAudioEngine();
    final c = harness(engine);
    addTearDown(c.dispose);
    final pc = c.read(playerControllerProvider.notifier);
    // play with a queue large enough that _generateAfter builds _order
    pc.play(t('1'), queue: [t('1'), t('2'), t('3'), t('4')]);
    // toggleShuffle calls _recomputeFrontierNext → _ensureOrder → _order built
    pc.toggleShuffle();
    // Now _activeSeq == _order (shuffle on, _order non-empty, same source)
    pc.playNext(t('9'));
    // Regardless of shuffle permutation, track '9' must be the very next heard
    expect(pc.upcomingTracks.first.id, '9');
  });

  group('forget', () {
    String? cur(ProviderContainer c) =>
        c.read(playerControllerProvider).track?.id;

    PlayerController setup(ProviderContainer c, String start) {
      final pc = c.read(playerControllerProvider.notifier);
      pc.play(t(start), queue: [t('1'), t('2'), t('3'), t('4')]);
      return pc;
    }

    test('prev after forgetting an earlier track skips it', () {
      final c = harness(FakeAudioEngine());
      addTearDown(c.dispose);
      final pc = setup(c, '1');
      pc.next();
      pc.next();
      expect(cur(c), '3');
      pc.forget('2');
      pc.previous();
      expect(cur(c), '1');
    });

    test('prev right after forgetting the one before stays on current', () {
      final c = harness(FakeAudioEngine());
      addTearDown(c.dispose);
      final pc = setup(c, '2');
      pc.next();
      pc.forget('2');
      pc.previous();
      expect(cur(c), '3');
    });

    test('forgetting the playing track drops it once playback moves on', () {
      final c = harness(FakeAudioEngine());
      addTearDown(c.dispose);
      final pc = setup(c, '1');
      pc.next();
      pc.forget('2');
      expect(cur(c), '2');
      pc.next();
      expect(cur(c), '3');
      pc.previous();
      expect(cur(c), '1');
      expect(pc.upcomingTracks.map((x) => x.id), isNot(contains('2')));
    });

    test('stepping back from a forgotten playing track drops it', () {
      final c = harness(FakeAudioEngine());
      addTearDown(c.dispose);
      final pc = setup(c, '1');
      pc.next();
      pc.forget('2');
      expect(cur(c), '2');
      pc.previous();
      expect(cur(c), '1');
      pc.next();
      expect(cur(c), isNot('2'));
    });

    test('a queue passed to play skips already forgotten tracks', () {
      final c = harness(FakeAudioEngine());
      addTearDown(c.dispose);
      final pc = setup(c, '1');
      pc.forget('3');
      pc.play(t('2'), queue: [t('1'), t('2'), t('3'), t('4')]);
      expect(pc.upcomingTracks.map((x) => x.id), ['4']);
      pc.next();
      expect(cur(c), '4');
    });

    test('unforget and explicit play make the track normal again', () {
      final c = harness(FakeAudioEngine());
      addTearDown(c.dispose);
      final pc = setup(c, '1');
      pc.next();
      pc.forget('2');
      pc.next();
      pc.unforget('2');
      pc.play(t('2'), queue: [t('1'), t('2'), t('3')]);
      pc.next();
      expect(cur(c), '3');
      pc.previous();
      expect(cur(c), '2');

      pc.forget('3');
      pc.play(t('3'), queue: [t('1'), t('2'), t('3')]);
      pc.next();
      pc.previous();
      expect(cur(c), '3');
    });

    test('history index stays consistent walking back and forward', () {
      final c = harness(FakeAudioEngine());
      addTearDown(c.dispose);
      final pc = setup(c, '1');
      pc.next();
      pc.next();
      pc.next();
      expect(cur(c), '4');
      pc.forget('2');
      pc.previous();
      expect(cur(c), '3');
      pc.previous();
      expect(cur(c), '1');
      pc.previous();
      expect(cur(c), '1');
      pc.next();
      expect(cur(c), '3');
      pc.next();
      expect(cur(c), '4');
    });
  });
}
