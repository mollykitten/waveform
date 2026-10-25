import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/api/soundcloud_auth.dart';
import 'package:waveform_app/core/recommendations/ai_config.dart';
import 'package:waveform_app/core/recommendations/providers.dart';
import 'package:waveform_app/core/recommendations/models.dart';

import 'support.dart';

class DelayedConfigStore extends AiConfigStore {
  final loaded = Completer<AiConfig>();
  final saved = <AiConfig>[];
  @override
  Future<AiConfig> load() => loaded.future;
  @override
  Future<void> save(AiConfig config) async {
    saved.add(config);
  }
}

void main() {
  late Directory directory;
  late ProviderContainer container;
  late ScriptedAi client;
  var authenticated = false;
  setUp(() async {
    authenticated = false;
    directory = await Directory.systemTemp.createTemp('waveform-ai-providers');
    client = ScriptedAi();
    container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWithBuild(
          (ref, notifier) => SoundcloudAuth(
            clientId: 'test',
            userToken: authenticated ? 'synthetic-account' : null,
          ),
        ),
        aiConfigStoreProvider.overrideWithValue(
          AiConfigStore(directory: () async => directory),
        ),
        aiClientProvider.overrideWithValue(client),
        soundcloudApiProvider.overrideWithValue(TestSoundcloud()),
      ],
    );
    container.listen(aiSettingsProvider, (_, _) {});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await container
        .read(aiSettingsProvider.notifier)
        .save(testConfig, sessionKey: 'SESSION_SECRET');
  });
  tearDown(() async {
    container.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'account change revokes consent/key and discards pending generation',
    () async {
      final settings = container.read(aiSettingsProvider.notifier);
      await settings.setListeningConsent(true);
      container.listen(recommendationsProvider, (_, _) {});
      final pending = client.pending = Completer<String>();
      final generation = container
          .read(recommendationsProvider.notifier)
          .generate(consent: testConsent, mood: 'night', useListening: false);
      authenticated = true;
      container.invalidate(authControllerProvider);
      container.read(authControllerProvider);
      await Future<void>.delayed(Duration.zero);
      pending.complete('{"queries":["ambient"]}');
      await generation;
      expect(container.read(aiSettingsProvider).hasSessionKey, isFalse);
      expect(
        container.read(aiSettingsProvider).config.listeningConsent,
        isFalse,
      );
      expect(container.read(recommendationsProvider).busy, isFalse);
      expect(container.read(recommendationsProvider).items, isEmpty);
    },
  );

  test(
    'auth restore racing config load does not erase the saved endpoint',
    () async {
      final store = DelayedConfigStore();
      var signedIn = false;
      final local = ProviderContainer(
        overrides: [
          aiConfigStoreProvider.overrideWithValue(store),
          authControllerProvider.overrideWithBuild(
            (ref, notifier) => SoundcloudAuth(
              clientId: 'test',
              userToken: signedIn ? 'test' : null,
            ),
          ),
        ],
      );
      addTearDown(local.dispose);
      local.listen(aiSettingsProvider, (_, _) {});
      signedIn = true;
      local.invalidate(authControllerProvider);
      local.read(authControllerProvider);
      await Future<void>.delayed(Duration.zero);
      store.loaded.complete(testConfig.withConsent(true));
      await Future<void>.delayed(Duration.zero);
      expect(
        local.read(aiSettingsProvider).config.destination,
        testConfig.destination,
      );
      expect(local.read(aiSettingsProvider).config.listeningConsent, isFalse);
      expect(store.saved, isEmpty);
    },
  );

  test(
    'key is session-only and endpoint changes revoke listening consent',
    () async {
      final controller = container.read(aiSettingsProvider.notifier);
      await controller.setListeningConsent(true);
      expect(container.read(aiSettingsProvider).hasSessionKey, isTrue);
      final file = await File(
        '${directory.path}/ai_config.json',
      ).readAsString();
      expect(file, isNot(contains('SESSION_SECRET')));
      await controller.save(
        const AiConfig(
          endpoint: 'https://other.example/v1',
          model: 'm',
          listeningConsent: true,
        ),
      );
      expect(
        container.read(aiSettingsProvider).config.listeningConsent,
        isFalse,
      );
      expect(container.read(aiSettingsProvider).hasSessionKey, isFalse);
    },
  );

  test(
    'refresh keeps success and cancellation discards late results',
    () async {
      container.listen(recommendationsProvider, (_, _) {});
      final controller = container.read(recommendationsProvider.notifier);
      await controller.generate(
        consent: testConsent,
        mood: 'night',
        useListening: false,
      );
      expect(
        container.read(recommendationsProvider).items.single.track.id,
        '2',
      );
      final pending = client.pending = Completer<String>();
      final refresh = controller.generate(
        consent: testConsent,
        mood: 'new',
        useListening: false,
      );
      expect(container.read(recommendationsProvider).busy, isTrue);
      expect(
        container.read(recommendationsProvider).items.single.track.id,
        '2',
      );
      controller.cancel();
      pending.complete('{"queries":["late"]}');
      await refresh;
      expect(container.read(recommendationsProvider).busy, isFalse);
      expect(
        container.read(recommendationsProvider).items.single.track.id,
        '2',
      );
    },
  );

  test(
    'configuration change cancels in-flight work and clears stale results',
    () async {
      container.listen(recommendationsProvider, (_, _) {});
      final controller = container.read(recommendationsProvider.notifier);
      final pending = client.pending = Completer<String>();
      final future = controller.generate(
        consent: testConsent,
        mood: 'night',
        useListening: false,
      );
      await container.read(aiSettingsProvider.notifier).clear();
      pending.complete('{"queries":["ambient"]}');
      await future;
      expect(container.read(recommendationsProvider).items, isEmpty);
      expect(container.read(recommendationsProvider).busy, isFalse);
      expect(container.read(aiSettingsProvider).hasSessionKey, isFalse);
    },
  );

  test('raw client errors are sanitized in observable state', () async {
    container.listen(recommendationsProvider, (_, _) {});
    client.failure = AiFailureForTest.transport;
    await container
        .read(recommendationsProvider.notifier)
        .generate(consent: testConsent, mood: 'night', useListening: false);
    expect(container.read(recommendationsProvider).error, AiFailure.network);
    expect(
      container.read(recommendationsProvider).error.toString(),
      isNot(contains('SESSION_SECRET')),
    );
  });

  test('retry failure retains the last successful result', () async {
    container.listen(recommendationsProvider, (_, _) {});
    final controller = container.read(recommendationsProvider.notifier);
    await controller.generate(
      consent: testConsent,
      mood: 'night',
      useListening: false,
    );
    final original = container.read(recommendationsProvider).items;
    client.failure = AiFailureForTest.transport;
    await controller.generate(
      consent: testConsent,
      mood: 'again',
      useListening: false,
    );
    expect(container.read(recommendationsProvider).items, same(original));
    expect(container.read(recommendationsProvider).error, AiFailure.network);
    expect(container.read(recommendationsProvider).busy, isFalse);
  });
}
