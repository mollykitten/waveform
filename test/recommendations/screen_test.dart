import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:waveform_app/app/theme/app_theme.dart';
import 'package:waveform_app/core/api/liked_tracks.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/api/soundcloud_auth.dart';
import 'package:waveform_app/core/audio/audio_engine.dart';
import 'package:waveform_app/core/log/talker.dart';
import 'package:waveform_app/core/recommendations/ai_config.dart';
import 'package:waveform_app/core/recommendations/providers.dart';
import 'package:waveform_app/core/recommendations/models.dart';
import 'package:waveform_app/features/player/player_controller.dart';
import 'package:waveform_app/features/recommendations/ai_settings_section.dart';
import 'package:waveform_app/features/recommendations/recommendations_screen.dart';
import 'package:waveform_app/shared/widgets/top_bar.dart';
import 'package:waveform_app/shared/widgets/track_row.dart';
import 'package:waveform_app/shared/widgets/pressable.dart';
import 'package:waveform_app/features/recommendations/widgets/wave_hero.dart';

import '../support/fake_audio_engine.dart';
import '../support/stub_liked_tracks.dart';
import 'support.dart';
import 'ui_test_support.dart';

void main() {
  late ProviderContainer container;
  late ScriptedAi client;
  late TestSoundcloud api;
  late WaveTestSettings settings;
  late FakeAudioEngine engine;
  var signedIn = false;

  setUp(() {
    signedIn = false;
    settings = WaveTestSettings();
    client = ScriptedAi();
    api = TestSoundcloud()
      ..tracks = List.generate(4, (i) => realTrack('${i + 1}'));
    client.replies[1] = jsonEncode({
      'recommendations': [
        for (final id in ['2', '1', '3', '4'])
          {'id': id, 'reason': 'a possible fit'},
      ],
    });
    engine = FakeAudioEngine();
    container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWithBuild(
          (ref, notifier) => SoundcloudAuth(
            clientId: 'ui-test',
            userToken: signedIn ? 'synthetic-test-account' : null,
          ),
        ),
        aiSettingsProvider.overrideWith(() => settings),
        aiListeningIdentityProvider.overrideWith(
          (ref) async => 'ui-test-profile',
        ),
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

  Future<void> show(
    WidgetTester tester, {
    Widget? child,
    Size size = const Size(1200, 1100),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(body: child ?? const RecommendationsScreen()),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> connect() =>
      container.read(aiSettingsProvider.notifier).connectChatGpt();

  Future<void> approve(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('wave-primary')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 2),
    );
    expect(find.text('make my wave personal'), findsOneWidget);
    await tester.tap(find.text('allow and play'));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 2),
    );
  }

  testWidgets('connect once without metadata or generation before play', (
    tester,
  ) async {
    await show(tester);
    expect(find.text('my wave'), findsOneWidget);
    expect(find.byType(WaveHero), findsOneWidget);
    expect(find.text('continue with ChatGPT'), findsOneWidget);
    expect(
      tester
          .widget<Pressable>(find.byKey(const ValueKey('wave-primary')))
          .enabled,
      isFalse,
    );
    expect(find.byType(TextField), findsNothing);
    settings.pendingConnect = Completer<void>();
    await tester.tap(find.text('continue with ChatGPT'));
    await tester.pump();
    expect(find.text('connecting…'), findsOneWidget);
    expect(api.likesCalls, 0);
    expect(api.historyCalls, 0);
    expect(client.payloads, isEmpty);
    settings.pendingConnect!.complete();
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 2),
    );
    expect(settings.connections, 1);
    expect(find.text('connected to ChatGPT'), findsOneWidget);
    expect(client.payloads, isEmpty);
    expect(find.text('continue with ChatGPT'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'declining consent sends no listening data and never starts playback',
    (tester) async {
      signedIn = true;
      await connect();
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('wave-primary')));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 2),
      );
      expect(api.likesCalls, 0);
      expect(api.historyCalls, 0);
      expect(client.payloads, isEmpty);
      await tester.tap(find.text('not now'));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 2),
      );
      expect(settings.consentChanges, 0);
      expect(client.payloads, isEmpty);
      expect(container.read(playerControllerProvider).track, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'one consent automatically uses listening/current track and plays real queue',
    (tester) async {
      signedIn = true;
      await connect();
      final current = realTrack('current');
      container.read(playerControllerProvider.notifier).play(current);
      client.replies[1] =
          '{"recommendations":[{"id":"1","reason":"first fit"},'
          '{"id":"2","reason":"another fit"},'
          '{"id":"3","reason":"another fit"},'
          '{"id":"4","reason":"another fit"}]}';
      await show(tester);
      await approve(tester);
      expect(settings.lastUseListening, isTrue);
      expect(settings.lastCurrentTrack, same(current));
      expect(api.likesCalls, 1);
      expect(api.historyCalls, 1);
      expect(settings.consentChanges, 1);
      expect(client.payloads, hasLength(2));
      final player = container.read(playerControllerProvider.notifier);
      expect(
        container.read(playerControllerProvider).track,
        same(api.tracks.first),
      );
      expect(player.upcomingTracks, api.tracks.skip(1).toList());
      expect(engine.lastLoadedUrl, 'https://play.invalid/stream.mp3');
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.byType(TextField), findsNothing);

      client.replies.addAll([
        '{"queries":["ambient"]}',
        jsonEncode({
          'recommendations': [
            for (final id in ['2', '1', '3', '4'])
              {'id': id, 'reason': 'a possible fit'},
          ],
        }),
      ]);
      await tester.tap(find.byKey(const ValueKey('wave-primary')));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 2),
      );
      expect(find.text('make my wave personal'), findsNothing);
      expect(settings.consentChanges, 1);
      expect(client.payloads, hasLength(4));
      expect(
        container.read(playerControllerProvider).track,
        same(api.tracks[1]),
      );
      await tester.pumpWidget(const SizedBox.shrink());

      // Re-entering the view reuses core consent rather than asking per visit.
      client.replies.addAll([
        '{"queries":["ambient"]}',
        jsonEncode({
          'recommendations': [
            for (final id in ['1', '2', '3', '4'])
              {'id': id, 'reason': 'a possible fit'},
          ],
        }),
      ]);
      await show(tester);
      expect(client.payloads, hasLength(4));
      await tester.tap(find.byKey(const ValueKey('wave-primary')));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 2),
      );
      expect(find.text('make my wave personal'), findsNothing);
      expect(settings.consentChanges, 1);
      expect(client.payloads, hasLength(6));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('optional mood stays unobtrusive and is sent only after play', (
    tester,
  ) async {
    await connect();
    await show(tester);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('tune your wave'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('wave-mood')),
      'quiet evening',
    );
    expect(client.payloads, isEmpty);
    await approve(tester);
    expect(jsonDecode(client.payloads.first)['mood'], 'quiet evening');
    expect(settings.lastUseListening, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'destination change revokes approval and discards the old dialog',
    (tester) async {
      await connect();
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('wave-primary')));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 2),
      );
      const custom = AiConfig(
        backend: AiBackend.openAi,
        endpoint: 'https://custom.example/v1',
        model: 'test-model',
      );
      await settings.save(custom);
      await tester.tap(find.text('allow and play'));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 2),
      );
      expect(client.payloads, isEmpty);
      await tester.tap(find.byKey(const ValueKey('wave-primary')));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 2),
      );
      expect(find.text('sent to ${custom.destination}'), findsOneWidget);
      await tester.tap(find.text('not now'));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 2),
      );
      expect(
        container.read(aiSettingsProvider).config.listeningConsent,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    '960x640 supports connection, consent and result queue without overflow',
    (tester) async {
      await connect();
      await show(
        tester,
        size: const Size(960, 640),
        child: const Stack(
          children: [
            RecommendationsScreen(),
            Align(
              alignment: Alignment.topCenter,
              child: TopBar(location: '/recommendations'),
            ),
          ],
        ),
      );
      expect(tester.takeException(), isNull);
      await approve(tester);
      await tester.scrollUntilVisible(
        find.byType(TrackRow).first,
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byType(TrackRow), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('advanced provider fields are collapsed by default', (
    tester,
  ) async {
    await show(
      tester,
      size: const Size(960, 640),
      child: const SingleChildScrollView(
        child: Center(child: SizedBox(width: 640, child: AiSettingsSection())),
      ),
    );
    expect(find.text('continue with ChatGPT'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('advanced settings'));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 2),
    );
    expect(find.widgetWithText(TextField, 'endpoint base URL'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'model name'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'pending custom clear serializes edits/save and survives view disposal',
    (tester) async {
      await connect();
      await show(
        tester,
        child: const SingleChildScrollView(child: AiSettingsSection()),
      );
      await tester.tap(find.text('advanced settings'));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 2),
      );
      final endpoint = find.widgetWithText(TextField, 'endpoint base URL');
      final model = find.widgetWithText(TextField, 'model name');
      await tester.enterText(endpoint, 'https://custom.example/v1');
      await tester.enterText(model, 'custom-model');
      await tester.enterText(
        find.byType(TextField).last,
        'UI_TEST_SESSION_KEY',
      );
      await tester.tap(find.text('save custom provider'));
      await tester.pump();
      expect(container.read(aiSettingsProvider).hasSessionKey, isTrue);
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        isEmpty,
      );
      settings.pendingWrite = Completer<void>();
      await tester.tap(find.text('clear custom settings'));
      await tester.pump();
      expect(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .every((field) => field.enabled == false),
        isTrue,
      );
      expect(
        tester
            .widget<Pressable>(
              find.widgetWithText(Pressable, 'save custom provider'),
            )
            .onTap,
        isNull,
      );
      for (final label in ['OpenAI-compatible', 'Ollama (native)']) {
        expect(
          tester
              .widget<Pressable>(find.widgetWithText(Pressable, label))
              .enabled,
          isFalse,
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
      settings.pendingWrite!.complete();
      await tester.pump();
      expect(
        container.read(aiSettingsProvider).config.backend,
        AiBackend.chatGpt,
      );
      expect(container.read(aiSettingsProvider).hasSessionKey, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('account switch is available inside advanced settings', (
    tester,
  ) async {
    await connect();
    await show(
      tester,
      child: const SingleChildScrollView(child: AiSettingsSection()),
    );
    expect(find.text('use another ChatGPT account'), findsNothing);
    await tester.tap(find.text('advanced settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('use another ChatGPT account'));
    await tester.tap(find.text('use another ChatGPT account'));
    await tester.pumpAndSettle();
    expect(settings.usedNewAccount, isTrue);
    expect(settings.connections, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'denied reconnect stays visible for an already connected account',
    (tester) async {
      settings = WaveTestSettings(
        initial: const AiSettingsState(
          ready: true,
          config: AiConfig(backend: AiBackend.chatGpt),
          chatGptConnected: true,
          error: AiFailure.credentials,
        ),
      )..connectionFailure = AiFailure.credentials;
      await show(tester);
      expect(
        find.textContaining('ChatGPT access expired or was denied'),
        findsOneWidget,
      );
      await tester.tap(find.text('reconnect ChatGPT'));
      await tester.pumpAndSettle();
      expect(settings.connections, 1);
      expect(container.read(aiSettingsProvider).chatGptConnected, isTrue);
      expect(
        find.textContaining('ChatGPT access expired or was denied'),
        findsOneWidget,
      );
      expect(find.text('reconnect ChatGPT'), findsOneWidget);
      expect(find.textContaining('session key'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('malformed result shows safe retry and leaves player alone', (
    tester,
  ) async {
    await connect();
    client.replies[0] = 'PRIVATE raw model error';
    await show(tester);
    await approve(tester);
    expect(
      find.textContaining('invalid recommendation response'),
      findsOneWidget,
    );
    expect(find.text('try again'), findsOneWidget);
    expect(find.textContaining('PRIVATE'), findsNothing);
    expect(container.read(playerControllerProvider).track, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'wave refills after screen disposal and continues beyond two batches',
    (tester) async {
      await connect();
      api.tracks = List.generate(16, (i) => realTrack('${i + 1}'));
      client.replies.clear();
      for (var batch = 0; batch < 4; batch++) {
        client.replies.add('{"queries":["ambient"]}');
        client.replies.add(
          jsonEncode({
            'recommendations': [
              for (var index = 0; index < 4; index++)
                {'id': '${batch * 4 + index + 1}', 'reason': 'a possible fit'},
            ],
          }),
        );
      }
      await show(tester);
      expect(client.payloads, isEmpty);
      await approve(tester);
      expect(client.payloads, hasLength(2));
      await tester.pumpWidget(const SizedBox.shrink());
      final player = container.read(playerControllerProvider.notifier);
      for (var i = 0; i < 10; i++) {
        player.next();
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 2),
        );
      }
      expect(client.payloads, hasLength(8));
      expect(container.read(recommendationsProvider).items, hasLength(16));
      player.toggle();
      player.toggle();
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 2),
      );
      expect(client.payloads, hasLength(8));
      expect(find.text('make my wave personal'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
