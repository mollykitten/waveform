import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/models/track.dart';
import '../api/liked_tracks.dart';
import '../api/providers.dart';
import '../api/soundcloud_auth.dart';
import '../log/talker.dart';
import 'ai_client.dart';
import 'ai_config.dart';
import 'chatgpt_auth.dart';
import 'chatgpt_client.dart';
import 'models.dart';
import 'listening_store_provider.dart';
import 'recommendation_service.dart';
import 'seen_store.dart';
import 'vector_engine.dart';
import 'vector_store.dart';

final aiConfigStoreProvider = Provider<AiConfigStore>((ref) => AiConfigStore());
final chatGptAuthProvider = Provider<ChatGptAuth>((ref) {
  final auth = ChatGptAuth();
  ref.onDispose(auth.close);
  return auth;
});

/// The actual SoundCloud profile identity, never an OAuth-token fingerprint.
final aiListeningIdentityProvider = FutureProvider<String>((ref) async {
  final auth = ref.watch(authControllerProvider);
  if (!auth.isAuthenticated) return 'anonymous';
  final rail = await ref.watch(soundcloudApiProvider).rail();
  if (rail.me == null) throw AiFailure.source;
  return rail.me!.id;
}, retry: (_, _) => null);

class AiSettingsState {
  const AiSettingsState({
    this.config = const AiConfig(backend: AiBackend.chatGpt),
    this.ready = false,
    this.hasSessionKey = false,
    this.error,
    this.revision = 0,
    this.chatGptConnected = false,
    this.chatGptAccountLabel,
    this.connecting = false,
  });
  final AiConfig config;
  final bool ready;
  final bool hasSessionKey;
  final AiFailure? error;
  final int revision;
  final bool chatGptConnected;
  final String? chatGptAccountLabel;
  final bool connecting;
}

/// The credential stays in this controller's private session field. Neither
/// provider state, persisted JSON nor toString exposes its value.
class AiSettingsController extends Notifier<AiSettingsState> {
  String _sessionKey = '';
  int _restoreVersion = 0;
  int _connectionVersion = 0;
  bool _connected = false;
  String? _accountLabel;
  bool _connecting = false;

  @override
  AiSettingsState build() {
    ref.listen(authControllerProvider, (previous, next) {
      if (previous?.userToken != next.userToken) {
        _accountChanged(restoreConsent: next.isAuthenticated);
      }
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
      // Custom providers continue working even if an OS secret service is
      // unavailable. ChatGPT must never fall back to unprotected storage.
      try {
        final auth = ref.read(chatGptAuthProvider);
        await auth.restore();
        _connected = auth.account?.connected == true;
        _accountLabel = auth.account?.label;
      } catch (_) {
        if (config.backend == AiBackend.chatGpt) throw AiFailure.storage;
      }
      var binding = '';
      String? identity;
      if (config.listeningConsent && config.consentBinding.isNotEmpty) {
        try {
          identity = await ref.read(aiListeningIdentityProvider.future);
          binding = await _binding(config, identity: identity);
        } catch (_) {
          /* No disclosure until identity is available. */
        }
      }
      if (!ref.mounted || version != _restoreVersion) return;
      state = AiSettingsState(
        config: config.withConsent(
          config.listeningConsent &&
              config.consentBinding.isNotEmpty &&
              (identity == null ||
                  identity == 'anonymous' ||
                  binding.isNotEmpty && config.consentBinding == binding),
        ),
        ready: true,
        revision: state.revision,
        chatGptConnected: _connected,
        chatGptAccountLabel: _accountLabel,
      );
      if (config.listeningConsent &&
          identity != null &&
          identity != 'anonymous' &&
          binding.isNotEmpty &&
          config.consentBinding != binding) {
        await _persist(config.withConsent(false));
      }
    } catch (error) {
      if (!ref.mounted || version != _restoreVersion) return;
      state = AiSettingsState(
        ready: true,
        error: error is AiFailure ? error : AiFailure.configuration,
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
    final credentialChanged =
        sessionKey != null && sessionKey.trim() != _sessionKey;
    if (!sameDestination) _sessionKey = '';
    if (sessionKey != null) _sessionKey = sessionKey.trim();
    final next = config.withConsent(
      sameDestination &&
          !credentialChanged &&
          state.config.listeningConsent &&
          config.listeningConsent,
      binding: state.config.consentBinding,
    );
    state = AiSettingsState(
      config: next,
      ready: true,
      hasSessionKey: _sessionKey.isNotEmpty,
      revision: state.revision + 1,
      chatGptConnected: _connected,
      chatGptAccountLabel: _accountLabel,
    );
    await _persist(next);
  }

  Future<void> setListeningConsent(bool value) async {
    if (!state.config.isValid) throw AiFailure.configuration;
    ++_restoreVersion;
    final revision = state.revision;
    final binding = value ? await _binding(state.config) : '';
    if (!ref.mounted || revision != state.revision) throw AiFailure.cancelled;
    if (value && binding.isEmpty) throw AiFailure.configuration;
    final next = state.config.withConsent(value, binding: binding);
    state = AiSettingsState(
      config: next,
      ready: true,
      hasSessionKey: _sessionKey.isNotEmpty,
      revision: state.revision + 1,
      chatGptConnected: _connected,
      chatGptAccountLabel: _accountLabel,
    );
    await _persist(next);
  }

  void _accountChanged({bool restoreConsent = false}) {
    final version = ++_restoreVersion;
    _sessionKey = '';
    final next = state.config.withConsent(false);
    final ready = state.ready;
    state = AiSettingsState(
      config: next,
      ready: ready,
      revision: state.revision + 1,
      chatGptConnected: _connected,
      chatGptAccountLabel: _accountLabel,
    );
    if (restoreConsent) {
      unawaited(_restore(version));
    } else if (ready) {
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
    state = AiSettingsState(
      ready: true,
      revision: state.revision + 1,
      chatGptConnected: _connected,
      chatGptAccountLabel: _accountLabel,
    );
    await _persist(state.config);
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
        chatGptConnected: _connected,
        chatGptAccountLabel: _accountLabel,
      );
    }
  }

  Future<String> _identity() async {
    try {
      return await ref.read(aiListeningIdentityProvider.future);
    } catch (_) {
      if (!ref.mounted) throw AiFailure.cancelled;
      // A transient profile lookup must not poison all later approvals.
      ref.invalidate(aiListeningIdentityProvider);
      try {
        return await ref.read(aiListeningIdentityProvider.future);
      } catch (_) {
        throw AiFailure.source;
      }
    }
  }

  Future<String> _binding(AiConfig config, {String? identity}) async {
    identity ??= await _identity();
    final connection = config.backend == AiBackend.chatGpt
        ? ref.read(chatGptAuthProvider).account?.binding
        : '${config.backend.name}:${config.destination}';
    if (connection == null) return '';
    return sha256
        .convert(utf8.encode('$identity:$connection:metadata-v1'))
        .toString();
  }

  void _connectionState({AiFailure? error}) {
    state = AiSettingsState(
      config: state.config,
      ready: true,
      hasSessionKey: _sessionKey.isNotEmpty,
      revision: state.revision + 1,
      chatGptConnected: _connected,
      chatGptAccountLabel: _accountLabel,
      connecting: _connecting,
      error: error,
    );
  }

  Future<void> useChatGpt() => save(const AiConfig(backend: AiBackend.chatGpt));

  Future<void> connectChatGpt({bool newAccount = false}) async {
    if (_connecting) return;
    final version = ++_restoreVersion;
    final connectionVersion = ++_connectionVersion;
    _connecting = true;
    _connectionState();
    try {
      final auth = ref.read(chatGptAuthProvider);
      final before = auth.account?.binding;
      await auth.signIn(newAccount: newAccount);
      if (!ref.mounted || connectionVersion != _connectionVersion) return;
      // SoundCloud changes revoke consent but do not cancel ChatGPT sign-in.
      // Reconcile persisted credentials without restoring stale configuration.
      _connected = auth.account?.connected == true;
      _accountLabel = auth.account?.label;
      if (version != _restoreVersion) return;
      final keep =
          before == auth.account?.binding &&
          state.config.backend == AiBackend.chatGpt;
      final next = const AiConfig(backend: AiBackend.chatGpt).withConsent(
        keep && state.config.listeningConsent,
        binding: state.config.consentBinding,
      );
      state = AiSettingsState(
        config: next,
        ready: true,
        chatGptConnected: _connected,
        chatGptAccountLabel: _accountLabel,
        revision: state.revision + 1,
      );
      await _persist(next);
    } catch (error) {
      if (ref.mounted) {
        _connectionState(error: error is AiFailure ? error : AiFailure.signIn);
      }
    } finally {
      _connecting = false;
      if (ref.mounted) _connectionState(error: state.error);
    }
  }

  Future<void> disconnectChatGpt() async {
    ++_restoreVersion;
    ++_connectionVersion;
    _connected = false;
    _accountLabel = null;
    final next = state.config.withConsent(false);
    state = AiSettingsState(
      config: next,
      ready: true,
      revision: state.revision + 1,
    );
    await _persist(next);
    try {
      final revoked = await ref.read(chatGptAuthProvider).signOut();
      if (ref.mounted) {
        _connectionState(error: revoked ? null : AiFailure.revocation);
      }
    } catch (error) {
      if (ref.mounted) {
        _connectionState(error: error is AiFailure ? error : AiFailure.storage);
      }
    }
  }

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
  }) async {
    final config = state.config;
    final revision = state.revision;
    final sourceAccount = ref.read(authControllerProvider).userToken;
    final aiAccount = config.backend == AiBackend.chatGpt
        ? ref.read(chatGptAuthProvider).account?.binding
        : null;
    void check() {
      if (!ref.mounted ||
          state.revision != revision ||
          cancelToken.isCancelled ||
          sourceAccount != ref.read(authControllerProvider).userToken ||
          config.backend == AiBackend.chatGpt &&
              aiAccount != ref.read(chatGptAuthProvider).account?.binding) {
        throw AiFailure.cancelled;
      }
    }

    if (config.backend == AiBackend.chatGpt && !_connected) {
      throw AiFailure.credentials;
    }
    if (useListening && !config.listeningConsent) throw AiFailure.configuration;
    // A remembered approval covers mood/current-track metadata too. Startup
    // cannot bypass identity verification merely by disabling history access.
    String? verifiedListeningIdentity;
    if (config.listeningConsent) {
      final identity = await _identity();
      check();
      final binding = await _binding(config, identity: identity);
      check();
      if (binding.isEmpty || config.consentBinding != binding) {
        // Anonymous startup is not proof of an account change. Keep its saved
        // grant pending, but send no metadata until it can be verified.
        if (identity == 'anonymous' || binding.isEmpty) throw AiFailure.source;
        ++_restoreVersion;
        final next = config.withConsent(false);
        state = AiSettingsState(
          config: next,
          ready: state.ready,
          hasSessionKey: _sessionKey.isNotEmpty,
          revision: revision + 1,
          chatGptConnected: _connected,
          chatGptAccountLabel: _accountLabel,
          connecting: _connecting,
        );
        if (ref.mounted && state.revision == revision + 1) await _persist(next);
        throw AiFailure.configuration;
      }
      verifiedListeningIdentity = identity;
    }
    check();
    return service.generate(
      config: config,
      consent: consent,
      apiKey: _sessionKey,
      mood: mood,
      useListening: useListening,
      cancelToken: cancelToken,
      currentTrack: currentTrack,
      excludedTrackIds: excludedTrackIds,
      listeningIdentity: verifiedListeningIdentity,
      localExcludedTrackIds: localExcludedTrackIds,
      checkCurrent: check,
      limit: limit,
    );
  }
}

final aiSettingsProvider =
    NotifierProvider<AiSettingsController, AiSettingsState>(
      AiSettingsController.new,
    );

final aiClientProvider = Provider<AiClient>((ref) {
  final client = HttpAiClient();
  final chatGpt = ChatGptAiClient(auth: ref.watch(chatGptAuthProvider));
  ref.onDispose(client.close);
  ref.onDispose(chatGpt.close);
  return RoutedAiClient(client, chatGpt);
});

final recommendationServiceProvider = Provider<RecommendationService>(
  (ref) => RecommendationService(
    api: ref.watch(soundcloudApiProvider),
    client: ref.watch(aiClientProvider),
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
  final AiFailure? error;
}

class RecommendationsController extends Notifier<RecommendationState> {
  String? _knownIdentity;
  CancelToken? _cancel;
  int _generation = 0;

  @override
  RecommendationState build() {
    ref.listen(aiSettingsProvider.select((value) => value.revision), (_, _) {
      cancel();
      state = const RecommendationState();
    });
    // Logging out drops that account's seen memory; switching accounts keeps
    // each one's file so A -> B -> A loses nothing.
    ref.listen(aiListeningIdentityProvider, (_, next) {
      // `previous` can be a loading state, so remember the last real value.
      final identity = next.asData?.value;
      if (identity == null) return;
      final was = _knownIdentity;
      _knownIdentity = identity;
      if (was != null && was != 'anonymous' && identity == 'anonymous') {
        unawaited(ref.read(seenStoreProvider).forget(was));
      }
    }, fireImmediately: true);
    ref.onDispose(() {
      _generation++;
      _cancel?.cancel();
    });
    return const RecommendationState();
  }

  /// Surface a visible failure after an automatic search gave up quietly.
  void reportFailure(AiFailure failure) {
    state = RecommendationState(items: state.items, error: failure);
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
    bool append = false,
    int limit = 10,
  }) async {
    cancel();
    final generation = _generation;
    final token = _cancel = CancelToken();
    final previous = append ? state.items : const <Recommendation>[];
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
            excludedTrackIds: previous.map((item) => item.track.id).toSet(),
            localExcludedTrackIds: ref.read(likedTracksProvider),
            limit: limit,
          );
      if (!ref.mounted || generation != _generation) return;
      state = RecommendationState(items: [...previous, ...result]);
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
