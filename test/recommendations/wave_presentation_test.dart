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
import 'package:waveform_app/core/recommendations/chatgpt_auth.dart';
import 'package:waveform_app/core/recommendations/providers.dart';
import 'package:waveform_app/features/recommendations/recommendations_screen.dart';
import 'package:waveform_app/features/recommendations/widgets/wave_hero.dart';

import '../support/fake_audio_engine.dart';
import '../support/stub_liked_tracks.dart';
import 'support.dart';
import 'visual_test_fonts.dart';

class NoChatGpt extends ChatGptAuth {
  @override
  Future<void> restore() async {}
}

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
        chatGptAuthProvider.overrideWithValue(NoChatGpt()),
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
    Key? captureKey,
    Size size = const Size(1200, 1100),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.dark,
            home: MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: Scaffold(body: child ?? const RecommendationsScreen()),
            ),
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
      expect(find.byKey(const ValueKey('wave-mood')), findsOneWidget);
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
    testWidgets(
      'consent capture ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        await container.read(aiSettingsProvider.notifier).save(testConfig);
        const capture = ValueKey('consent-capture');
        await show(tester, size: size, captureKey: capture);
        await tester.tap(find.byKey(const ValueKey('wave-primary')));
        await tester.pumpAndSettle();
        await tester.runAsync(() => GoogleFonts.pendingFonts());
        await tester.pump();
        expect(find.text('sent to ${testConfig.destination}'), findsOneWidget);
        expect(find.text('allow and play').hitTestable(), findsOneWidget);
        expect(client.payloads, isEmpty);
        expect(tester.takeException(), isNull);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(capture),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('build/visual-review').create(recursive: true);
          await File(
            'build/visual-review/wave-consent-'
            '${size.width.toInt()}x${size.height.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.tap(find.text('not now'));
        await tester.pumpAndSettle();
        expect(client.payloads, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      skip: !waveVisualCaptureEnabled,
    );
    for (final tune in [false, true]) {
      testWidgets('wave capture ${tune ? 'tune open' : 'idle'} '
          '${size.width.toInt()}x${size.height.toInt()}', (tester) async {
        await captureWave(tester, size, tune);
      }, skip: !waveVisualCaptureEnabled);
    }
  }

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
}
