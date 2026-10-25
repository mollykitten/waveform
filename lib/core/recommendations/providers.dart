import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/models/track.dart';
import '../api/providers.dart';
import '../api/soundcloud_auth.dart';
import 'ai_client.dart';
import 'ai_config.dart';
import 'models.dart';
import 'recommendation_service.dart';

final aiConfigStoreProvider = Provider<AiConfigStore>((ref) => AiConfigStore());

class AiSettingsState {
  const AiSettingsState({
    this.config = const AiConfig(),
    this.ready = false,
    this.hasSessionKey = false,
    this.error,
    this.revision = 0,
  });
  final AiConfig config;
  final bool ready;
  final bool hasSessionKey;
  final AiFailure? error;
  final int revision;
}

/// The credential stays in this controller's private session field. Neither
/// provider state, persisted JSON nor toString exposes its value.
class AiSettingsController extends Notifier<AiSettingsState> {
  String _sessionKey = '';
  int _restoreVersion = 0;

  @override
  AiSettingsState build() {
    ref.listen(authControllerProvider, (previous, next) {
      if (previous != next) _accountChanged();
    });
    final version = ++_restoreVersion;
    unawaited(_restore(version));
    ref.onDispose(() {
      _sessionKey = '';
      _restoreVersion++;
    });
    return const AiSettingsState();
  }

  Future<void> _restore(int version) async {
    try {
      final config = await ref.read(aiConfigStoreProvider).load();
      if (!ref.mounted || version != _restoreVersion) return;
      // Never carry listening authorization across an unknown startup account.
      state = AiSettingsState(
        config: config.withConsent(false),
        ready: true,
        revision: state.revision,
      );
    } catch (_) {
      if (!ref.mounted || version != _restoreVersion) return;
      state = const AiSettingsState(
        ready: true,
        error: AiFailure.configuration,
      );
    }
  }

  Future<void> save(AiConfig config, {String? sessionKey}) async {
    if (!config.isValid ||
        (sessionKey != null &&
            (sessionKey.length > 4096 ||
                RegExp(r'[\r\n]').hasMatch(sessionKey)))) {
      throw AiFailure.configuration;
    }
    ++_restoreVersion;
    final sameDestination =
        state.config.isValid &&
        state.config.destination == config.destination &&
        state.config.backend == config.backend;
    if (!sameDestination) _sessionKey = '';
    if (sessionKey != null) _sessionKey = sessionKey.trim();
    final next = config.withConsent(
      sameDestination &&
          state.config.listeningConsent &&
          config.listeningConsent,
    );
    state = AiSettingsState(
      config: next,
      ready: true,
      hasSessionKey: _sessionKey.isNotEmpty,
      revision: state.revision + 1,
    );
    await _persist(next);
  }

  Future<void> setListeningConsent(bool value) async {
    if (!state.config.isValid) throw AiFailure.configuration;
    final next = state.config.withConsent(value);
    state = AiSettingsState(
      config: next,
      ready: true,
      hasSessionKey: _sessionKey.isNotEmpty,
      revision: state.revision + 1,
    );
    await _persist(next);
  }

  void _accountChanged() {
    final version = ++_restoreVersion;
    _sessionKey = '';
    final next = state.config.withConsent(false);
    final ready = state.ready;
    state = AiSettingsState(
      config: next,
      ready: ready,
      revision: state.revision + 1,
    );
    if (ready) {
      unawaited(_persist(next));
    } else {
      // Auth may finish restoring while configuration is still loading. Revoke
      // authorization without overwriting the saved endpoint with an empty one.
      unawaited(_restore(version));
    }
  }

  Future<void> clear() async {
    ++_restoreVersion;
    _sessionKey = '';
    state = AiSettingsState(ready: true, revision: state.revision + 1);
    await _persist(const AiConfig());
  }

  Future<void> _persist(AiConfig config) async {
    try {
      await ref.read(aiConfigStoreProvider).save(config);
    } catch (_) {
      if (!ref.mounted) return;
      state = AiSettingsState(
        config: state.config,
        ready: true,
        hasSessionKey: _sessionKey.isNotEmpty,
        error: AiFailure.configuration,
        revision: state.revision,
      );
    }
  }

  Future<List<Recommendation>> generate(
    RecommendationService service, {
    required AiConsent consent,
    required String mood,
    required bool useListening,
    required CancelToken cancelToken,
    Track? currentTrack,
  }) => service.generate(
    config: state.config,
    consent: consent,
    apiKey: _sessionKey,
    mood: mood,
    useListening: useListening,
    cancelToken: cancelToken,
    currentTrack: currentTrack,
  );
}

final aiSettingsProvider =
    NotifierProvider<AiSettingsController, AiSettingsState>(
      AiSettingsController.new,
    );

final aiClientProvider = Provider<AiClient>((ref) {
  final client = HttpAiClient();
  ref.onDispose(client.close);
  return client;
});

final recommendationServiceProvider = Provider<RecommendationService>(
  (ref) => RecommendationService(
    api: ref.watch(soundcloudApiProvider),
    client: ref.watch(aiClientProvider),
  ),
);

class RecommendationState {
  const RecommendationState({
    this.items = const [],
    this.busy = false,
    this.error,
  });
  final List<Recommendation> items;
  final bool busy;
  final AiFailure? error;
}

class RecommendationsController extends Notifier<RecommendationState> {
  CancelToken? _cancel;
  int _generation = 0;

  @override
  RecommendationState build() {
    ref.listen(aiSettingsProvider.select((value) => value.revision), (_, _) {
      cancel();
      state = const RecommendationState();
    });
    ref.onDispose(() {
      _generation++;
      _cancel?.cancel();
    });
    return const RecommendationState();
  }

  void cancel() {
    _generation++;
    _cancel?.cancel();
    _cancel = null;
    state = RecommendationState(items: state.items);
  }

  Future<void> generate({
    required AiConsent consent,
    required String mood,
    required bool useListening,
    Track? currentTrack,
  }) async {
    cancel();
    final generation = _generation;
    final token = _cancel = CancelToken();
    state = RecommendationState(items: state.items, busy: true);
    try {
      final result = await ref
          .read(aiSettingsProvider.notifier)
          .generate(
            ref.read(recommendationServiceProvider),
            consent: consent,
            mood: mood,
            useListening: useListening,
            currentTrack: currentTrack,
            cancelToken: token,
          );
      if (!ref.mounted || generation != _generation) return;
      state = RecommendationState(items: result);
    } catch (error) {
      if (!ref.mounted || generation != _generation) return;
      state = RecommendationState(
        items: state.items,
        error: error is AiFailure ? error : AiFailure.network,
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
