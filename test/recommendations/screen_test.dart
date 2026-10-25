import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:waveform_app/app/theme/app_theme.dart';
import 'package:waveform_app/app/theme/colors.dart';
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
import 'package:waveform_app/features/recommendations/widgets/wave_hero.dart';
import 'package:waveform_app/shared/widgets/pressable.dart';
import 'package:waveform_app/shared/widgets/track_row.dart';
import 'package:waveform_app/shared/widgets/top_bar.dart';

import '../support/fake_audio_engine.dart';
import '../support/stub_liked_tracks.dart';
import 'support.dart';
import 'visual_test_fonts.dart';

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
  setUpAll(installVisualTestFonts);
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
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(body: child ?? const RecommendationsScreen()),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> captureWave(WidgetTester tester, Size size, bool tune) async {
    await container.read(aiSettingsProvider.notifier).save(testConfig);
    const capture = ValueKey('wave-capture');
    await show(
      tester,
      size: size,
      child: const RepaintBoundary(
        key: capture,
        child: ColoredBox(color: AppColors.bg, child: RecommendationsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() => GoogleFonts.pendingFonts());
    await tester.pump();
    final heroSize = tester.getSize(find.byType(WaveHero));
    expect(heroSize.height, 400);
    expect(heroSize.width, lessThanOrEqualTo(880));
    expect(find.byType(TextField), findsNothing);
    if (tune) {
      await tester.tap(find.text('tune your wave'));
      await tester.pumpAndSettle();
      // Capture the real scroll position needed to expose the complete shelf.
      await tester.ensureVisible(find.text('model connection'));
      await tester.pumpAndSettle();
      expect(
        find.text('listening history · off').hitTestable(),
        findsOneWidget,
      );
      expect(find.text('current track · off').hitTestable(), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(capture),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      expect(image.width, size.width.toInt());
      expect(image.height, size.height.toInt());
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final folder = await Directory(
        'build/visual-review',
      ).create(recursive: true);
      await File(
        '${folder.path}/wave-${tune ? 'tune-open' : 'idle'}-'
        '${size.width.toInt()}x${size.height.toInt()}.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.pumpWidget(const SizedBox.shrink());
  }

  for (final size in [const Size(1280, 720), const Size(960, 640)]) {
    for (final tune in [false, true]) {
      testWidgets('wave capture ${tune ? 'tune open' : 'idle'} '
          '${size.width.toInt()}x${size.height.toInt()}', (tester) async {
        await captureWave(tester, size, tune);
      });
    }
  }

  testWidgets('unconfigured state is explicit and never calls model', (
    tester,
  ) async {
    await show(tester);
    expect(find.text('configure your wave'), findsOneWidget);
    expect(find.text('my wave'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
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
    final actionsLocked =
        [
              'OpenAI-compatible',
              'Ollama (native)',
              'save AI settings',
              'clear AI settings and key',
            ]
            .map(
              (label) => tester.widget<Pressable>(
                find.widgetWithText(Pressable, label),
              ),
            )
            .every((button) => !button.enabled || button.onTap == null);
    final save = tester.widget<Pressable>(
      find.widgetWithText(Pressable, 'save AI settings'),
    );
    // Attempt the reported overlap whenever the UI mistakenly permits it.
    if (!fieldsLocked && save.enabled && save.onTap != null) {
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
    expect(save.enabled, isFalse);
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
    await tester.tap(find.byKey(const ValueKey('wave-primary')));
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
    await tester.tap(find.text('tune your wave'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'quiet night');
    await tester.tap(find.byKey(const ValueKey('wave-primary')));
    await tester.pumpAndSettle();
    expect(find.text(testConfig.destination), findsOneWidget);
    expect(find.textContaining('up to 40 public SoundCloud'), findsOneWidget);
    expect(client.payloads, isEmpty);
    await tester.tap(find.text('cancel'));
    await tester.pumpAndSettle();
    expect(client.payloads, isEmpty);
    await tester.tap(find.byKey(const ValueKey('wave-primary')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('approve and generate'));
    await tester.pumpAndSettle();
    expect(find.byType(TrackRow), findsOneWidget);
    expect(find.text('model suggestion: a possible fit'), findsOneWidget);
    final track = tester.widget<TrackRow>(find.byType(TrackRow)).track;
    expect(container.read(playerControllerProvider).track, isNull);
    await tester.tap(find.byKey(const ValueKey('wave-primary')));
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
    await tester.tap(find.byKey(const ValueKey('wave-primary')));
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

  testWidgets('empty real selection offers retry without invented tracks', (
    tester,
  ) async {
    await container.read(aiSettingsProvider.notifier).save(testConfig);
    client.replies[1] = '{"recommendations":[]}';
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('wave-primary')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('approve and generate'));
    await tester.pumpAndSettle();
    expect(find.text('retry with approval'), findsOneWidget);
    expect(find.byType(TrackRow), findsNothing);
    expect(container.read(playerControllerProvider).track, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('tuning presets change the actual request; history stays off', (
    tester,
  ) async {
    await container.read(aiSettingsProvider.notifier).save(testConfig);
    await show(tester);
    await tester.tap(find.text('tune your wave'));
    await tester.pump();
    await tester.tap(find.text('focus without vocals'));
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'focus without vocals',
    );
    expect(find.text('listening history · off'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsNothing);
    await tester.tap(find.byKey(const ValueKey('wave-primary')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('recent likes and listening history:'),
      findsNothing,
    );
    await tester.tap(find.text('approve and generate'));
    await tester.pumpAndSettle();
    expect(client.payloads.first, contains('focus without vocals'));
    expect(container.read(playerControllerProvider).track, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('hero pauses hidden and responds to reduced motion dynamically', (
    tester,
  ) async {
    var reduced = false;
    var visible = true;
    late StateSetter update;
    await show(
      tester,
      child: StatefulBuilder(
        builder: (context, setState) {
          update = setState;
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
            child: TickerMode(
              enabled: visible,
              child: WaveHero(
                description: 'test wave',
                actionLabel: 'play',
                onPlay: () {},
                onTune: () {},
              ),
            ),
          );
        },
      ),
    );
    final paint =
        tester
                .widget<CustomPaint>(
                  find.descendant(
                    of: find.byType(WaveHero),
                    matching: find.byType(CustomPaint),
                  ),
                )
                .painter
            as WaveRibbonPainter;
    await tester.pump(const Duration(seconds: 2));
    expect(paint.phase.value, greaterThan(0));
    update(() => visible = false);
    await tester.pump();
    final paused = paint.phase.value;
    await tester.pump(const Duration(seconds: 2));
    expect(paint.phase.value, paused);
    update(() {
      visible = true;
      reduced = true;
    });
    await tester.pump();
    expect(paint.phase.value, 0);
    await tester.pump(const Duration(seconds: 2));
    expect(paint.phase.value, 0);
    update(() => reduced = false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(paint.phase.value, greaterThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('primary play hands the complete real result queue to player', (
    tester,
  ) async {
    await container.read(aiSettingsProvider.notifier).save(testConfig);
    client.replies[1] =
        '{"recommendations":[{"id":"2","reason":"first"},'
        '{"id":"1","reason":"next"}]}';
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('wave-primary')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('approve and generate'));
    await tester.pumpAndSettle();
    final result = container.read(recommendationsProvider);
    expect(result.items.length, 2);
    expect(container.read(playerControllerProvider).track, isNull);
    await tester.tap(find.byKey(const ValueKey('wave-primary')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      container.read(playerControllerProvider).track,
      same(result.items.first.track),
    );
    expect(
      container
          .read(playerControllerProvider.notifier)
          .upcomingTracks
          .map((track) => track.id),
      contains('1'),
    );
    expect(engine.lastLoadedUrl, 'https://play.invalid/stream.mp3');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cancel busy refresh keeps old results without playing them', (
    tester,
  ) async {
    await container.read(aiSettingsProvider.notifier).save(testConfig);
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('wave-primary')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('approve and generate'));
    await tester.pumpAndSettle();
    final oldItems = container.read(recommendationsProvider).items;
    final playing = realTrack('already-playing');
    container
        .read(playerControllerProvider.notifier)
        .play(playing, queue: [playing]);
    await tester.pump(const Duration(milliseconds: 500));
    client.pending = Completer<String>();
    await tester.tap(find.text('refresh selection'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('approve and generate'));
    await tester.pumpAndSettle();
    expect(container.read(recommendationsProvider).busy, isTrue);
    expect(container.read(playerControllerProvider).track, same(playing));
    final chosenWhileBusy = realTrack('chosen-while-busy');
    container
        .read(playerControllerProvider.notifier)
        .play(chosenWhileBusy, queue: [chosenWhileBusy]);
    await tester.pump(const Duration(milliseconds: 500));
    final primary = tester.widget<Pressable>(
      find.byKey(const ValueKey('wave-primary')),
    );
    expect(primary.enabled, isFalse);
    await tester.tap(find.text('cancel generation'));
    await tester.pumpAndSettle();
    client.pending!.complete('{"queries":["ignored"]}');
    await tester.pumpAndSettle();
    expect(container.read(recommendationsProvider).items, same(oldItems));
    expect(container.read(recommendationsProvider).busy, isFalse);
    expect(container.read(recommendationsProvider).error, isNull);
    expect(
      container.read(playerControllerProvider).track,
      same(chosenWhileBusy),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'successful generation never interrupts music chosen while busy',
    (tester) async {
      await container.read(aiSettingsProvider.notifier).save(testConfig);
      final pending = client.pending = Completer<String>();
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('wave-primary')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('approve and generate'));
      await tester.pumpAndSettle();
      final chosen = realTrack('chosen-while-selecting');
      container
          .read(playerControllerProvider.notifier)
          .play(chosen, queue: [chosen]);
      await tester.pump(const Duration(milliseconds: 500));
      client.pending = null;
      client.replies.removeAt(0);
      pending.complete('{"queries":["ambient"]}');
      await tester.pumpAndSettle();
      expect(container.read(recommendationsProvider).items, isNotEmpty);
      expect(container.read(playerControllerProvider).track, same(chosen));
      expect(find.text('refresh selection'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

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
