import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/models/track.dart';
import '../api/liked_tracks.dart';
import '../api/providers.dart';
import '../api/soundcloud_auth.dart';
import '../log/talker.dart';
import 'listening_store_provider.dart';
import 'models.dart';
import 'recommendation_service.dart';
import 'seen_store.dart';
import 'vector_engine.dart';
import 'vector_store.dart';

/// The actual SoundCloud profile identity, never an OAuth-token fingerprint.
final listeningIdentityProvider = FutureProvider<String>((ref) async {
  final auth = ref.watch(authControllerProvider);
  if (!auth.isAuthenticated) return 'anonymous';
  final rail = await ref.watch(soundcloudApiProvider).rail();
  if (rail.me == null) throw WaveFailure.source;
  return rail.me!.id;
}, retry: (_, _) => null);

final recommendationServiceProvider = Provider<RecommendationService>(
  (ref) => RecommendationService(
    api: ref.watch(soundcloudApiProvider),
    onWarning: ref.read(talkerProvider).warning,
    vectorEngine: VectorEngine(
      api: ref.watch(soundcloudApiProvider),
      store: ref.watch(vectorStoreProvider),
      listening: ref.watch(listeningStoreProvider),
      seen: ref.watch(seenStoreProvider),
    ),
  ),
);

final seenStoreProvider = Provider<SeenStore>(
  (ref) => SeenStore(onFailure: ref.read(talkerProvider).warning),
);

final vectorStoreProvider = Provider<VectorStore>(
  (ref) => VectorStore(onFailure: ref.read(talkerProvider).warning),
);

class RecommendationState {
  const RecommendationState({
    this.items = const [],
    this.busy = false,
    this.error,
  });
  final List<Recommendation> items;
  final bool busy;
  final WaveFailure? error;
}

class RecommendationsController extends Notifier<RecommendationState> {
  CancelToken? _cancel;
  int _generation = 0;

  @override
  RecommendationState build() {
    ref.listen(authControllerProvider.select((s) => s.userToken), (_, _) {
      cancel();
      state = const RecommendationState();
    });
    ref.onDispose(() {
      _generation++;
      _cancel?.cancel();
    });
    return const RecommendationState();
  }

  /// Forget every earlier result, e.g. when a brand-new wave begins, so a
  /// failed search can never fall back on a previous wave's tracks.
  void clear() {
    cancel();
    state = const RecommendationState();
  }

  /// Surface a visible failure after an automatic search gave up quietly.
  void reportFailure(WaveFailure failure) {
    state = RecommendationState(items: state.items, error: failure);
  }

  void cancel() {
    _generation++;
    _cancel?.cancel();
    _cancel = null;
    state = RecommendationState(items: state.items);
  }

  Future<String> _identity() async {
    try {
      return await ref.read(listeningIdentityProvider.future);
    } catch (_) {
      if (!ref.mounted) throw WaveFailure.cancelled;
      // A transient profile lookup must not poison every later attempt.
      ref.invalidate(listeningIdentityProvider);
      try {
        return await ref.read(listeningIdentityProvider.future);
      } catch (_) {
        throw WaveFailure.source;
      }
    }
  }

  Future<void> generate({
    Track? currentTrack,
    bool append = false,
    int limit = 10,
  }) async {
    cancel();
    final generation = _generation;
    final token = _cancel = CancelToken();
    final previous = append ? state.items : const <Recommendation>[];
    state = RecommendationState(items: state.items, busy: true);
    final account = ref.read(authControllerProvider).userToken;
    void check() {
      if (!ref.mounted ||
          token.isCancelled ||
          account != ref.read(authControllerProvider).userToken) {
        throw WaveFailure.cancelled;
      }
    }

    try {
      final identity = await _identity();
      check();
      if (identity == 'anonymous') throw WaveFailure.signIn;
      final result = await ref
          .read(recommendationServiceProvider)
          .generate(
            listeningIdentity: identity,
            cancelToken: token,
            currentTrack: currentTrack,
            excludedTrackIds: previous.map((item) => item.track.id).toSet(),
            localExcludedTrackIds: ref.read(likedTracksProvider),
            checkCurrent: check,
            limit: limit,
          );
      if (!ref.mounted || generation != _generation) return;
      state = RecommendationState(items: [...previous, ...result]);
    } catch (error) {
      if (!ref.mounted || generation != _generation) return;
      state = RecommendationState(
        items: state.items,
        error: error is WaveFailure ? error : WaveFailure.network,
      );
    } finally {
      if (generation == _generation) _cancel = null;
    }
  }
}

final recommendationsProvider =
    NotifierProvider<RecommendationsController, RecommendationState>(
      RecommendationsController.new,
    );
