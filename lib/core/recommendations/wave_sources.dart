import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models.dart';

/// Which source supplied each track the active wave queued. The wave writes
/// it before queueing; the player reads it to stamp listening facts, so
/// tracks played outside the wave carry no source.
///
/// A source is only valid for the queue the wave started: [add] with
/// `startsQueue` arms the map for the very next [PlayerController.play], and
/// any other `play` (a track picked from search, a track page, a library list)
/// calls [consumeArm], finds it unarmed and clears the map before the
/// listening session begins.
class WaveSources extends Notifier<Map<String, WaveSource>> {
  bool _armed = false;

  @override
  Map<String, WaveSource> build() => const {};

  void add(Map<String, WaveSource> sources, {bool startsQueue = false}) {
    _armed = startsQueue;
    state = Map.unmodifiable({...state, ...sources});
  }

  /// Whether the wave itself is about to start playback; resets the arm.
  bool consumeArm() {
    final armed = _armed;
    _armed = false;
    return armed;
  }

  void clear() {
    _armed = false;
    if (state.isNotEmpty) state = const {};
  }
}

final waveSourcesProvider =
    NotifierProvider<WaveSources, Map<String, WaveSource>>(WaveSources.new);
