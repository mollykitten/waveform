import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:waveform_app/core/api/liked_tracks.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/api/soundcloud_auth.dart';
import 'package:waveform_app/core/audio/audio_engine.dart';
import 'package:waveform_app/core/log/talker.dart';
import 'package:waveform_app/core/recommendations/ai_config.dart';
import 'package:waveform_app/core/recommendations/providers.dart';
import 'package:waveform_app/features/player/player_controller.dart';
import 'package:waveform_app/features/recommendations/wave_controller.dart';

import '../support/fake_audio_engine.dart';
import '../support/stub_liked_tracks.dart';
import 'support.dart';
import 'ui_test_support.dart';

void main() {
  late ProviderContainer container;
  late WaveTestSettings settings;
  late ScriptedAi client;
  late TestSoundcloud api;
  late FakeAudioEngine engine;
  Future<void> flush() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  void batch(List<String> ids) {
    client.replies.addAll([
      '{"queries":["ambient"]}',
      jsonEncode({
        'recommendations': [
          for (final id in ids) {'id': id, 'reason': 'a possible fit'},
        ],
      }),
    ]);
  }

  setUp(() {
    settings = WaveTestSettings(
      initial: const AiSettingsState(
        ready: true,
        chatGptConnected: true,
        config: AiConfig(backend: AiBackend.chatGpt, listeningConsent: true),
      ),
    );
    client = ScriptedAi()..replies.clear();
    api = TestSoundcloud()
      ..tracks = List.generate(12, (i) => realTrack('${i + 1}'));
    engine = FakeAudioEngine();
    container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWithBuild(
          (ref, notifier) => const SoundcloudAuth(clientId: 'test'),
        ),
        aiSettingsProvider.overrideWith(() => settings),
        aiListeningIdentityProvider.overrideWith((ref) async => 'test-profile'),
        aiClientProvider.overrideWithValue(client),
        soundcloudApiProvider.overrideWithValue(api),
        audioEngineProvider.overrideWithValue(engine),
        likedTracksProvider.overrideWith(StubLikedTracks.new),
        talkerProvider.overrideWithValue(Talker()),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    engine.dispose();
  });

  test('a late initial result cannot replace a newly selected track', () async {
    final pending = Completer<String>();
    client.pending = pending;
    final request = container
        .read(waveControllerProvider.notifier)
        .start('ambient');
    await flush();
    final other = realTrack('other');
    container.read(playerControllerProvider.notifier).play(other);
    client.pending = null;
    client.replies.add('{"recommendations":[{"id":"1","reason":"fit"}]}');
    pending.complete('{"queries":["ambient"]}');
    await request;
    await flush();
    expect(container.read(playerControllerProvider).track, same(other));
    expect(container.read(waveControllerProvider).active, isFalse);
    expect(
      container.read(playerControllerProvider.notifier).upcomingTracks,
      isEmpty,
    );
  });

  test(
    'one initial result prefetches one unique batch without a refill loop',
    () async {
      batch(['1']);
      batch(['2', '3', '4']);
      await container.read(waveControllerProvider.notifier).start('ambient');
      await flush();
      expect(client.payloads, hasLength(4));
      expect(container.read(playerControllerProvider).track?.id, '1');
      expect(
        container
            .read(playerControllerProvider.notifier)
            .upcomingTracks
            .map((t) => t.id),
        ['2', '3', '4'],
      );
      expect(container.read(waveControllerProvider).active, isTrue);
      await flush();
      expect(client.payloads, hasLength(4));
    },
  );

  test(
    'late refill cannot append to an unrelated queue even with a wave current track',
    () async {
      batch(['1', '2', '3', '4']);
      await container.read(waveControllerProvider.notifier).start('ambient');
      final pending = Completer<String>();
      client.pending = pending;
      final player = container.read(playerControllerProvider.notifier);
      player.next();
      await flush();
      expect(container.read(waveControllerProvider).discovering, isTrue);
      player.play(api.tracks[1], queue: [api.tracks[1], realTrack('outside')]);
      client.pending = null;
      pending.complete('{"queries":["ambient"]}');
      await flush();
      expect(player.upcomingTracks.map((t) => t.id), ['outside']);
      expect(container.read(waveControllerProvider).active, isFalse);
    },
  );

  test('no new candidates stops the wave with no repeated requests', () async {
    batch(['1', '2', '3', '4']);
    batch(['1']);
    await container.read(waveControllerProvider.notifier).start('ambient');
    final player = container.read(playerControllerProvider.notifier);
    player.next();
    await flush();
    expect(container.read(waveControllerProvider).active, isFalse);
    final count = client.payloads.length;
    for (var i = 0; i < 8; i++) {
      player.next();
      await flush();
    }
    expect(client.payloads, hasLength(count));
    expect(
      container
          .read(recommendationsProvider)
          .items
          .map((i) => i.track.id)
          .toSet(),
      hasLength(4),
    );
  });

  for (final change in ['disconnect', 'config', 'logout', 'cancel']) {
    test(
      '$change aborts a pending refill and does not change the queue',
      () async {
        batch(['1', '2', '3', '4']);
        await container.read(waveControllerProvider.notifier).start('ambient');
        final pending = Completer<String>();
        client.pending = pending;
        final player = container.read(playerControllerProvider.notifier);
        player.next();
        await flush();
        switch (change) {
          case 'disconnect':
            await settings.disconnectChatGpt();
          case 'config':
            await settings.save(testConfig);
          case 'logout':
            container.invalidate(authControllerProvider);
            await flush();
          case 'cancel':
            container.read(waveControllerProvider.notifier).cancel();
        }
        final queued = player.upcomingTracks.map((t) => t.id).toList();
        client.pending = null;
        pending.complete('{"queries":["ambient"]}');
        await flush();
        expect(container.read(waveControllerProvider).active, isFalse);
        expect(container.read(waveControllerProvider).discovering, isFalse);
        expect(player.upcomingTracks.map((t) => t.id), queued);
      },
    );
  }
}
