import 'dart:async';

import 'package:dio/dio.dart';
import 'package:waveform_app/core/recommendations/ai_client.dart';
import 'package:waveform_app/core/recommendations/ai_config.dart';
import 'package:waveform_app/core/recommendations/models.dart';
import 'package:waveform_app/core/recommendations/providers.dart';
import 'package:waveform_app/core/recommendations/recommendation_service.dart';
import 'package:waveform_app/shared/models/track.dart';

class MemoryConfigStore extends AiConfigStore {
  AiConfig config = const AiConfig();
  Completer<void>? pending;
  @override
  Future<AiConfig> load() async => config;
  @override
  Future<void> save(AiConfig value) async {
    if (pending != null) await pending!.future;
    config = value;
  }
}

/// UI boundary double: no browser auth, credential store or account files.
/// The production recommendation service still runs with scripted test data.
class WaveTestSettings extends AiSettingsController {
  WaveTestSettings({this.initial = const AiSettingsState(ready: true)});
  final AiSettingsState initial;
  int connections = 0;
  bool usedNewAccount = false;
  AiFailure? connectionFailure;
  int consentChanges = 0;
  int generations = 0;
  bool? lastUseListening;
  Track? lastCurrentTrack;
  Completer<void>? pendingWrite;
  Completer<void>? pendingConnect;

  @override
  AiSettingsState build() => initial;

  void _publish({
    AiConfig? config,
    bool? connected,
    bool? connecting,
    bool? key,
    AiFailure? error,
  }) {
    state = AiSettingsState(
      ready: true,
      error: error,
      config: config ?? state.config,
      chatGptConnected: connected ?? state.chatGptConnected,
      chatGptAccountLabel: 'listener@example.test',
      connecting: connecting ?? state.connecting,
      hasSessionKey: key ?? state.hasSessionKey,
      revision: state.revision + 1,
    );
  }

  @override
  Future<void> connectChatGpt({bool newAccount = false}) async {
    connections++;
    usedNewAccount = newAccount;
    _publish(connecting: true);
    if (pendingConnect != null) await pendingConnect!.future;
    if (connectionFailure != null) {
      _publish(connecting: false, error: connectionFailure);
      return;
    }
    _publish(
      config: const AiConfig(backend: AiBackend.chatGpt),
      connected: true,
      connecting: false,
    );
  }

  @override
  Future<void> disconnectChatGpt() async =>
      _publish(connected: false, config: state.config.withConsent(false));

  @override
  Future<void> useChatGpt() async =>
      _publish(config: const AiConfig(backend: AiBackend.chatGpt));

  @override
  Future<void> setListeningConsent(bool value) async {
    consentChanges++;
    _publish(
      config: state.config.withConsent(value, binding: 'ui-test-binding'),
    );
    if (pendingWrite != null) await pendingWrite!.future;
  }

  @override
  Future<void> save(AiConfig config, {String? sessionKey}) async {
    if (!config.isValid) throw AiFailure.configuration;
    final keep =
        config.destination == state.config.destination &&
        config.backend == state.config.backend &&
        state.config.listeningConsent;
    _publish(
      config: config.withConsent(keep, binding: 'ui-test-binding'),
      key: sessionKey?.isNotEmpty ?? state.hasSessionKey,
    );
    if (pendingWrite != null) await pendingWrite!.future;
  }

  @override
  Future<void> clear() async {
    _publish(config: const AiConfig(backend: AiBackend.chatGpt), key: false);
    if (pendingWrite != null) await pendingWrite!.future;
  }

  @override
  Future<List<Recommendation>> generate(
    RecommendationService service, {
    required AiConsent consent,
    required String mood,
    required bool useListening,
    required CancelToken cancelToken,
    Track? currentTrack,
    Set<String> excludedTrackIds = const {},
    Set<String> localExcludedTrackIds = const {},
    int limit = 10,
  }) {
    generations++;
    lastUseListening = useListening;
    lastCurrentTrack = currentTrack;
    return service.generate(
      config: state.config,
      consent: consent,
      apiKey: '',
      mood: mood,
      useListening: useListening,
      cancelToken: cancelToken,
      currentTrack: currentTrack,
      excludedTrackIds: excludedTrackIds,
      localExcludedTrackIds: localExcludedTrackIds,
      limit: limit,
    );
  }
}
