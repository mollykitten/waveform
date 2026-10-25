import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
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
import 'package:waveform_app/core/recommendations/models.dart';
import 'package:waveform_app/features/player/player_controller.dart';
import 'package:waveform_app/features/recommendations/wave_controller.dart';
import 'package:waveform_app/shared/models/track.dart';
import 'package:waveform_app/shared/providers/waveform_samples.dart';
import 'package:waveform_app/features/recommendations/recommendations_screen.dart';
import 'package:waveform_app/features/recommendations/widgets/wave_hero.dart';
import 'package:waveform_app/shared/widgets/form_controls.dart';

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

class _PlaybackSpy extends PlayerController {
  _PlaybackSpy(this.current, {this.foreign = false});
  final Track current;
  final bool foreign;
  int toggles = 0;
  void advance(int milliseconds) =>
      state = state.copyWith(position: Duration(milliseconds: milliseconds));
  @override
  PlayerState build() => PlayerState(
    track: foreign ? realTrack('foreign') : current,
    isPlaying: true,
  );
  @override
  List<Track> get upcomingTracks => [realTrack('next')];
  @override
  void toggle() {
    toggles++;
    state = state.copyWith(isPlaying: !state.isPlaying);
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
    double scale = 1,
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
              data: MediaQueryData(
                size: size,
                textScaler: TextScaler.linear(scale),
                disableAnimations: true,
              ),
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
    expect(heroSize.height, inInclusiveRange(280, 400));
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

  for (final size in [const Size(960, 640), const Size(1280, 720)]) {
    for (final scale in [1.0, 1.5]) {
      testWidgets('discover tuning ${size.width} scale $scale', (tester) async {
        await container.read(aiSettingsProvider.notifier).save(testConfig);
        await show(tester, size: size, scale: scale);
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byType(WaveHero)).height,
          lessThanOrEqualTo(400),
        );
        await tester.tap(find.text('tune your wave'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const ValueKey('wave-mood')));
        await tester.enterText(
          find.byKey(const ValueKey('wave-mood')),
          'a long quiet evening with something new',
        );
        expect(
          tester.getSize(find.byKey(const ValueKey('wave-mood'))).width,
          lessThanOrEqualTo(584),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  for (final refill in [false, true]) {
    testWidgets(
      'owned wave toggles playback without regeneration refill $refill',
      (tester) async {
        final track = realTrack('owned');
        final player = _PlaybackSpy(track);
        container.dispose();
        container = ProviderContainer(
          overrides: [
            aiSettingsProvider.overrideWithBuild(
              (ref, notifier) =>
                  const AiSettingsState(ready: true, config: testConfig),
            ),
            recommendationsProvider.overrideWithBuild(
              (ref, notifier) => RecommendationState(
                items: [
                  Recommendation(track, 'same real reason'),
                  Recommendation(realTrack('next'), 'same real reason'),
                ],
                busy: refill,
              ),
            ),
            waveControllerProvider.overrideWithBuild(
              (ref, notifier) => WaveState(active: true, discovering: refill),
            ),
            playerControllerProvider.overrideWith(() => player),
            authControllerProvider.overrideWithBuild(
              (ref, notifier) => const SoundcloudAuth(clientId: 'test'),
            ),
          ],
        );
        await show(
          tester,
          size: refill ? const Size(1280, 720) : const Size(960, 640),
          captureKey: const ValueKey('playing-capture'),
        );
        final primary = find.byKey(const ValueKey('wave-primary'));
        expect(
          find.descendant(
            of: primary,
            matching: find.byIcon(Icons.pause_rounded),
          ),
          findsOneWidget,
        );
        await tester.tap(primary);
        await tester.pump();
        expect(player.toggles, 1);
        expect(container.read(playerControllerProvider).isPlaying, isFalse);
        expect(
          container
              .read(recommendationsProvider)
              .items
              .map((item) => item.track.id),
          ['owned', 'next'],
        );
        expect(client.payloads, isEmpty);
        await tester.tap(primary);
        await tester.pump();
        expect(player.toggles, 2);
        expect(
          tester
              .widgetList<WaveQueueRow>(find.byType(WaveQueueRow))
              .map((row) => row.track.id),
          ['owned', 'next'],
        );
        expect(find.text('same real reason'), findsOneWidget);
        if (waveVisualCaptureEnabled) {
          await tester.ensureVisible(
            find.byKey(const ValueKey('wave-row-owned')),
          );
          await tester.pump();
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('playing-capture')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              'build/visual-review/after-wave-queue-${refill ? '1280' : '960'}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        expect(container.read(playerControllerProvider).isPlaying, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final useToggle in [false, true]) {
    testWidgets('paused wave rereads shuffle order toggle $useToggle', (
      tester,
    ) async {
      final tracks = List.generate(4, (i) => realTrack('${i + 1}'));
      container.dispose();
      container = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWithBuild(
            (ref, notifier) => const SoundcloudAuth(clientId: 'test'),
          ),
          aiSettingsProvider.overrideWithBuild(
            (ref, notifier) =>
                const AiSettingsState(ready: true, config: testConfig),
          ),
          soundcloudApiProvider.overrideWithValue(TestSoundcloud()),
          audioEngineProvider.overrideWithValue(engine),
          likedTracksProvider.overrideWith(StubLikedTracks.new),
          talkerProvider.overrideWithValue(Talker()),
          recommendationsProvider.overrideWithBuild(
            (ref, notifier) => RecommendationState(
              items: [for (final track in tracks) Recommendation(track, 'fit')],
            ),
          ),
          waveControllerProvider.overrideWithBuild(
            (ref, notifier) => const WaveState(active: true),
          ),
        ],
      );
      final player = container.read(playerControllerProvider.notifier);
      player.play(tracks.first, queue: tracks);
      const capture = ValueKey('shuffle-capture');
      await show(tester, captureKey: capture);
      await tester.pumpAndSettle();
      player.toggle();
      await tester.pumpAndSettle();
      expect(container.read(playerControllerProvider).isPlaying, isFalse);

      player.setShuffle(true);
      // Make the shuffled tail differ deterministically, even if random
      // shuffle happened to preserve the original queue order.
      final linearTail = tracks.skip(1).toList();
      if (listEquals(player.upcomingTracks, linearTail)) {
        player.reorderUpcoming(0, 2);
      }
      await tester.pumpAndSettle();
      final shuffledTail = player.upcomingTracks.toList();
      expect(shuffledTail, isNot(linearTail));
      // Mount with the completed shuffled order so a missing subscription
      // cannot be masked by the UI retaining its original linear order.
      await tester.pumpWidget(const SizedBox.shrink());
      await show(tester, captureKey: capture);
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<WaveQueueRow>(find.byType(WaveQueueRow))
            .map((row) => row.track.id),
        [tracks.first, ...shuffledTail].map((track) => track.id),
      );
      final version = container.read(playerControllerProvider).queueVersion;
      if (useToggle) {
        player.toggleShuffle();
      } else {
        player.setShuffle(false);
      }
      await tester.pumpAndSettle();
      expect(player.upcomingTracks, linearTail);
      expect(container.read(playerControllerProvider).queueVersion, version);
      if (File('build/visual-review/.capture-wave').existsSync()) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(capture),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'build/visual-review/wave-shuffle-$useToggle.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      expect(
        tester
            .widgetList<WaveQueueRow>(find.byType(WaveQueueRow))
            .map((row) => row.track.id),
        tracks.map((track) => track.id),
        reason: 'paused wave must refresh without a track or playback change',
      );
      if (useToggle) {
        player.toggleShuffle();
      } else {
        player.setShuffle(true);
      }
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<WaveQueueRow>(find.byType(WaveQueueRow))
            .map((row) => row.track.id),
        [tracks.first, ...player.upcomingTracks].map((track) => track.id),
        reason: 'read the shuffled order after the controller recomputes it',
      );
      expect(container.read(playerControllerProvider).isPlaying, isFalse);
      expect(container.read(playerControllerProvider).queueVersion, version);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'foreign queue retains start and consent instead of toggling playback',
    (tester) async {
      final track = realTrack('owned');
      final player = _PlaybackSpy(track, foreign: true);
      container.dispose();
      container = ProviderContainer(
        overrides: [
          aiSettingsProvider.overrideWithBuild(
            (ref, notifier) =>
                const AiSettingsState(ready: true, config: testConfig),
          ),
          recommendationsProvider.overrideWithBuild(
            (ref, notifier) => RecommendationState(
              items: [Recommendation(track, 'real reason')],
            ),
          ),
          waveControllerProvider.overrideWithBuild(
            (ref, notifier) => const WaveState(active: true),
          ),
          playerControllerProvider.overrideWith(() => player),
          authControllerProvider.overrideWithBuild(
            (ref, notifier) => const SoundcloudAuth(clientId: 'test'),
          ),
        ],
      );
      await show(tester, size: const Size(960, 640));
      final primary = find.byKey(const ValueKey('wave-primary'));
      expect(
        find.descendant(
          of: primary,
          matching: find.byIcon(Icons.play_arrow_rounded),
        ),
        findsOneWidget,
      );
      await tester.tap(primary);
      await tester.pumpAndSettle();
      expect(find.text('make my wave personal'), findsOneWidget);
      expect(player.toggles, 0);
      expect(client.payloads, isEmpty);
      expect(find.text('picked for your wave'), findsOneWidget);
      await tester.tap(find.text('not now'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('hidden hero stops energy and drift while playback advances', (
    tester,
  ) async {
    final track = Track(
      id: 'energy-owned',
      title: 'real envelope',
      artist: 'artist',
      durationMs: 1000,
      likes: 0,
      reposts: 0,
      plays: 0,
      waveform: const [],
      waveformUrl: 'hero-real',
    );
    final player = _PlaybackSpy(track);
    container.dispose();
    container = ProviderContainer(
      overrides: [
        playerControllerProvider.overrideWith(() => player),
        waveformSamplesProvider(
          'hero-real',
        ).overrideWith((ref) async => [0, 1, 1]),
      ],
    );
    var visible = true;
    late StateSetter update;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return MediaQuery(
                  data: const MediaQueryData(
                    size: Size(960, 640),
                    disableAnimations: false,
                  ),
                  child: WaveHero(
                    active: visible,
                    energyEnabled: true,
                    playing: true,
                    description: 'advancing playback',
                    actionLabel: 'pause',
                    onPlay: () {},
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    WaveRibbonPainter painter() =>
        tester
                .widget<CustomPaint>(
                  find.descendant(
                    of: find.byType(WaveHero),
                    matching: find.byType(CustomPaint),
                  ),
                )
                .painter!
            as WaveRibbonPainter;
    player.advance(250);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      painter().energy!.value,
      greaterThan(0),
      reason:
          'visible hero responds to fetched bins and actual advancing playback',
    );
    expect(painter().phase.value, greaterThan(0));
    update(() => visible = false);
    await tester.pump();
    final phase = painter().phase.value;
    expect(
      painter().energy!.value,
      0,
      reason: 'retained offscreen hero must immediately become neutral',
    );
    player.advance(500);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(painter().energy!.value, 0);
    expect(painter().phase.value, phase);
    expect(
      tester.binding.transientCallbackCount,
      0,
      reason: 'hidden hero schedules no decorative or energy ticker frames',
    );
    update(() => visible = true);
    await tester.pump();
    player.advance(750);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(painter().energy!.value, greaterThan(0));
    expect(painter().phase.value, isNot(phase));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('ribbon rasters leave a clear outer edge in every phase and energy', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final results = <Map<String, Object>>[];
      for (final size in [const Size(584, 280), const Size(880, 400)]) {
        for (final phase in [0.0, .25, .5, .75]) {
          Uint8List? silent;
          for (final energy in [0.0, 1.0]) {
            const overscan = 64;
            final recorder = ui.PictureRecorder();
            final canvas = Canvas(recorder)
              ..translate(overscan.toDouble(), overscan.toDouble());
            final envelope = ValueNotifier<double>(energy);
            WaveRibbonPainter(
              AlwaysStoppedAnimation(phase),
              energy: envelope,
            ).paint(canvas, size);
            final picture = recorder.endRecording();
            final image = await picture.toImage(
              size.width.toInt() + overscan * 2,
              size.height.toInt() + overscan * 2,
            );
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
            var edgeAlpha = 0;
            var maximumAlpha = 0;
            var changedPixels = 0;
            for (var y = 0; y < image.height; y++) {
              for (var x = 0; x < image.width; x++) {
                final alpha = bytes[(y * image.width + x) * 4 + 3];
                if (alpha > maximumAlpha) {
                  maximumAlpha = alpha;
                }
                final insideClearEdge =
                    x >= overscan + 8 &&
                    y >= overscan + 8 &&
                    x < overscan + size.width - 8 &&
                    y < overscan + size.height - 8;
                if (!insideClearEdge && alpha > edgeAlpha) {
                  edgeAlpha = alpha;
                }
                if (silent != null &&
                    alpha != silent[(y * image.width + x) * 4 + 3]) {
                  changedPixels++;
                }
              }
            }
            expect(
              maximumAlpha,
              greaterThan(32),
              reason: 'the actual ribbons must be painted',
            );
            expect(
              edgeAlpha,
              lessThanOrEqualTo(2),
              reason:
                  'no visible orange reaches the outer8px or the overscan canvas',
            );
            if (silent != null) {
              expect(
                changedPixels,
                greaterThan(100),
                reason: 'real energy still changes the rendered envelope',
              );
            }
            silent = bytes;
            results.add({
              'width': size.width,
              'height': size.height,
              'phase': phase,
              'energy': energy,
              'edgeAlpha': edgeAlpha,
              'maximumAlpha': maximumAlpha,
              'changedPixels': changedPixels,
            });
            if (File('build/visual-review/.capture-ribbon').existsSync()) {
              final png = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                'build/visual-review/ribbon-${size.width.toInt()}x${size.height.toInt()}-phase$phase-energy${energy.toInt()}.png',
              ).writeAsBytes(png!.buffer.asUint8List());
            }
            envelope.dispose();
            image.dispose();
            picture.dispose();
          }
        }
      }
      if (File('build/visual-review/.capture-ribbon').existsSync()) {
        await File(
          'build/visual-review/ribbon-raster-results.json',
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(results));
      }
    });
  });

  for (final size in [const Size(960, 640), const Size(1280, 800)]) {
    for (final scale in [1.0, 1.5]) {
      for (final mode in ['idle', 'playing', 'error']) {
        testWidgets('toolbar composition $mode at ${size.width} scale $scale', (
          tester,
        ) async {
          final track = realTrack('owned');
          final player = _PlaybackSpy(track);
          container.dispose();
          container = ProviderContainer(
            overrides: [
              aiSettingsProvider.overrideWithBuild(
                (ref, notifier) =>
                    const AiSettingsState(ready: true, config: testConfig),
              ),
              recommendationsProvider.overrideWithBuild(
                (ref, notifier) => RecommendationState(
                  items: mode == 'idle'
                      ? []
                      : [
                          Recommendation(track, 'real reason'),
                          Recommendation(realTrack('next'), 'real reason'),
                        ],
                  error: mode == 'error' ? AiFailure.network : null,
                ),
              ),
              waveControllerProvider.overrideWithBuild(
                (ref, notifier) => WaveState(active: mode != 'idle'),
              ),
              playerControllerProvider.overrideWith(() => player),
              authControllerProvider.overrideWithBuild(
                (ref, notifier) => const SoundcloudAuth(clientId: 'test'),
              ),
            ],
          );
          await show(tester, size: size, scale: scale);
          await tester.pumpAndSettle();
          final toolbar = find.byKey(const ValueKey('wave-toolbar'));
          expect(
            tester.getRect(toolbar).top,
            greaterThanOrEqualTo(tester.getRect(find.byType(WaveHero)).bottom),
          );
          expect(
            find.descendant(
              of: find.byType(WaveHero),
              matching: find.text('tune your wave'),
            ),
            findsNothing,
          );
          expect(
            find.descendant(of: toolbar, matching: find.text('tune your wave')),
            findsOneWidget,
          );
          await tester.ensureVisible(find.text('tune your wave'));
          await tester.tap(find.text('tune your wave'));
          await tester.pumpAndSettle();
          final mood = find.byKey(const ValueKey('wave-mood'));
          await tester.ensureVisible(mood);
          await tester.pump();
          expect(find.descendant(of: toolbar, matching: mood), findsOneWidget);
          expect(
            tester.getSize(mood).width,
            closeTo(tester.getSize(toolbar).width - 32, 1.1),
          );
          final actions = find.byKey(const ValueKey('wave-toolbar-actions'));
          final tune = tester.getRect(find.text('tune your wave'));
          final model = tester.getRect(find.text('model connection'));
          expect((tune.center.dy - model.center.dy).abs(), lessThan(1));
          expect(
            tester.getRect(actions).right,
            lessThanOrEqualTo(tester.getRect(toolbar).right - 16),
          );
          if (mode != 'idle') {
            expect(
              find.descendant(of: toolbar, matching: find.text('stop my wave')),
              findsNothing,
            );
            expect(find.text('stop my wave'), findsOneWidget);
            final apply = find.text('apply mood');
            await tester.ensureVisible(apply);
            expect(
              tester
                  .getRect(
                    find.ancestor(of: apply, matching: find.byType(FormAction)),
                  )
                  .right,
              closeTo(tester.getRect(toolbar).right - 16, .6),
            );
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
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
