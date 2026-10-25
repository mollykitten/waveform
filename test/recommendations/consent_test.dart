import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/api/soundcloud_auth.dart';
import 'package:waveform_app/core/recommendations/ai_config.dart';
import 'package:waveform_app/core/recommendations/ai_client.dart';
import 'package:waveform_app/core/recommendations/chatgpt_auth.dart';
import 'package:waveform_app/core/recommendations/models.dart';
import 'package:waveform_app/core/recommendations/providers.dart';
import 'package:waveform_app/core/recommendations/recommendation_service.dart';

import 'support.dart';

class MemoryConfig extends AiConfigStore {
  AiConfig value = testConfig;
  @override
  Future<AiConfig> load() async => value;
  @override
  Future<void> save(AiConfig config) async {
    value = config;
  }
}

class NoChatGpt extends ChatGptAuth {
  @override
  Future<void> restore() async {}
}

void main() {
  late MemoryConfig store;
  setUp(() {
    store = MemoryConfig();
  });
  Future<ProviderContainer> open({String identity = 'soundcloud-one'}) async {
    final auth = NoChatGpt();
    final container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWithBuild(
          (ref, notifier) => const SoundcloudAuth(),
        ),
        aiListeningIdentityProvider.overrideWith((ref) async => identity),
        chatGptAuthProvider.overrideWithValue(auth),
        aiConfigStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(() {
      container.dispose();
      auth.close();
    });
    container.listen(aiSettingsProvider, (_, _) {});
    for (var i = 0; i < 20 && !container.read(aiSettingsProvider).ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(container.read(aiSettingsProvider).ready, isTrue);
    return container;
  }

  test(
    'one listening approval persists for the same destination and SoundCloud identity',
    () async {
      final first = await open();
      await first.read(aiSettingsProvider.notifier).setListeningConsent(true);
      expect(store.value.consentBinding, isNotEmpty);
      final second = await open();
      expect(second.read(aiSettingsProvider).config.listeningConsent, isTrue);
      expect(
        second.read(aiSettingsProvider).config.consentBinding,
        store.value.consentBinding,
      );
      final changedAccount = await open(identity: 'soundcloud-two');
      expect(
        changedAccount.read(aiSettingsProvider).config.listeningConsent,
        isFalse,
      );
      expect(store.value.listeningConsent, isFalse);
    },
  );

  test('new custom credentials revoke previous listening permission', () async {
    final container = await open();
    final controller = container.read(aiSettingsProvider.notifier);
    await controller.save(testConfig, sessionKey: 'first');
    await controller.setListeningConsent(true);
    await controller.save(
      container.read(aiSettingsProvider).config,
      sessionKey: 'second',
    );
    expect(container.read(aiSettingsProvider).config.listeningConsent, isFalse);
  });

  test(
    'a cached failed profile lookup is retried on explicit approval',
    () async {
      var attempts = 0;
      final auth = NoChatGpt();
      final container = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWithBuild(
            (ref, notifier) => const SoundcloudAuth(),
          ),
          aiListeningIdentityProvider.overrideWith((ref) async {
            if (++attempts == 1) throw AiFailure.source;
            return 'soundcloud-one';
          }),
          chatGptAuthProvider.overrideWithValue(auth),
          aiConfigStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(() {
        container.dispose();
        auth.close();
      });
      container.listen(aiSettingsProvider, (_, _) {});
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await expectLater(
        container.read(aiListeningIdentityProvider.future),
        throwsA(AiFailure.source),
      );
      await container
          .read(aiSettingsProvider.notifier)
          .setListeningConsent(true);
      expect(attempts, 2);
      expect(
        container.read(aiSettingsProvider).config.listeningConsent,
        isTrue,
      );
      expect(container.read(aiSettingsProvider).error, isNull);
    },
  );

  test(
    'startup before SoundCloud auth restoration preserves the bound approval',
    () async {
      final initial = await open();
      await initial.read(aiSettingsProvider.notifier).setListeningConsent(true);
      final binding = store.value.consentBinding;
      final pendingAuth = await open(identity: 'anonymous');
      expect(
        pendingAuth.read(aiSettingsProvider).config.listeningConsent,
        isTrue,
      );
      expect(store.value.consentBinding, binding);
      final restoredAuth = await open();
      expect(
        restoredAuth.read(aiSettingsProvider).config.listeningConsent,
        isTrue,
      );
    },
  );

  test('late identity lookup cannot approve a changed destination', () async {
    final identity = Completer<String>();
    final auth = NoChatGpt();
    final container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWithBuild(
          (ref, notifier) => const SoundcloudAuth(),
        ),
        aiListeningIdentityProvider.overrideWith((ref) => identity.future),
        chatGptAuthProvider.overrideWithValue(auth),
        aiConfigStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(() {
      container.dispose();
      auth.close();
    });
    container.listen(aiSettingsProvider, (_, _) {});
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final controller = container.read(aiSettingsProvider.notifier);
    final approval = controller.setListeningConsent(true);
    final assertion = expectLater(approval, throwsA(AiFailure.cancelled));
    await controller.save(
      const AiConfig(endpoint: 'https://other.example/v1', model: 'm'),
    );
    identity.complete('soundcloud-one');
    await assertion;
    expect(store.value.listeningConsent, isFalse);
  });

  test(
    'unverified restored approval cannot send mood or current track metadata',
    () async {
      final original = await open();
      await original
          .read(aiSettingsProvider.notifier)
          .setListeningConsent(true);
      final pendingAuth = await open(identity: 'anonymous');
      final client = ScriptedAi();
      await expectLater(
        pendingAuth
            .read(aiSettingsProvider.notifier)
            .generate(
              RecommendationService(api: TestSoundcloud(), client: client),
              consent: AiConsent(
                destination: testConfig.destination,
                listening: false,
              ),
              mood: 'night',
              useListening: false,
              currentTrack: realTrack('current'),
              cancelToken: CancelToken(),
            ),
        throwsA(AiFailure.source),
      );
      expect(client.payloads, isEmpty);
      expect(
        pendingAuth.read(aiSettingsProvider).config.listeningConsent,
        isTrue,
      );
      expect(store.value.listeningConsent, isTrue);
    },
  );

  test(
    'confirmed new identity after failed startup lookup revokes a stale approval before sending',
    () async {
      final original = await open();
      await original
          .read(aiSettingsProvider.notifier)
          .setListeningConsent(true);
      final auth = NoChatGpt();
      var attempts = 0;
      final container = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWithBuild(
            (ref, notifier) => const SoundcloudAuth(),
          ),
          aiListeningIdentityProvider.overrideWith((ref) async {
            if (++attempts == 1) throw AiFailure.source;
            return 'soundcloud-two';
          }),
          chatGptAuthProvider.overrideWithValue(auth),
          aiConfigStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(() {
        container.dispose();
        auth.close();
      });
      container.listen(aiSettingsProvider, (_, _) {});
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(
        container.read(aiSettingsProvider).config.listeningConsent,
        isTrue,
      );
      final revision = container.read(aiSettingsProvider).revision;
      final client = ScriptedAi();
      await expectLater(
        container
            .read(aiSettingsProvider.notifier)
            .generate(
              RecommendationService(api: TestSoundcloud(), client: client),
              consent: AiConsent(
                destination: testConfig.destination,
                listening: false,
              ),
              mood: 'night',
              useListening: false,
              currentTrack: realTrack('current'),
              cancelToken: CancelToken(),
            ),
        throwsA(AiFailure.configuration),
      );
      expect(client.payloads, isEmpty);
      expect(
        container.read(aiSettingsProvider).revision,
        greaterThan(revision),
      );
      expect(
        container.read(aiSettingsProvider).config.listeningConsent,
        isFalse,
      );
      expect(store.value.listeningConsent, isFalse);
    },
  );

  test(
    'unavailable identity blocks all metadata while preserving permission for recovery',
    () async {
      final original = await open();
      await original
          .read(aiSettingsProvider.notifier)
          .setListeningConsent(true);
      final auth = NoChatGpt();
      var available = false;
      final container = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWithBuild(
            (ref, notifier) => const SoundcloudAuth(),
          ),
          aiListeningIdentityProvider.overrideWith((ref) async {
            if (!available) throw AiFailure.source;
            return 'soundcloud-one';
          }),
          chatGptAuthProvider.overrideWithValue(auth),
          aiConfigStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(() {
        container.dispose();
        auth.close();
      });
      container.listen(aiSettingsProvider, (_, _) {});
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final client = ScriptedAi();
      Future<void> generate() async {
        await container
            .read(aiSettingsProvider.notifier)
            .generate(
              RecommendationService(api: TestSoundcloud(), client: client),
              consent: AiConsent(
                destination: testConfig.destination,
                listening: false,
              ),
              mood: 'night',
              useListening: false,
              currentTrack: realTrack('current'),
              cancelToken: CancelToken(),
            );
      }

      await expectLater(generate(), throwsA(AiFailure.source));
      expect(client.payloads, isEmpty);
      expect(
        container.read(aiSettingsProvider).config.listeningConsent,
        isTrue,
      );
      expect(store.value.listeningConsent, isTrue);
      available = true;
      await generate();
      expect(client.payloads.length, 2);
    },
  );

  test(
    'late identity mismatch cannot revoke replacement configuration',
    () async {
      final original = await open();
      await original
          .read(aiSettingsProvider.notifier)
          .setListeningConsent(true);
      final auth = NoChatGpt();
      final identity = Completer<String>(), requested = Completer<void>();
      var attempts = 0;
      final container = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWithBuild(
            (ref, notifier) => const SoundcloudAuth(),
          ),
          aiListeningIdentityProvider.overrideWith((ref) async {
            if (++attempts == 1) throw AiFailure.source;
            requested.complete();
            return identity.future;
          }),
          chatGptAuthProvider.overrideWithValue(auth),
          aiConfigStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(() {
        container.dispose();
        auth.close();
      });
      container.listen(aiSettingsProvider, (_, _) {});
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final client = ScriptedAi();
      final controller = container.read(aiSettingsProvider.notifier);
      final generation = controller.generate(
        RecommendationService(api: TestSoundcloud(), client: client),
        consent: AiConsent(
          destination: testConfig.destination,
          listening: false,
        ),
        mood: 'night',
        useListening: false,
        currentTrack: realTrack('current'),
        cancelToken: CancelToken(),
      );
      final assertion = expectLater(generation, throwsA(AiFailure.cancelled));
      await requested.future;
      const replacement = AiConfig(
        endpoint: 'https://replacement.example/v1',
        model: 'm',
      );
      await controller.save(replacement);
      identity.complete('soundcloud-two');
      await assertion;
      expect(client.payloads, isEmpty);
      expect(store.value.destination, replacement.destination);
      expect(
        container.read(aiSettingsProvider).config.destination,
        replacement.destination,
      );
    },
  );
}
