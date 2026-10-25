import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show AudioPlayer, ProcessingState;
import 'package:talker_flutter/talker_flutter.dart';
import 'package:waveform_app/core/api/liked_tracks.dart';
import 'package:waveform_app/core/api/mock_soundcloud_api.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/audio/audio_engine.dart';
import 'package:waveform_app/core/audio/playback_prefs.dart';
import 'package:waveform_app/features/player/player_controller.dart';
import 'package:waveform_app/shared/models/track.dart';

import '../support/stub_liked_tracks.dart';

class _Api extends MockSoundcloudApi {
  Completer<String?>? replacement;

  @override
  Future<String?> resolveStreamUrl(String transcodingUrl) async {
    if (transcodingUrl.endsWith('/replacement') && replacement != null) {
      return replacement!.future;
    }
    return transcodingUrl;
  }
}

class _Player implements AudioPlayer {
  final positions = StreamController<Duration>.broadcast();
  final playingEvents = StreamController<bool>.broadcast();
  final states = StreamController<ProcessingState>.broadcast();
  final buffers = StreamController<Duration>.broadcast();
  final urls = <String>[];
  bool isPlaying = false;
  @override
  double volume = 1;
  int plays = 0;
  bool failSeek = false;

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
        return Future<Duration?>.value(const Duration(seconds: 100));
      case #setVolume:
        volume = invocation.positionalArguments.first as double;
        return Future<void>.value();
      case #play:
        isPlaying = true;
        plays++;
        playingEvents.add(true);
        return Completer<void>().future;
      case #pause:
      case #stop:
        isPlaying = false;
        playingEvents.add(false);
        return Future<void>.value();
      case #seek:
        if (failSeek) return Future<void>.error(StateError('seek failed'));
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

class _Harness {
  final api = _Api();
  final players = <_Player>[];
  final bindingStarted = Completer<void>();
  final binding = Completer<void>();
  late final JustAudioEngine engine;
  late final ProviderContainer container;
  late final PlayerController controller;
  bool failBinding = false;
  bool preservePlayer = false;
  bool failRetainedBinding = false;
  AudioPlayer? routedPlayer;

  _Harness() {
    engine = JustAudioEngine(
      TalkerFlutter.init(),
      preservePlayer: () => preservePlayer,
      createPlayer: () {
        final player = _Player();
        players.add(player);
        return player;
      },
      bindAudioOutput: (player) async {
        routedPlayer = player;
        if (failRetainedBinding &&
            identical(player, players[0]) &&
            players[0].urls.length > 1) {
          throw StateError('retained binding failed');
        }
        if (identical(player, players[1]) && !bindingStarted.isCompleted) {
          bindingStarted.complete();
          await binding.future;
          if (failBinding) throw StateError('binding failed');
        }
      },
    );
    container = ProviderContainer(
      overrides: [
        audioEngineProvider.overrideWithValue(engine),
        likedTracksProvider.overrideWith(StubLikedTracks.new),
        soundcloudApiProvider.overrideWithValue(api),
      ],
    );
    controller = container.read(playerControllerProvider.notifier);
    container.read(playbackPrefsProvider.notifier).setCrossfadeMs(100);
    addTearDown(() {
      container.dispose();
      engine.dispose();
    });
  }

  PlayerState get state => container.read(playerControllerProvider);

  Future<void> startSwap() async {
    final queue = [_track('first'), _track('next'), _track('third')];
    controller.play(queue.first, queue: queue);
    await pumpEventQueue();
    expect(engine.hasPreload, isTrue);
    players.first.positions.add(const Duration(milliseconds: 99950));
    await bindingStarted.future;
    expect(state.track?.id, 'next');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('AirPlay retention during paused binding keeps next paused', () async {
    final h = _Harness();
    await h.startSwap();
    h.controller.toggle();
    await pumpEventQueue();
    h.preservePlayer = true;
    h.binding.complete();
    await pumpEventQueue();
    expect(h.state.track?.id, 'next');
    expect(h.state.isPlaying, isFalse);
    expect(h.players[0].urls.last, 'https://example.com/next');
    expect(h.players.every((player) => !player.isPlaying), isTrue);
    expect(h.routedPlayer, same(h.players[0]));
    h.controller.toggle();
    await pumpEventQueue();
    expect(h.players[0].isPlaying, isTrue);
    expect(h.players[1].isPlaying, isFalse);
  });

  test(
    'failure after source commit keeps incoming metadata and stops audio',
    () async {
      final h = _Harness();
      await h.startSwap();
      h.players[1].failSeek = true;
      h.binding.complete();
      await pumpEventQueue();
      expect(h.state.track?.id, 'next');
      expect(h.state.isPlaying, isFalse);
      expect(h.state.unplayable?.title, 'next');
      expect(h.players.every((player) => !player.isPlaying), isTrue);
      h.players[1].failSeek = false;
      h.controller.toggle();
      await pumpEventQueue();
      expect(h.players[1].isPlaying, isTrue);
      expect(h.players[0].isPlaying, isFalse);
    },
  );

  test(
    'retained-player binding failure never rolls back to outgoing metadata',
    () async {
      final h = _Harness();
      await h.startSwap();
      h.preservePlayer = true;
      h.failRetainedBinding = true;
      h.binding.complete();
      await pumpEventQueue();
      expect(h.players[0].urls.last, 'https://example.com/next');
      expect(h.state.track?.id, 'next');
      expect(h.state.isPlaying, isFalse);
      expect(h.state.unplayable?.title, 'next');
      expect(h.players.every((player) => !player.isPlaying), isTrue);
    },
  );

  test(
    'pause during binding retains incoming track without autoplay',
    () async {
      final h = _Harness();
      await h.startSwap();
      h.controller.toggle();
      await pumpEventQueue();
      h.binding.complete();
      await pumpEventQueue();

      expect(h.state.track?.id, 'next');
      expect(h.state.isPlaying, isFalse);
      expect(h.players.every((player) => !player.isPlaying), isTrue);
      expect(h.routedPlayer, same(h.players[1]));
      // Following preload must go to the old player, never overwrite "next".
      expect(h.players[1].urls, ['https://example.com/next']);
      expect(h.players[0].urls.last, 'https://example.com/third');
      h.controller.toggle();
      await pumpEventQueue();
      expect(h.players[1].isPlaying, isTrue);
      expect(h.players[0].isPlaying, isFalse);
      h.controller.previous();
      expect(h.state.track?.id, 'first');
      await pumpEventQueue();
    },
  );

  test('binding failure restores metadata and allows the next swap', () async {
    final h = _Harness()..failBinding = true;
    await h.startSwap();
    h.binding.complete();
    await pumpEventQueue();
    expect(h.state.track?.id, 'first');
    expect(h.routedPlayer, same(h.players[0]));
    expect(h.players[0].isPlaying, isTrue);
    expect(h.players[1].isPlaying, isFalse);
    expect(h.engine.hasPreload, isTrue);
    h.players[0].positions.add(const Duration(milliseconds: 99950));
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(h.state.track?.id, 'next');
    expect(h.players[1].isPlaying, isTrue);
    h.controller.previous();
    expect(h.state.track?.id, 'first');
    await pumpEventQueue();
  });

  test(
    'resume before binding completes waits for the incoming player',
    () async {
      final h = _Harness();
      await h.startSwap();
      h.controller.toggle();
      await pumpEventQueue();
      h.controller.toggle();
      await pumpEventQueue();
      expect(h.players[0].plays, 1);
      expect(h.players[1].plays, 0);
      h.binding.complete();
      await pumpEventQueue();
      expect(h.state.track?.id, 'next');
      expect(h.state.isPlaying, isTrue);
      expect(h.players[0].isPlaying, isFalse);
      expect(h.players[1].isPlaying, isTrue);
      expect(h.players[1].volume, 1);
    },
  );

  test(
    'paused binding failure restores the old track without autoplay',
    () async {
      final h = _Harness()..failBinding = true;
      await h.startSwap();
      h.controller.toggle();
      await pumpEventQueue();
      h.binding.complete();
      await pumpEventQueue();
      expect(h.state.track?.id, 'first');
      expect(h.state.isPlaying, isFalse);
      expect(h.players.every((player) => !player.isPlaying), isTrue);
      h.controller.toggle();
      await pumpEventQueue();
      expect(h.players[0].isPlaying, isTrue);
      expect(h.players[1].isPlaying, isFalse);
      h.controller.next();
      expect(h.state.track?.id, 'next');
      await pumpEventQueue();
    },
  );

  test('new play cancels binding before its stream URL resolves', () async {
    final h = _Harness();
    await h.startSwap();
    final replacement = Completer<String?>();
    h.api.replacement = replacement;
    final queue = [_track('replacement'), _track('following')];
    h.controller.play(queue.first, queue: queue);
    await pumpEventQueue();
    h.binding.complete();
    await pumpEventQueue();
    expect(h.state.track?.id, 'replacement');
    expect(h.players[1].plays, 0);
    replacement.complete('https://example.com/replacement');
    await pumpEventQueue();
    h.players[0].positions.add(const Duration(milliseconds: 99950));
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(h.state.track?.id, 'following');
    expect(h.players[1].isPlaying, isTrue);
    expect(h.players[1].urls.last, 'https://example.com/following');
  });

  for (final fail in [false, true]) {
    test('new play supersedes pending binding (failure: $fail)', () async {
      final h = _Harness()..failBinding = fail;
      await h.startSwap();
      h.controller.play(_track('replacement'));
      await pumpEventQueue();
      h.binding.complete();
      await pumpEventQueue();
      expect(h.state.track?.id, 'replacement');
      expect(h.players[0].urls.last, 'https://example.com/replacement');
      expect(h.players[0].isPlaying, isTrue);
      expect(h.players[1].isPlaying, isFalse);
      expect(h.players[1].urls, ['https://example.com/next']);
      expect(h.routedPlayer, same(h.players[0]));
      h.controller.previous();
      expect(h.state.track?.id, 'replacement');
    });
  }
}
