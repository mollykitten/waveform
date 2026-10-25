import 'dart:async';

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
import 'package:waveform_app/features/player/player_controller.dart';
import 'package:waveform_app/features/recommendations/ai_settings_section.dart';
import 'package:waveform_app/features/recommendations/recommendations_screen.dart';
import 'package:waveform_app/shared/widgets/track_row.dart';
import 'package:waveform_app/shared/widgets/top_bar.dart';

import '../support/fake_audio_engine.dart';
import '../support/stub_liked_tracks.dart';
import 'support.dart';

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

void main() {
  late ProviderContainer container;
  late ScriptedAi client;
  late FakeAudioEngine engine;
  late MemoryConfigStore store;

  setUp(() async {
    client = ScriptedAi();
    engine = FakeAudioEngine();
    store = MemoryConfigStore();
    container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWithBuild(
          (ref, notifier) => const SoundcloudAuth(clientId: 'test'),
        ),
        aiConfigStoreProvider.overrideWithValue(store),
        aiClientProvider.overrideWithValue(client),
        soundcloudApiProvider.overrideWithValue(TestSoundcloud()),
        audioEngineProvider.overrideWithValue(engine),
        likedTracksProvider.overrideWith(StubLikedTracks.new),
        talkerProvider.overrideWithValue(Talker()),
      ],
    );
    container.listen(aiSettingsProvider, (_, _) {});
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  tearDown(() async {
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
          home: Scaffold(body: child ?? const RecommendationsScreen()),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('unconfigured state is explicit and never calls model', (
    tester,
  ) async {
    await show(tester);
    expect(find.text('configure your model first'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
    expect(client.payloads, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final clear in [false, true]) {
    testWidgets('leaving settings during ${clear ? 'clear' : 'save'} is safe', (
      tester,
    ) async {
      await container.read(aiSettingsProvider.notifier).save(testConfig);
      await show(
        tester,
        child: const SingleChildScrollView(child: AiSettingsSection()),
      );
      store.pending = Completer<void>();
      await tester.tap(
        find.text(clear ? 'clear AI settings and key' : 'save AI settings'),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      store.pending!.complete();
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('pending clear cannot race with replacement edits and save', (
    tester,
  ) async {
    await container.read(aiSettingsProvider.notifier).save(testConfig);
    await show(
      tester,
      child: const SingleChildScrollView(child: AiSettingsSection()),
    );
    final endpoint = find.widgetWithText(TextField, 'endpoint base URL');
    final model = find.widgetWithText(TextField, 'model name');
    store.pending = Completer<void>();
    await tester.tap(find.text('clear AI settings and key'));
    await tester.pump();
    final fieldsLocked = tester
        .widgetList<TextField>(find.byType(TextField))
        .every((field) => field.enabled == false);
    final actionsLocked = tester
        .widgetList<TextButton>(find.byType(TextButton))
        .every((button) => button.onPressed == null);
    final protocolLocked =
        tester
            .widget<DropdownButtonFormField<AiBackend>>(
              find.byType(DropdownButtonFormField<AiBackend>),
            )
            .onChanged ==
        null;
    final save = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'save AI settings'),
    );
    // Attempt the reported overlap whenever the UI mistakenly permits it.
    if (!fieldsLocked && save.onPressed != null) {
      await tester.enterText(endpoint, 'https://replacement.example/v1');
      await tester.enterText(model, 'replacement');
      await tester.enterText(
        find.byType(TextField).last,
        'REPLACEMENT_TEST_KEY',
      );
      await tester.tap(find.text('save AI settings'));
      await tester.pump();
    }
    store.pending!.complete();
    await tester.pump();
    expect(
      container.read(aiSettingsProvider).config.isValid,
      isFalse,
      reason:
          'clear must not report success while an overlapping save stays active',
    );
    expect(fieldsLocked, isTrue);
    expect(actionsLocked, isTrue);
    expect(protocolLocked, isTrue);
    expect(save.onPressed, isNull);
    expect(tester.widget<TextField>(endpoint).controller!.text, isEmpty);
    store.pending = null;
    await tester.enterText(endpoint, 'https://replacement.example/v1');
    await tester.enterText(model, 'replacement');
    await tester.tap(find.text('save AI settings'));
    await tester.pump();
    expect(
      container.read(aiSettingsProvider).config.endpoint,
      'https://replacement.example/v1',
    );
    expect(
      tester.widget<TextField>(endpoint).controller!.text,
      'https://replacement.example/v1',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('discover navigation fits the minimum desktop width', (
    tester,
  ) async {
    await show(
      tester,
      child: const Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 960,
          child: TopBar(location: '/recommendations'),
        ),
      ),
    );
    expect(find.text('discover'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('960x640 supports approval, results and discover navigation', (
    tester,
  ) async {
    await container.read(aiSettingsProvider.notifier).save(testConfig);
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
    await tester.enterText(find.byType(TextField), 'quiet evening');
    await tester.scrollUntilVisible(
      find.text('generate recommendations'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('generate recommendations'));
    await tester.pumpAndSettle();
    expect(find.text(testConfig.destination), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('approve and generate'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byType(TrackRow),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('model suggestion: a possible fit'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('AI configuration fits the 960x640 desktop viewport', (
    tester,
  ) async {
    await show(
      tester,
      size: const Size(960, 640),
      child: const SingleChildScrollView(
        child: Center(child: SizedBox(width: 640, child: AiSettingsSection())),
      ),
    );
    await tester.scrollUntilVisible(
      find.text('save AI settings'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cancel approval sends nothing; approved real results play', (
    tester,
  ) async {
    await container.read(aiSettingsProvider.notifier).save(testConfig);
    await show(tester);
    await tester.enterText(find.byType(TextField), 'quiet night');
    await tester.tap(find.text('generate recommendations'));
    await tester.pumpAndSettle();
    expect(find.text(testConfig.destination), findsOneWidget);
    expect(find.textContaining('up to 40 public SoundCloud'), findsOneWidget);
    expect(client.payloads, isEmpty);
    await tester.tap(find.text('cancel'));
    await tester.pumpAndSettle();
    expect(client.payloads, isEmpty);
    await tester.tap(find.text('generate recommendations'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('approve and generate'));
    await tester.pumpAndSettle();
    expect(find.byType(TrackRow), findsOneWidget);
    expect(find.text('model suggestion: a possible fit'), findsOneWidget);
    final track = tester.widget<TrackRow>(find.byType(TrackRow)).track;
    await tester.tap(
      find
          .descendant(
            of: find.byType(TrackRow),
            matching: find.byIcon(Icons.play_arrow),
          )
          .first,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(container.read(playerControllerProvider).track, same(track));
    expect(container.read(playerControllerProvider).isPlaying, isTrue);
    expect(engine.lastLoadedUrl, 'https://play.invalid/stream.mp3');
    expect(client.payloads.length, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('malformed model output shows safe retry state', (tester) async {
    await container.read(aiSettingsProvider.notifier).save(testConfig);
    client.replies[0] = 'SECRET model stack trace';
    await show(tester);
    await tester.enterText(find.byType(TextField), 'night');
    await tester.tap(find.text('generate recommendations'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('approve and generate'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('invalid recommendation response'),
      findsOneWidget,
    );
    expect(find.text('retry with approval'), findsOneWidget);
    expect(find.byType(TrackRow), findsNothing);
    expect(find.textContaining('SECRET'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('settings save session key, revoke consent and clear', (
    tester,
  ) async {
    await show(
      tester,
      child: const SingleChildScrollView(child: AiSettingsSection()),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'endpoint base URL'),
      testConfig.endpoint,
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'model name'),
      'model',
    );
    await tester.enterText(find.byType(TextField).last, 'SESSION_SECRET');
    await tester.tap(find.text('save AI settings'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(container.read(aiSettingsProvider).hasSessionKey, isTrue);
    expect(
      tester.widget<TextField>(find.byType(TextField).last).controller!.text,
      isEmpty,
    );
    await tester.runAsync(
      () =>
          container.read(aiSettingsProvider.notifier).setListeningConsent(true),
    );
    await tester.pump();
    await tester.tap(find.text('revoke listening metadata consent'));
    await tester.pump();
    expect(container.read(aiSettingsProvider).config.listeningConsent, isFalse);
    await tester.tap(find.text('clear AI settings and key'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(container.read(aiSettingsProvider).config.isValid, isFalse);
    expect(container.read(aiSettingsProvider).hasSessionKey, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
