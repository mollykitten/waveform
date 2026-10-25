import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:talker_flutter/talker_flutter.dart';

import '../log/talker.dart';
import 'audio_output.dart';

/// A swap failed after selecting the incoming source. Its metadata must be
/// retained: the outgoing source may already have been replaced for AirPlay.
class AudioSwapCommittedException implements Exception {
  const AudioSwapCommittedException(this.cause);

  final Object cause;

  @override
  String toString() => 'audio swap failed after source commit: $cause';
}

/// Абстракция звукового движка. PlayerController зависит только от неё —
/// не от just_audio напрямую, поэтому тесты подменяют движок заглушкой.
abstract interface class AudioEngine {
  /// Текущая позиция воспроизведения.
  Stream<Duration> get positionStream;

  /// Граница того, насколько вперёд буферизировано (для buffered-полоски
  /// на waveform). Может «дёргаться» назад при seek.
  Stream<Duration> get bufferedPositionStream;

  /// Реальный признак «играет» от движка (учитывает буферизацию/паузы ОС).
  Stream<bool> get playingStream;

  /// Эмитит, когда трек доиграл до конца.
  Stream<void> get completedStream;

  /// Загрузить источник по URL и начать воспроизведение.
  Future<void> load(String url);
  Future<void> pause();
  Future<void> resume();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> stop();

  /// Подготовить следующий источник в «теневом» движке (для gapless / crossfade).
  /// На JustAudioEngine — `setUrl` на inactive `AudioPlayer`. Без play.
  /// Если null — отменяем preload.
  Future<void> preloadNext(String? url);

  /// Перейти на preload'ный источник. При [crossfade]>0 — плавный fade-in/out
  /// (оба движка играют параллельно во время рампы). При zero — мгновенный.
  /// Если preload не подготовлен — no-op.
  Future<void> swapToNext({Duration crossfade = Duration.zero});

  /// Готов ли preload (можно swap'аться). Полезно контроллеру решить — swap
  /// или fallback к обычной `load(next)`.
  bool get hasPreload;

  void dispose();
}

/// Реализация на just_audio с **двумя** `AudioPlayer`'ами (`_a`, `_b`),
/// чтобы поддерживать gapless и crossfade: один играет, второй preload'ит
/// следующий трек. `_active` указывает на текущий.
///
/// Стримы (`position/buffered/playing/completed`) пробрасываются через
/// собственные broadcast-контроллеры — downstream-слушатель (PlayerController)
/// не пересоздаёт подписки при swap'е.
class JustAudioEngine implements AudioEngine {
  JustAudioEngine(
    this._log, {
    AudioPlayer Function()? createPlayer,
    Future<void> Function(AudioPlayer)? preparePlayer,
    Future<void> Function(AudioPlayer)? bindAudioOutput,
    Future<void> Function(Future<void> Function())? routingTransaction,
    bool Function()? preservePlayer,
  }) : _preparePlayer = preparePlayer,
       _bindAudioOutput = bindAudioOutput,
       _routingTransaction = routingTransaction,
       _preservePlayer = preservePlayer,
       _a = (createPlayer ?? AudioPlayer.new)(),
       _b = (createPlayer ?? AudioPlayer.new)() {
    _bindActive();
  }

  /// Talker для диагностики crossfade (виден в /logs).
  final Talker _log;
  final Future<void> Function(AudioPlayer)? _preparePlayer;
  final Future<void> Function(AudioPlayer)? _bindAudioOutput;
  final Future<void> Function(Future<void> Function())? _routingTransaction;
  final bool Function()? _preservePlayer;
  bool get _preservingPlayer => _preservePlayer?.call() ?? false;
  bool _disposed = false;

  final AudioPlayer _a;
  final AudioPlayer _b;
  late AudioPlayer _active = _a;
  AudioPlayer get _inactive => identical(_active, _a) ? _b : _a;

  // Целевая громкость пользователя (по этой возвращаемся после fade-in).
  double _userVolume = 1.0;

  bool _preloadReady = false;
  String? _preloadUrl;
  int _preloadGen = 0;

  /// Поколение «переходных» операций (load/swap). Каждая новая операция
  /// инкрементит счётчик; долгая crossfade-рампа на каждой итерации сверяет
  /// своё поколение и прекращается, если её перебила более новая операция —
  /// иначе `_active` мог 6с указывать на старый (паузный) плеер, и громкость/
  /// прогресс/play-pause рулили «не тем» плеером (главный баг десинка).
  int _swapGen = 0;

  // Pause cancels the ramp, but must still commit an incoming source whose
  // metadata the controller has already selected. Load/stop cancel both.
  int _sourceGen = 0;
  bool _wantsPlayback = false;
  Future<void>? _pendingSwap;

  bool _isSourceCurrent(int generation) =>
      !_disposed && generation == _sourceGen;

  bool _isCurrent(int generation) => !_disposed && generation == _swapGen;

  Future<void> _prepareOutput(AudioPlayer player) async {
    await _preparePlayer?.call(player);
  }

  Future<void> _withRoutingTransaction(Future<void> Function() operation) =>
      _routingTransaction?.call(operation) ?? operation();

  Future<void> _restoreOutput() async {
    if (_disposed) return;
    try {
      await _bindAudioOutput?.call(_active);
    } catch (error, stack) {
      _log.error('[engine] output binding recovery failed', error, stack);
    }
  }

  Future<void> _bindOutput(AudioPlayer player) async {
    try {
      await _bindAudioOutput?.call(player);
    } catch (error, stack) {
      _log.error('[engine] output binding failed', error, stack);
      await _restoreOutput();
      rethrow;
    }
  }

  // Прокси-стримы.
  final _positionCtrl = StreamController<Duration>.broadcast();
  final _bufferedCtrl = StreamController<Duration>.broadcast();
  final _playingCtrl = StreamController<bool>.broadcast();
  final _completedCtrl = StreamController<void>.broadcast();

  StreamSubscription<Duration>? _posSub, _bufSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<ProcessingState>? _stateSub;

  /// Перепривязать подписки к новому активному плееру.
  void _bindActive() {
    _posSub?.cancel();
    _bufSub?.cancel();
    _playingSub?.cancel();
    _stateSub?.cancel();
    _posSub = _active.positionStream.listen(_positionCtrl.add);
    _bufSub = _active.bufferedPositionStream.listen(_bufferedCtrl.add);
    _playingSub = _active.playingStream.listen(_playingCtrl.add);
    _stateSub = _active.processingStateStream.listen((s) {
      if (s == ProcessingState.completed) _completedCtrl.add(null);
    });
  }

  @override
  Stream<Duration> get positionStream => _positionCtrl.stream;

  @override
  Stream<Duration> get bufferedPositionStream => _bufferedCtrl.stream;

  @override
  Stream<bool> get playingStream => _playingCtrl.stream;

  @override
  Stream<void> get completedStream => _completedCtrl.stream;

  /// Запускает воспроизведение, НЕ ожидая `play()`-future. У just_audio она
  /// завершается лишь когда воспроизведение ОСТАНАВЛИВАЕТСЯ (pause/stop/
  /// completed) — `await player.play()` заблокировал бы всё, что идёт следом:
  /// рампу crossfade'а, `from.pause()`, продолжение `_load`. Гард
  /// `if (playing) return` в just_audio спасал `load()` (там плеер обычно уже
  /// играет), но НЕ swap: preload'ный плеер ещё не играет, и await висел до
  /// конца трека → входящий оставался на нулевой громкости (тихий трек).
  void _play(AudioPlayer p) {
    unawaited(
      p.play().catchError((Object e, StackTrace st) {
        _log.error('[engine] play() failed', e, st);
      }),
    );
  }

  @override
  Future<void> load(String url) => _load(url);

  Future<void> _load(
    String url, {
    bool autoplay = true,
    void Function()? onSourceLoaded,
  }) async {
    if (_disposed) return;
    final source = ++_sourceGen;
    if (onSourceLoaded == null) _pendingSwap = null;
    _wantsPlayback = autoplay;
    // Новая авторитетная загрузка отменяет любую идущую crossfade-рампу и
    // preload (он был под старый «следующий»).
    final gen = ++_swapGen;
    // A retained-player swap still has to select its incoming source after
    // pause. Ordinary loads retain their existing cancellation behavior.
    bool isCurrentLoad() =>
        onSourceLoaded == null ? _isCurrent(gen) : _isSourceCurrent(source);
    ++_preloadGen;
    _log.debug('[engine] load → gen=$_swapGen');
    _preloadReady = false;
    _preloadUrl = null;
    final player = _active;
    final inactive = _inactive;
    // Глушим теневой плеер — чтобы не остался «призрачный» звук от
    // прерванного crossfade'а.
    try {
      await inactive.pause();
      if (!isCurrentLoad()) return;
      await inactive.setVolume(0);
    } catch (error, stack) {
      _log.warning('[engine] inactive player cleanup failed', error, stack);
    }
    if (!isCurrentLoad()) return;
    await player.setUrl(url);
    if (!isCurrentLoad()) return;
    onSourceLoaded?.call();
    await _prepareOutput(player);
    if (!isCurrentLoad()) return;
    await _withRoutingTransaction(() async {
      if (!isCurrentLoad()) return;
      await _bindOutput(player);
      if (!isCurrentLoad()) await _restoreOutput();
    });
    if (!isCurrentLoad()) return;
    await player.setVolume(_userVolume);
    if (!isCurrentLoad()) return;
    // Явный seek(0): setUrl обычно сбрасывает позицию, но защищаемся от
    // унаследованной позиции у переиспользуемого AudioPlayer'а.
    await player.seek(Duration.zero);
    if (isCurrentLoad() && _wantsPlayback) _play(player);
  }

  @override
  Future<void> pause() async {
    // Отменяем идущую crossfade-рампу — иначе она доиграет старый плеер и
    // докрутит громкости поверх нашей паузы.
    final gen = ++_swapGen;
    _wantsPlayback = false;
    _log.debug('[engine] pause → gen=$_swapGen');
    // Глушим ОБА плеера: во время crossfade старый (`from`) ещё звучит, и
    // пауза только `_active` оставляла бы его играющим («поставил на паузу —
    // а играет»). Пауза второго плеера идемпотентна, когда он и так стоит.
    (Object, StackTrace)? failure;
    for (final player in [_a, _b]) {
      try {
        await player.pause();
      } catch (error, stack) {
        // Failure on one player must not leave the other playing. Keep the
        // first error for the caller, with at most one log per player.
        failure ??= (error, stack);
        _log.warning('[engine] player pause failed', error, stack);
      }
      if (!_isCurrent(gen) || _wantsPlayback) return;
    }
    if (failure != null) {
      Error.throwWithStackTrace(failure.$1, failure.$2);
    }
    // Рампа могла оставить активный на промежуточной громкости — возвращаем.
    await _active.setVolume(_userVolume);
  }

  @override
  Future<void> resume() async {
    final source = _sourceGen;
    _wantsPlayback = true;
    // Until native binding commits, _active still owns the outgoing source.
    await _pendingSwap;
    if (_isSourceCurrent(source) && _wantsPlayback) _play(_active);
  }

  @override
  Future<void> seek(Duration position) => _active.seek(position);

  @override
  Future<void> setVolume(double volume) async {
    _userVolume = volume;
    await _active.setVolume(volume);
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    ++_sourceGen;
    _pendingSwap = null;
    _wantsPlayback = false;
    final gen = ++_swapGen;
    ++_preloadGen;
    _preloadReady = false;
    _preloadUrl = null;
    final player = _active;
    await _inactive.pause();
    if (!_isCurrent(gen)) return;
    if (_preservingPlayer) {
      await player.pause();
      if (_isCurrent(gen)) await player.seek(Duration.zero);
    } else {
      await player.stop();
    }
  }

  @override
  Future<void> preloadNext(String? url) async {
    final gen = ++_preloadGen;
    _preloadReady = false;
    _preloadUrl = null;
    if (_disposed) return;
    final player = _inactive;
    if (_preservingPlayer || url == null || url.isEmpty) {
      try {
        await player.pause();
      } catch (error, stack) {
        _log.warning('[engine] preload cancellation failed', error, stack);
      }
      return;
    }
    try {
      await player.setUrl(url);
      if (_disposed || gen != _preloadGen || _preservingPlayer) return;
      await _prepareOutput(player);
      if (_disposed || gen != _preloadGen || _preservingPlayer) return;
      await player.setVolume(0);
      if (_disposed || gen != _preloadGen || _preservingPlayer) return;
      _preloadUrl = url;
      _preloadReady = true;
    } catch (error, stack) {
      if (gen == _preloadGen) _preloadReady = false;
      _log.warning('[engine] preload failed', error, stack);
    }
  }

  @override
  bool get hasPreload => !_disposed && !_preservingPlayer && _preloadReady;

  @override
  Future<void> swapToNext({Duration crossfade = Duration.zero}) async {
    final done = Completer<void>();
    _pendingSwap = done.future;
    var committed = false;
    try {
      await _swapToNext(crossfade: crossfade, onCommit: () => committed = true);
    } catch (error) {
      if (committed) throw AudioSwapCommittedException(error);
      rethrow;
    } finally {
      if (identical(_pendingSwap, done.future)) _pendingSwap = null;
      done.complete();
    }
  }

  Future<void> _swapToNext({
    required Duration crossfade,
    required void Function() onCommit,
  }) async {
    if (_disposed || !_preloadReady) {
      _log.warning('[swap] called but preload not ready — no-op');
      return;
    }
    final preloadUrl = _preloadUrl;
    if (_preservingPlayer) {
      if (preloadUrl != null) {
        await _load(preloadUrl, onSourceLoaded: onCommit);
      }
      return;
    }
    final gen = ++_swapGen;
    final source = ++_sourceGen;
    _wantsPlayback = true;
    ++_preloadGen;
    _log.debug('[swap] gen=$gen crossfade=${crossfade.inMilliseconds}ms');
    final from = _active;
    final to = _inactive;
    _preloadReady = false;
    _preloadUrl = null;

    // Picker presentation shares this transaction: it must observe either the
    // committed incoming player or the restored player retained for AirPlay.
    var keepPlayer = false;
    await _withRoutingTransaction(() async {
      if (!_isSourceCurrent(source)) return;
      await _bindOutput(to);
      if (!_isSourceCurrent(source)) {
        await _restoreOutput();
        return;
      }
      if (_preservingPlayer) {
        keepPlayer = true;
        await _bindOutput(from);
        return;
      }
      _active = to;
      onCommit();
      _bindActive();
    });
    if (!_isSourceCurrent(source)) return;
    if (keepPlayer) {
      if (preloadUrl != null) {
        await _load(
          preloadUrl,
          autoplay: _wantsPlayback,
          onSourceLoaded: onCommit,
        );
      }
      return;
    }

    if (!_isCurrent(gen)) {
      // A pause during binding keeps the incoming source selected, silently.
      // A queued resume waits for this commit before playing the new source.
      await from.pause();
      if (_isSourceCurrent(source)) await to.setVolume(_userVolume);
      return;
    }

    // Защита от унаследованной позиции у preload'ного плеера.
    await to.seek(Duration.zero);
    if (!_isCurrent(gen)) return;

    if (crossfade <= Duration.zero) {
      // Gapless: мгновенный swap.
      await to.setVolume(_userVolume);
      if (!_isCurrent(gen)) return;
      _play(to);
      await from.pause();
      return;
    }

    // Crossfade: оба играют, линейная рампа громкости. Фон (`from`) гаснет,
    // передний (`to` = новый `_active`) набирает до _userVolume.
    const stepMs = 50;
    final steps = (crossfade.inMilliseconds / stepMs).clamp(1, 10000).toInt();
    _log.debug('[crossfade] start gen=$gen steps=$steps userVol=$_userVolume');
    await to.setVolume(0);
    if (!_isCurrent(gen)) return;
    _play(to);
    for (var i = 1; i <= steps; i++) {
      if (!_isCurrent(gen)) {
        _log.warning(
          '[crossfade] ABORT mid-ramp step=$i/$steps gen=$gen now=$_swapGen '
          'toVol=${_userVolume * (i / steps)}',
        );
        return; // нас перебила новая load/swap — выходим
      }
      if (_preservingPlayer) {
        await from.pause();
        if (_isCurrent(gen)) await to.setVolume(_userVolume);
        return;
      }
      final t = i / steps;
      await from.setVolume(_userVolume * (1 - t));
      if (!_isCurrent(gen)) return;
      await to.setVolume(_userVolume * t);
      await Future<void>.delayed(const Duration(milliseconds: stepMs));
    }
    if (!_isCurrent(gen)) {
      _log.warning('[crossfade] ABORT post-loop gen=$gen now=$_swapGen');
      return;
    }
    await from.pause();
    if (!_isCurrent(gen)) return;
    await to.setVolume(_userVolume);
    _log.debug('[crossfade] done → to=userVol=$_userVolume');
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_sourceGen;
    ++_swapGen;
    ++_preloadGen;
    _posSub?.cancel();
    _bufSub?.cancel();
    _playingSub?.cancel();
    _stateSub?.cancel();
    _positionCtrl.close();
    _bufferedCtrl.close();
    _playingCtrl.close();
    _completedCtrl.close();
    _a.dispose();
    _b.dispose();
  }
}

/// Единый звуковой движок на время жизни приложения.
/// Тесты переопределяют провайдер заглушкой, чтобы не дёргать плагин.
final audioEngineProvider = Provider<AudioEngine>((ref) {
  final output = ref.read(audioOutputProvider.notifier);
  final isMacOS = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
  final engine = JustAudioEngine(
    ref.read(talkerProvider),
    routingTransaction: (operation) => output.routingTransaction(operation),
    preservePlayer: () => output.preservePlayer,
    preparePlayer: isMacOS
        ? (player) => player.setAllowsExternalPlayback(true)
        : null,
    bindAudioOutput: isMacOS
        ? (player) => player.setAsAudioOutputPlayer()
        : null,
  );
  ref.onDispose(engine.dispose);
  return engine;
});
