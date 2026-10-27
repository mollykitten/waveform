import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models.dart';

/// Which source supplied each track the active wave queued. The wave writes
/// it before queueing; the player reads it to stamp listening facts, so
/// tracks played outside the wave carry no source.
class WaveSources extends Notifier<Map<String, WaveSource>> {
  @override
  Map<String, WaveSource> build() => const {};

  void add(Map<String, WaveSource> sources) =>
      state = Map.unmodifiable({...state, ...sources});

  void clear() {
    if (state.isNotEmpty) state = const {};
  }
}

final waveSourcesProvider =
    NotifierProvider<WaveSources, Map<String, WaveSource>>(WaveSources.new);
