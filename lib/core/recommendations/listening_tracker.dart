import 'dart:math' as math;

import 'listening_event.dart';
import 'models.dart' show WaveSource;

/// Counts observed advancing audio against monotonic elapsed time, never seeks.
/// Long sampling gaps are discarded rather than guessed as audible playback.
class ListeningTracker {
  ListeningTracker({
    required this.onEvent,
    int Function()? monotonicMs,
    DateTime Function()? timestamp,
  }) : _now = monotonicMs ?? _stopwatchClock(),
       _timestamp = timestamp ?? DateTime.now;

  final void Function(ListeningEvent event) onEvent;
  final int Function() _now;
  final DateTime Function() _timestamp;
  String? _identity;
  _Session? _session;

  static int Function() _stopwatchClock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsedMilliseconds;
  }

  /// Null identity suspends attribution during restore, lookup or account change.
  void setIdentity(String? identity) {
    if (identity != null && !validListeningIdentity(identity)) identity = null;
    if (identity == _identity) return;
    final previous = _session;
    finish(ListeningTransitionCause.accountChange);
    _identity = identity;
    if (previous != null) {
      start(
        trackId: previous.trackId,
        durationMs: previous.durationMs,
        positionMs: previous.positionMs,
        source: previous.source,
        obscure: previous.obscure,
      );
      setPlaying(previous.playing);
    }
  }

  void start({
    required String trackId,
    required int durationMs,
    int positionMs = 0,
    WaveSource? source,
    bool obscure = false,
  }) {
    finish(ListeningTransitionCause.directSelection);
    _session = _Session(
      trackId,
      math.max(0, durationMs),
      _identity,
      _now(),
      _timestamp().toUtc(),
      math.max(0, positionMs),
      source,
      obscure,
    );
  }

  void setPlaying(bool playing) {
    final session = _session;
    if (session == null) return;
    session.playing = playing;
    session.sampledAt = _now();
  }

  void sample({required int positionMs, required bool playing}) {
    final session = _session;
    if (session == null) return;
    final now = _now();
    final elapsed = now - session.sampledAt;
    final advance = positionMs - session.positionMs;
    if (session.playing &&
        playing &&
        elapsed > 0 &&
        elapsed <= 2000 &&
        advance > 0 &&
        advance <= elapsed + 250) {
      session.heardMs += math.min(advance, elapsed);
    }
    session.positionMs = math.max(0, positionMs);
    session.sampledAt = now;
    session.playing = playing;
  }

  /// Reset the observation baseline before asking the engine to seek.
  void seek(int positionMs) {
    final session = _session;
    if (session == null) return;
    session.seekCount++;
    session.positionMs = math.max(0, positionMs);
    session.sampledAt = _now();
  }

  /// Finish exactly once. Unknown attribution is deliberately never emitted.
  void finish(ListeningTransitionCause cause) {
    final session = _session;
    _session = null;
    if (session == null || session.identity == null) return;
    final event = ListeningEvent(
      sessionId: session.id,
      identity: session.identity!,
      trackId: session.trackId,
      durationMs: session.durationMs,
      heardMs: session.heardMs,
      finalPositionMs: session.positionMs,
      seekCount: session.seekCount,
      startedAt: session.startedAt,
      endedAt: _timestamp().toUtc(),
      cause: cause,
      source: session.source,
      obscure: session.obscure,
    );
    if (event.isValid) onEvent(event);
  }
}

class _Session {
  _Session(
    this.trackId,
    this.durationMs,
    this.identity,
    this.sampledAt,
    this.startedAt,
    this.positionMs,
    this.source,
    this.obscure,
  );
  static final _random = math.Random.secure();
  final String id = List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final String trackId;
  final int durationMs;
  final String? identity;
  final WaveSource? source;
  final bool obscure;
  final DateTime startedAt;
  int sampledAt;
  int positionMs;
  int heardMs = 0;
  int seekCount = 0;
  bool playing = false;
}
