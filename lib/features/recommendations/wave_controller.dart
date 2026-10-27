import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/soundcloud_auth.dart';
import '../../core/recommendations/listening_event.dart';
import '../../core/recommendations/models.dart';
import '../../core/recommendations/providers.dart';
import '../../core/recommendations/seen_store.dart';
import '../../shared/models/track.dart';
import '../player/player_controller.dart';

/// A dislike attempt: the account and track, whether it was really stored,
/// and whether the player moved on to another track.
typedef WaveDislike = ({
  String identity,
  Track track,
  bool saved,
  bool skipped,
});

class WaveState {
  const WaveState({this.active = false, this.discovering = false});
  final bool active;
  final bool discovering;
}

/// Owns an explicitly started wave beyond the lifetime of its screen.
/// Playback transitions request another batch. Empty or transient failures
/// retry a few times with a pause, then stop with a visible message.
class WaveController extends Notifier<WaveState> {
  /// Refill when this few tracks remain queued.
  static const refillThreshold = 5;

  /// A short first batch triggers the next search right away.
  static const initialPrefetchThreshold = 2;

  /// Most tracks put into the queue by one refill.
  static const batchSize = 10;

  /// Candidates requested per search; the surplus waits in the pool.
  static const searchLimit = 20;

  /// Extra attempts after an empty or transient failure before giving up.
  static const maxRetries = 3;

  final _ids = <String>{};
  Timer? _retryTimer;
  Completer<void>? _retryWait;
  int _epoch = 0;

  /// Changes whenever a wave starts or is cancelled, unlike [_epoch], which
  /// also moves on every refill.
  int _waveId = 0;
  bool _disposed = false;
  bool _mutatingQueue = false;
  String? _lastRefillTrack;
  int? _startingQueueVersion;

  @override
  WaveState build() {
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
              refillThreshold) {
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
      _wake();
    });
    return const WaveState();
  }

  bool _ownsQueue(PlayerState player) =>
      _ids.contains(player.track?.id) &&
      ref
          .read(playerControllerProvider.notifier)
          .upcomingTracks
          .every((track) => _ids.contains(track.id));

  Future<void> start() async {
    if (state.discovering || ref.read(recommendationsProvider).busy) return;
    _waveId++;
    _ids.clear();
    _startingQueueVersion = ref.read(playerControllerProvider).queueVersion;
    await _generate(append: false);
  }

  Future<void> _generate({required bool append}) async {
    if (!ref.read(authControllerProvider).isAuthenticated) {
      cancel();
      return;
    }
    final epoch = ++_epoch;
    final trigger = ref.read(playerControllerProvider).track?.id;
    state = WaveState(active: append, discovering: true);
    WaveFailure? failure;
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      if (attempt > 0) {
        await _pause(ref.read(waveRetryDelayProvider));
        if (_disposed || epoch != _epoch) return;
      }
      var batch = append ? _pool(append: true) : const <Recommendation>[];
      if (batch.length < refillThreshold) {
        await _search(append: append);
        if (_disposed || epoch != _epoch) return;
        if (_stale(append)) {
          cancel();
          return;
        }
        final result = ref.read(recommendationsProvider);
        if (result.busy) {
          _startingQueueVersion = null;
          state = const WaveState();
          return;
        }
        failure = result.error;
        if (failure != null && !_retryable(failure)) break;
        batch = _pool(append: append);
      }
      if (batch.isNotEmpty) {
        _enqueue(batch.take(batchSize).toList(), append: append);
        _lastRefillTrack = append ? trigger : _lastRefillTrack;
        _startingQueueVersion = null;
        state = const WaveState(active: true);
        if (!append) _prefetchIfLow(epoch);
        return;
      }
    }
    // Give up visibly: an error already on the result is shown by the
    // screen; an empty answer needs an explicit message.
    _lastRefillTrack = null;
    _startingQueueVersion = null;
    state = const WaveState();
    if (failure == null) {
      ref
          .read(recommendationsProvider.notifier)
          .reportFailure(WaveFailure.noTracks);
    }
  }

  /// A cancellable pause: [cancel] and dispose wake it up immediately.
  Future<void> _pause(Duration delay) {
    final wait = _retryWait = Completer<void>();
    _retryTimer = Timer(delay, _wake);
    return wait.future;
  }

  void _wake() {
    _retryTimer?.cancel();
    _retryTimer = null;
    final wait = _retryWait;
    _retryWait = null;
    if (wait != null && !wait.isCompleted) wait.complete();
  }

  Future<void> _search({required bool append}) => ref
      .read(recommendationsProvider.notifier)
      .generate(
        currentTrack: ref.read(playerControllerProvider).track,
        append: append,
        limit: searchLimit,
      );

  bool _stale(bool append) =>
      (append && !_ownsQueue(ref.read(playerControllerProvider))) ||
      (!append &&
          ref.read(playerControllerProvider).queueVersion !=
              _startingQueueVersion);

  /// Errors a new attempt could plausibly fix; the rest need the user.
  bool _retryable(WaveFailure failure) => switch (failure) {
    WaveFailure.noTracks || WaveFailure.network || WaveFailure.source => true,
    _ => false,
  };

  /// Unused candidates already found, not playing and not in the queue.
  List<Recommendation> _pool({required bool append}) {
    final player = ref.read(playerControllerProvider.notifier);
    // A fresh wave replaces the queue, so only a refill avoids what is queued.
    final taken = {
      ..._ids,
      if (append) ...{
        ?ref.read(playerControllerProvider).track?.id,
        ...player.upcomingTracks.map((track) => track.id),
      },
    };
    return ref
        .read(recommendationsProvider)
        .items
        .where((item) => !taken.contains(item.track.id))
        .toList();
  }

  void _enqueue(List<Recommendation> batch, {required bool append}) {
    final player = ref.read(playerControllerProvider.notifier);
    final ids = batch.map((item) => item.track.id).toSet();
    _ids.addAll(ids);
    _mutatingQueue = true;
    try {
      if (append) {
        for (final item in batch) {
          player.addToQueue(item.track);
        }
      } else {
        _lastRefillTrack = batch.first.track.id;
        player.play(
          batch.first.track,
          queue: batch.map((item) => item.track).toList(),
        );
      }
      // Keep only what the player really accepted.
      final queued = {
        ?ref.read(playerControllerProvider).track?.id,
        ...player.upcomingTracks.map((track) => track.id),
      };
      _ids.removeAll(ids.where((id) => !queued.contains(id)));
    } finally {
      _mutatingQueue = false;
    }
    unawaited(_markShown(ids.where(_ids.contains).toList()));
  }

  /// Only tracks really put in the queue get the "shown" cooldown; spare
  /// candidates stay in the pool untouched.
  Future<void> _markShown(List<String> ids) async {
    if (ids.isEmpty) return;
    try {
      final identity = await _stableIdentity();
      if (identity == null) return;
      await ref
          .read(seenStoreProvider)
          .record(identity, SeenKind.shown, ids, DateTime.now());
    } catch (_) {
      // Memory is best effort; the queue itself is already correct.
    }
  }

  /// The verified identity of the account active right now, or null when it
  /// is anonymous or the account changed while it was being resolved. The
  /// auth token is captured before the first await.
  Future<String?> _stableIdentity() async {
    final token = ref.read(authControllerProvider).userToken;
    final provider = ref.read(listeningIdentityProvider);
    final identity =
        provider.asData?.value ??
        await ref.read(listeningIdentityProvider.future);
    if (_disposed ||
        ref.read(authControllerProvider).userToken != token ||
        identity == 'anonymous') {
      return null;
    }
    return identity;
  }

  void _prefetchIfLow(int epoch) {
    final player = ref.read(playerControllerProvider.notifier);
    if (player.upcomingTracks.length > initialPrefetchThreshold) return;
    scheduleMicrotask(() {
      if (!_disposed && epoch == _epoch && state.active && !state.discovering) {
        unawaited(_generate(append: true));
      }
    });
  }

  /// Whether [trackId] was queued by the active wave.
  bool ownsTrack(String trackId) => state.active && _ids.contains(trackId);

  bool _dislikeBusy = false;

  /// Thumbs-down on the playing wave track: remember it for the active
  /// account (id and artist handle, locally only), then move on. A second tap
  /// while the first is being stored is ignored, and the player only skips if
  /// the same track of the same wave is still playing once the write is done.
  /// The result says honestly whether it was saved and whether it skipped;
  /// null means nothing happened.
  Future<WaveDislike?> dislikeCurrent() async {
    final track = ref.read(playerControllerProvider).track;
    if (_dislikeBusy || track == null || !ownsTrack(track.id)) return null;
    _dislikeBusy = true;
    final wave = _waveId;
    try {
      final identity = await _stableIdentity();
      if (identity == null) return null;
      final saved = await ref
          .read(seenStoreProvider)
          .dislike(identity, track.id, track.artistHandle, DateTime.now());
      if (_disposed) return null;
      final player = ref.read(playerControllerProvider.notifier);
      var skipped = false;
      if (wave == _waveId &&
          ref.read(playerControllerProvider).track?.id == track.id &&
          ownsTrack(track.id)) {
        if (player.upcomingTracks.isEmpty) {
          // Nothing to skip to yet: ask for more and keep playing.
          if (!state.discovering) unawaited(_generate(append: true));
        } else {
          player.next(reason: ListeningTransitionCause.dislike);
          skipped = ref.read(playerControllerProvider).track?.id != track.id;
        }
      }
      return (identity: identity, track: track, saved: saved, skipped: skipped);
    } catch (_) {
      return null;
    } finally {
      _dislikeBusy = false;
    }
  }

  /// Take back a dislike for the account it was made under.
  Future<void> undoDislike(WaveDislike dislike) async {
    try {
      await ref
          .read(seenStoreProvider)
          .undislike(dislike.identity, dislike.track.id);
    } catch (_) {
      // Nothing to undo if the memory is unavailable.
    }
  }

  void cancel() {
    _epoch++;
    _waveId++;
    _wake();
    _lastRefillTrack = null;
    _startingQueueVersion = null;
    if (state.discovering) ref.read(recommendationsProvider.notifier).cancel();
    state = const WaveState();
  }
}

final waveControllerProvider = NotifierProvider<WaveController, WaveState>(
  WaveController.new,
);

/// Pause between retries after an empty or failed search.
final waveRetryDelayProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 4),
);

/// True while the playing track was queued by the active wave and a verified
/// account exists to remember a dislike under.
final currentTrackInWaveProvider = Provider<bool>((ref) {
  ref.watch(waveControllerProvider);
  final identity = ref.watch(listeningIdentityProvider).asData?.value;
  if (identity == null || identity == 'anonymous') return false;
  final id = ref.watch(playerControllerProvider.select((p) => p.track?.id));
  return id != null && ref.read(waveControllerProvider.notifier).ownsTrack(id);
});
