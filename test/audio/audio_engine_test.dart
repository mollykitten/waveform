import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:waveform_app/core/audio/audio_engine.dart';

/// Подделка just_audio [AudioPlayer], моделирующая ключевое поведение, из-за
/// которого жил баг «тихий входящий трек при crossfade»: `play()` возвращает
/// future, которая НЕ завершается, пока воспроизведение не остановят (ровно
/// как настоящий just_audio во время игры). Если движок `await`'ит этот
/// `play()` до рампы громкости — рампа не выполнится и тест зависнет.
class _FakePlayer implements AudioPlayer {
  final _state = StreamController<ProcessingState>.broadcast();
  final _pos = StreamController<Duration>.broadcast();
  final _buf = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();

  /// Future от play() — намеренно никогда не завершается.
  final Completer<void> playCompleter = Completer<void>();
  final List<double> volumes = [];
  final List<String> urls = [];
  final List<String> events = [];
  void Function(double)? onSetVolume;
  Future<void> Function()? onPause;
  Future<Duration?> Function(String)? onSetUrl;
  bool played = false;
  int stopCount = 0;

  double? get lastVolume => volumes.isEmpty ? null : volumes.last;

  @override
  Stream<ProcessingState> get processingStateStream => _state.stream;
  @override
  Stream<Duration> get positionStream => _pos.stream;
  @override
  Stream<Duration> get bufferedPositionStream => _buf.stream;
  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  dynamic noSuchMethod(Invocation inv) {
    switch (inv.memberName) {
      case #setVolume:
        final volume = inv.positionalArguments.first as double;
        volumes.add(volume);
        events.add('volume:$volume');
        onSetVolume?.call(volume);
        return Future<void>.value();
      case #play:
        played = true;
        events.add('play');
        return playCompleter.future; // никогда не завершается
      case #setUrl:
        final url = inv.positionalArguments.first as String;
        final pending = onSetUrl?.call(url);
        if (pending != null) {
          return pending.then((duration) {
            urls.add(url);
            return duration;
          });
        }
        urls.add(url);
        return Future<Duration?>.value(const Duration(seconds: 1));
      case #stop:
        stopCount++;
        return Future<void>.value();
      case #pause:
        events.add('pause');
        return onPause?.call() ?? Future<void>.value();
      case #seek:
      case #dispose:
        return Future<void>.value();
      default:
        return null;
    }
  }
}

class _RoutingQueue {
  Future<void> _tail = Future<void>.value();

  Future<void> run(Future<void> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

void main() {
  final talker = TalkerFlutter.init();

  test('crossfade swap ramps incoming player to full volume and returns '
      '(does not await the blocking play() future)', () async {
    final players = <_FakePlayer>[];
    final engine = JustAudioEngine(
      talker,
      createPlayer: () {
        final p = _FakePlayer();
        players.add(p);
        return p;
      },
    );

    await engine.preloadNext('next-url');
    expect(engine.hasPreload, isTrue);

    // До фикса здесь висел `await to.play()` (future preload'ного плеера не
    // завершается) → swapToNext не возвращается → timeout = провал теста.
    await engine
        .swapToNext(crossfade: const Duration(milliseconds: 100))
        .timeout(const Duration(seconds: 2));

    final incoming = players[1]; // _b стал активным `to`
    expect(incoming.played, isTrue);
    // Рампа дошла до конца → входящий выходит на пользовательскую громкость
    // (по умолчанию 1.0), а НЕ застывает у нуля.
    expect(incoming.lastVolume, closeTo(1.0, 1e-9));

    engine.dispose();
  });

  test(
    'gapless swap returns promptly and brings incoming to full volume',
    () async {
      final players = <_FakePlayer>[];
      final engine = JustAudioEngine(
        talker,
        createPlayer: () {
          final p = _FakePlayer();
          players.add(p);
          return p;
        },
      );

      await engine.preloadNext('next-url');
      await engine.swapToNext().timeout(const Duration(seconds: 2));

      expect(players[1].played, isTrue);
      expect(players[1].lastVolume, closeTo(1.0, 1e-9));

      engine.dispose();
    },
  );

  test('load() does not block on play()', () async {
    final engine = JustAudioEngine(talker, createPlayer: _FakePlayer.new);
    await engine.load('url').timeout(const Duration(seconds: 2));
    engine.dispose();
  });

  test('pause still installs a pending source without autoplay', () async {
    final players = <_FakePlayer>[];
    final engine = JustAudioEngine(
      talker,
      createPlayer: () {
        final player = _FakePlayer();
        players.add(player);
        return player;
      },
    );
    addTearDown(engine.dispose);
    await engine.load('first');
    final started = Completer<void>();
    final cleanup = Completer<void>();
    players[1].onPause = () {
      if (started.isCompleted) return Future<void>.value();
      started.complete();
      return cleanup.future;
    };
    final load = engine.load('next');
    await started.future;
    await engine.pause();
    final plays = players[0].events.where((event) => event == 'play').length;
    cleanup.complete();
    await load;
    expect(players[0].urls.last, 'next');
    expect(players[0].events.where((event) => event == 'play').length, plays);
    await engine.resume();
    expect(players[0].events.last, 'play');
  });

  test(
    'resume waits for a pending load and a newer pause keeps it silent',
    () async {
      final players = <_FakePlayer>[];
      final engine = JustAudioEngine(
        talker,
        createPlayer: () {
          final player = _FakePlayer();
          players.add(player);
          return player;
        },
      );
      addTearDown(engine.dispose);
      await engine.load('first');
      final started = Completer<void>();
      final cleanup = Completer<void>();
      players[1].onPause = () {
        if (started.isCompleted) return Future<void>.value();
        started.complete();
        return cleanup.future;
      };
      final load = engine.load('next');
      await started.future;
      await engine.pause();
      final plays = players[0].events.where((event) => event == 'play').length;
      final resume = engine.resume();
      await pumpEventQueue();
      expect(players[0].events.where((event) => event == 'play').length, plays);
      await engine.pause();
      cleanup.complete();
      await load;
      await resume;
      expect(players[0].urls.last, 'next');
      expect(players[0].events.where((event) => event == 'play').length, plays);
      await engine.resume();
      expect(players[0].events.last, 'play');
    },
  );

  for (final cancellation in ['load', 'stop', 'dispose']) {
    test(
      'pending resume settles when $cancellation supersedes the source',
      () async {
        final players = <_FakePlayer>[];
        final engine = JustAudioEngine(
          talker,
          createPlayer: () {
            final player = _FakePlayer();
            players.add(player);
            return player;
          },
        );
        addTearDown(engine.dispose);
        await engine.load('first');
        final started = Completer<void>();
        final cleanup = Completer<void>();
        players[1].onPause = () {
          if (started.isCompleted) return Future<void>.value();
          started.complete();
          return cleanup.future;
        };
        final stale = engine.load('stale');
        await started.future;
        final resume = engine.resume();
        switch (cancellation) {
          case 'load':
            await engine.load('latest');
          case 'stop':
            await engine.stop();
          case 'dispose':
            engine.dispose();
        }
        final plays = players[0].events
            .where((event) => event == 'play')
            .length;
        try {
          await resume.timeout(const Duration(milliseconds: 250));
        } finally {
          cleanup.complete();
          await stale;
        }
        expect(
          players[0].urls,
          cancellation == 'load' ? ['first', 'latest'] : ['first'],
        );
        expect(
          players[0].events.where((event) => event == 'play').length,
          plays,
        );
      },
    );
  }

  test('a superseded load cannot release the newer load resume gate', () async {
    final players = <_FakePlayer>[];
    final engine = JustAudioEngine(
      talker,
      createPlayer: () {
        final player = _FakePlayer();
        players.add(player);
        return player;
      },
    );
    addTearDown(engine.dispose);
    await engine.load('first');
    final cleanups = [Completer<void>(), Completer<void>()];
    var pauses = 0;
    players[1].onPause = () => cleanups[pauses++].future;
    final stale = engine.load('stale');
    final latest = engine.load('latest');
    final plays = players[0].events.where((event) => event == 'play').length;
    cleanups[0].complete();
    await stale;
    var resumed = false;
    final resume = engine.resume().then((_) => resumed = true);
    await pumpEventQueue();
    expect(resumed, isFalse);
    expect(players[0].events.where((event) => event == 'play').length, plays);
    cleanups[1].complete();
    await latest;
    await resume;
    expect(players[0].urls, ['first', 'latest']);
  });

  test(
    'failed load settles queued resume without replaying the old source',
    () async {
      final players = <_FakePlayer>[];
      final engine = JustAudioEngine(
        talker,
        createPlayer: () {
          final player = _FakePlayer();
          players.add(player);
          return player;
        },
      );
      addTearDown(engine.dispose);
      await engine.load('first');
      final setUrl = Completer<Duration?>();
      players[0].onSetUrl = (_) => setUrl.future;
      final failed = engine.load('failed');
      final failure = expectLater(failed, throwsStateError);
      await pumpEventQueue();
      final plays = players[0].events.where((event) => event == 'play').length;
      final resume = engine.resume();
      setUrl.completeError(StateError('setUrl failed'));
      await failure;
      await resume.timeout(const Duration(milliseconds: 250));
      expect(players[0].urls, ['first']);
      expect(players[0].events.where((event) => event == 'play').length, plays);
      players[0].onSetUrl = null;
      await engine.load('latest');
      expect(players[0].urls.last, 'latest');
    },
  );

  test(
    'route preparation covers both players and binding follows setUrl',
    () async {
      final players = <_FakePlayer>[];
      final prepared = <AudioPlayer>[];
      final bound = <AudioPlayer>[];
      final engine = JustAudioEngine(
        talker,
        createPlayer: () {
          final player = _FakePlayer();
          players.add(player);
          return player;
        },
        preparePlayer: (player) async => prepared.add(player),
        bindAudioOutput: (player) async {
          expect((player as _FakePlayer).urls, isNotEmpty);
          bound.add(player);
        },
      );
      addTearDown(engine.dispose);

      await engine.load('first');
      await engine.preloadNext('next');
      expect(prepared, [players[0], players[1]]);
      expect(bound, [players[0]]);
      await engine.swapToNext();
      expect(bound, [players[0], players[1]]);
    },
  );

  test(
    'AirPlay loads consecutive tracks on the same player without preload',
    () async {
      final players = <_FakePlayer>[];
      final engine = JustAudioEngine(
        talker,
        preservePlayer: () => true,
        createPlayer: () {
          final player = _FakePlayer();
          players.add(player);
          return player;
        },
      );
      addTearDown(engine.dispose);

      await engine.load('first');
      await engine.preloadNext('next');
      expect(engine.hasPreload, isFalse);
      await engine.load('next');
      await engine.stop();
      await engine.load('third');

      expect(players[0].urls, ['first', 'next', 'third']);
      expect(players[0].stopCount, 0);
      expect(players[1].urls, isEmpty);
      expect(players[1].played, isFalse);
    },
  );

  test(
    'AirPlay selected after preload keeps the routed player on swap',
    () async {
      var preservePlayer = false;
      final players = <_FakePlayer>[];
      final bound = <AudioPlayer>[];
      final engine = JustAudioEngine(
        talker,
        preservePlayer: () => preservePlayer,
        bindAudioOutput: (player) async => bound.add(player),
        createPlayer: () {
          final player = _FakePlayer();
          players.add(player);
          return player;
        },
      );
      addTearDown(engine.dispose);
      await engine.load('first');
      await engine.preloadNext('next');
      expect(engine.hasPreload, isTrue);

      preservePlayer = true;
      expect(engine.hasPreload, isFalse);
      await engine.swapToNext(crossfade: const Duration(seconds: 1));

      expect(players[0].urls, ['first', 'next']);
      expect(players[1].played, isFalse);
      expect(bound, [players[0], players[0]]);
    },
  );

  test('swap binds output before making the incoming player active', () async {
    final players = <_FakePlayer>[];
    final binding = Completer<void>();
    final started = Completer<void>();
    final engine = JustAudioEngine(
      talker,
      bindAudioOutput: (_) {
        started.complete();
        return binding.future;
      },
      createPlayer: () {
        final player = _FakePlayer();
        players.add(player);
        return player;
      },
    );
    addTearDown(engine.dispose);
    await engine.preloadNext('next');
    final swap = engine.swapToNext();
    await started.future;

    await engine.setVolume(0.4);
    expect(players[0].lastVolume, 0.4);
    expect(players[1].played, isFalse);
    binding.complete();
    await swap;
    expect(players[1].played, isTrue);
    expect(players[1].lastVolume, 0.4);
  });

  test('new load supersedes an output binding before swap completes', () async {
    final players = <_FakePlayer>[];
    final routing = _RoutingQueue();
    AudioPlayer? nativePlayer;
    final binding = Completer<void>();
    final started = Completer<void>();
    final engine = JustAudioEngine(
      talker,
      routingTransaction: routing.run,
      bindAudioOutput: (player) async {
        nativePlayer = player;
        if (identical(player, players[1])) {
          started.complete();
          await binding.future;
        }
      },
      createPlayer: () {
        final player = _FakePlayer();
        players.add(player);
        return player;
      },
    );
    addTearDown(engine.dispose);
    await engine.preloadNext('next');
    final swap = engine.swapToNext();
    await started.future;
    final replacement = engine.load('replacement');
    binding.complete();
    await Future.wait([swap, replacement]);

    await engine.setVolume(0.7);
    expect(players[0].urls, ['replacement']);
    expect(players[0].played, isTrue);
    expect(players[0].lastVolume, 0.7);
    expect(players[1].played, isFalse);
    expect(nativePlayer, same(players[0]));
  });

  test(
    'AirPlay selected while binding prevents a pending player swap',
    () async {
      var preservePlayer = false;
      final players = <_FakePlayer>[];
      final binding = Completer<void>();
      final started = Completer<void>();
      final engine = JustAudioEngine(
        talker,
        preservePlayer: () => preservePlayer,
        bindAudioOutput: (player) async {
          if (identical(player, players[1])) {
            started.complete();
            await binding.future;
          }
        },
        createPlayer: () {
          final player = _FakePlayer();
          players.add(player);
          return player;
        },
      );
      addTearDown(engine.dispose);
      await engine.load('first');
      await engine.preloadNext('next');
      final swap = engine.swapToNext();
      await started.future;
      preservePlayer = true;
      binding.complete();
      await swap;

      expect(players[0].urls, ['first', 'next']);
      expect(players[1].played, isFalse);
    },
  );

  test(
    'disposed engine never starts a player after delayed output binding',
    () async {
      final players = <_FakePlayer>[];
      final binding = Completer<void>();
      final started = Completer<void>();
      final engine = JustAudioEngine(
        talker,
        bindAudioOutput: (_) {
          started.complete();
          return binding.future;
        },
        createPlayer: () {
          final player = _FakePlayer();
          players.add(player);
          return player;
        },
      );
      final load = engine.load('first');
      await started.future;
      engine.dispose();
      binding.complete();
      await load;
      expect(players[0].played, isFalse);
    },
  );

  test(
    'AirPlay picker observes retained player after pending native binding',
    () async {
      var preservePlayer = false;
      final players = <_FakePlayer>[];
      AudioPlayer? nativePlayer;
      AudioPlayer? pickerPlayer;
      final routing = _RoutingQueue();
      final binding = Completer<void>();
      final started = Completer<void>();
      final engine = JustAudioEngine(
        talker,
        preservePlayer: () => preservePlayer,
        routingTransaction: routing.run,
        bindAudioOutput: (player) async {
          nativePlayer = player;
          if (identical(player, players[1])) {
            started.complete();
            await binding.future;
          }
        },
        createPlayer: () {
          final player = _FakePlayer();
          players.add(player);
          return player;
        },
      );
      addTearDown(engine.dispose);
      await engine.load('first');
      await engine.preloadNext('next');
      final swap = engine.swapToNext();
      await started.future;
      expect(nativePlayer, same(players[1]));

      preservePlayer = true;
      final picker = routing.run(() async => pickerPlayer = nativePlayer);
      binding.complete();
      await Future.wait([swap, picker]);

      expect(pickerPlayer, same(players[0]));
      expect(nativePlayer, same(players[0]));
      expect(players[0].urls, ['first', 'next']);
      expect(players[1].played, isFalse);
    },
  );

  test(
    'output binding failure prevents playback on an unbound player',
    () async {
      final players = <_FakePlayer>[];
      AudioPlayer? nativePlayer;
      final engine = JustAudioEngine(
        talker,
        bindAudioOutput: (player) async {
          nativePlayer = player;
          if (identical(player, players[1])) throw StateError('route failed');
        },
        createPlayer: () {
          final player = _FakePlayer();
          players.add(player);
          return player;
        },
      );
      addTearDown(engine.dispose);
      await engine.load('first');
      await engine.preloadNext('next');
      await expectLater(engine.swapToNext(), throwsStateError);
      expect(nativePlayer, same(players[0]));
      expect(players[1].played, isFalse);
      await engine.setVolume(0.6);
      expect(players[0].lastVolume, 0.6);
    },
  );

  test(
    'AirPlay selected during crossfade finishes ramp and silences old player',
    () async {
      var preservePlayer = false;
      final players = <_FakePlayer>[];
      final engine = JustAudioEngine(
        talker,
        preservePlayer: () => preservePlayer,
        createPlayer: () {
          final player = _FakePlayer();
          players.add(player);
          return player;
        },
      );
      addTearDown(engine.dispose);
      await engine.preloadNext('next');
      players[0].onSetVolume = (_) => preservePlayer = true;

      await engine
          .swapToNext(crossfade: const Duration(seconds: 6))
          .timeout(const Duration(seconds: 1));

      expect(players[0].volumes, hasLength(1));
      expect(players[0].events.last, 'pause');
      expect(players[1].lastVolume, 1);
      expect(engine.hasPreload, isFalse);
    },
  );
}
