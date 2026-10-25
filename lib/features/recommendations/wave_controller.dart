import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/soundcloud_auth.dart';
import '../../core/recommendations/ai_client.dart';
import '../../core/recommendations/ai_config.dart';
import '../../core/recommendations/providers.dart';
import '../player/player_controller.dart';

class WaveState {
  const WaveState({this.active = false, this.discovering = false});
  final bool active;
  final bool discovering;
}

/// Owns an explicitly started wave beyond the lifetime of its screen.
/// Only playback transitions request another batch; failures never retry.
class WaveController extends Notifier<WaveState> {
  final _ids = <String>{};
  int _epoch = 0;
  bool _disposed = false;
  bool _mutatingQueue = false;
  String _mood = '';
  String? _lastRefillTrack;
  int? _startingQueueVersion;

  @override
  WaveState build() {
    ref.listen(
      aiSettingsProvider.select((s) => s.revision),
      (_, _) => cancel(),
    );
    ref.listen(authControllerProvider, (_, _) => cancel());
    ref.listen(playerControllerProvider, (previous, next) {
      if (_mutatingQueue) return;
      if (_startingQueueVersion != null &&
          next.queueVersion != _startingQueueVersion) {
        cancel();
        return;
      }
      if (!state.active) return;
      if (!_ownsQueue(next)) {
        cancel();
        return;
      }
      if (next.isPlaying &&
          !state.discovering &&
          next.track?.id != _lastRefillTrack &&
          ref.read(playerControllerProvider.notifier).upcomingTracks.length <=
              2) {
        _lastRefillTrack = next.track?.id;
        // Avoid re-entering the player while it publishes a transition.
        scheduleMicrotask(() {
          if (!_disposed && state.active && !state.discovering) {
            unawaited(_generate(append: true));
          }
        });
      }
    });
    ref.onDispose(() {
      _disposed = true;
      _epoch++;
    });
    return const WaveState();
  }

  bool _ownsQueue(PlayerState player) =>
      _ids.contains(player.track?.id) &&
      ref
          .read(playerControllerProvider.notifier)
          .upcomingTracks
          .every((track) => _ids.contains(track.id));

  Future<void> start(String mood) async {
    if (state.discovering || ref.read(recommendationsProvider).busy) return;
    _mood = mood;
    _ids.clear();
    _startingQueueVersion = ref.read(playerControllerProvider).queueVersion;
    await _generate(append: false);
  }

  Future<void> _generate({required bool append}) async {
    final settings = ref.read(aiSettingsProvider);
    if (!settings.ready ||
        !settings.config.isValid ||
        !settings.config.listeningConsent ||
        (settings.config.backend == AiBackend.chatGpt &&
            !settings.chatGptConnected)) {
      cancel();
      return;
    }
    final epoch = ++_epoch;
    final revision = settings.revision;
    state = WaveState(active: append, discovering: true);
    final authed = ref.read(authControllerProvider).isAuthenticated;
    final current = ref.read(playerControllerProvider).track;
    final mood = _mood.trim().isEmpty && !authed && current == null
        ? 'discover music on SoundCloud'
        : _mood;
    await ref
        .read(recommendationsProvider.notifier)
        .generate(
          consent: AiConsent(
            destination: settings.config.destination,
            listening: authed,
          ),
          mood: mood,
          useListening: authed,
          currentTrack: current,
          append: append,
        );
    if (_disposed || epoch != _epoch) return;
    if (revision != ref.read(aiSettingsProvider).revision ||
        (append && !_ownsQueue(ref.read(playerControllerProvider))) ||
        (!append &&
            ref.read(playerControllerProvider).queueVersion !=
                _startingQueueVersion)) {
      cancel();
      return;
    }
    final result = ref.read(recommendationsProvider);
    final fresh = result.items
        .where((item) => !_ids.contains(item.track.id))
        .toList();
    if (result.busy || result.error != null || fresh.isEmpty) {
      _startingQueueVersion = null;
      state = const WaveState();
      return;
    }
    _ids.addAll(fresh.map((item) => item.track.id));
    final player = ref.read(playerControllerProvider.notifier);
    _startingQueueVersion = null;
    _mutatingQueue = true;
    try {
      if (append) {
        for (final item in fresh) {
          player.addToQueue(item.track);
        }
      } else {
        _lastRefillTrack = fresh.first.track.id;
        player.play(
          fresh.first.track,
          queue: fresh.map((item) => item.track).toList(),
        );
      }
    } finally {
      _mutatingQueue = false;
    }
    state = const WaveState(active: true);
    if (!append && player.upcomingTracks.length <= 2) {
      scheduleMicrotask(() {
        if (!_disposed &&
            epoch == _epoch &&
            state.active &&
            !state.discovering) {
          unawaited(_generate(append: true));
        }
      });
    }
  }

  void cancel() {
    _epoch++;
    _startingQueueVersion = null;
    if (state.discovering) ref.read(recommendationsProvider.notifier).cancel();
    state = const WaveState();
  }
}

final waveControllerProvider = NotifierProvider<WaveController, WaveState>(
  WaveController.new,
);
