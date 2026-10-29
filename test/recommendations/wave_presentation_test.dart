import 'dart:io';
import 'dart:ui' as ui;
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:waveform_app/app/theme/app_theme.dart';
import 'package:waveform_app/app/theme/colors.dart';
import 'package:waveform_app/core/api/liked_tracks.dart';
import 'package:waveform_app/core/api/reposted_tracks.dart';
import 'package:waveform_app/core/api/soundcloud_api.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/api/soundcloud_auth.dart';
import 'package:waveform_app/core/audio/audio_engine.dart';
import 'package:waveform_app/core/log/talker.dart';
import 'package:waveform_app/core/recommendations/providers.dart';
import 'package:waveform_app/core/recommendations/models.dart';
import 'package:waveform_app/features/player/player_controller.dart';
import 'package:waveform_app/features/recommendations/wave_controller.dart';
import 'package:waveform_app/shared/models/track.dart';
import 'package:waveform_app/shared/providers/waveform_samples.dart';
import 'package:waveform_app/features/recommendations/recommendations_screen.dart';
import 'package:waveform_app/features/recommendations/widgets/wave_hero.dart';
import 'package:waveform_app/shared/widgets/pressable.dart';
import 'package:waveform_app/shared/widgets/track_row.dart';
import 'package:waveform_app/shared/widgets/waveform_view.dart';

import '../support/fake_audio_engine.dart';
import '../support/stub_liked_tracks.dart';
import 'pool_service.dart';
import 'support.dart';
import 'visual_test_fonts.dart';

class _PlaybackSpy extends PlayerController {
  _PlaybackSpy(this.current, {this.foreign = false});
  final Track current;
  final bool foreign;
  int toggles = 0;
  List<Track> _upcoming = [realTrack('next')];
  List<Track>? playedQueue;
  double? soughtFraction;
  void publishUpcoming(List<Track> tracks) {
    _upcoming = tracks;
    state = state.copyWith(queueVersion: state.queueVersion + 1);
  }

  @override
  void play(Track track, {List<Track>? queue}) {
    playedQueue = queue == null ? null : List.of(queue);
    final index = queue?.indexWhere((item) => item.id == track.id) ?? -1;
    _upcoming = index < 0 ? [] : queue!.skip(index + 1).toList();
    state = state.copyWith(
      track: track,
      isPlaying: true,
      queueVersion: state.queueVersion + 1,
    );
  }

  @override
  void seekFraction(double fraction) {
    soughtFraction = fraction;
    state = state.copyWith(
      position: Duration(
        milliseconds: (fraction * state.track!.durationMs).round(),
      ),
      seekVersion: state.seekVersion + 1,
    );
  }

  void advance(int milliseconds) =>
      state = state.copyWith(position: Duration(milliseconds: milliseconds));
  @override
  PlayerState build() => PlayerState(
    track: foreign ? realTrack('foreign') : current,
    isPlaying: true,
  );
  @override
  List<Track> get upcomingTracks => List.unmodifiable(_upcoming);
  @override
  void toggle() {
    toggles++;
    state = state.copyWith(isPlaying: !state.isPlaying);
  }
}

class _TrackActionsApi extends TestSoundcloud {
  @override
  Future<({List<Track> tracks, String? nextHref})> likesPage({
    String? nextHref,
    int limit = 50,
  }) async => (tracks: const <Track>[], nextHref: null);
  final likes = <(String, bool)>[];
  final reposts = <(String, bool)>[];
  @override
  Future<LikeOutcome> setLiked(String id, bool liked) async {
    likes.add((id, liked));
    return LikeOutcome.ok;
  }

  @override
  Future<Set<String>> repostedTrackIds() async => {};
  @override
  Future<LikeOutcome> setReposted(String id, bool reposted) async {
    reposts.add((id, reposted));
    return LikeOutcome.ok;
  }
}

void main() {
  setUpAll(installVisualTestFonts);
  late ProviderContainer container;
  late FakeAudioEngine engine;

  setUp(() {
    engine = FakeAudioEngine();
    container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWithBuild(
          (ref, notifier) =>
              const SoundcloudAuth(clientId: 'test', userToken: 'test-token'),
        ),
        listeningIdentityProvider.overrideWith((ref) async => 'test-profile'),
        soundcloudApiProvider.overrideWithValue(TestSoundcloud()),
        audioEngineProvider.overrideWithValue(engine),
        likedTracksProvider.overrideWith(StubLikedTracks.new),
        talkerProvider.overrideWithValue(Talker()),
      ],
    );
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

  Future<void> captureWave(WidgetTester tester, Size size) async {
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
        '${folder.path}/wave-idle-'
        '${size.width.toInt()}x${size.height.toInt()}.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.pumpWidget(const SizedBox.shrink());
  }

  for (final size in [const Size(1280, 720), const Size(960, 640)]) {
    testWidgets(
      'wave capture ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        await captureWave(tester, size);
      },
      skip: !waveVisualCaptureEnabled,
    );
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
            soundcloudApiProvider.overrideWithValue(TestSoundcloud()),
            likedTracksProvider.overrideWith(StubLikedTracks.new),
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

  testWidgets('foreign queue starts a wave instead of toggling playback', (
    tester,
  ) async {
    final track = realTrack('owned');
    final player = _PlaybackSpy(track, foreign: true);
    container.dispose();
    container = ProviderContainer(
      overrides: [
        recommendationServiceProvider.overrideWithValue(
          PoolService(TestSoundcloud())..scripted = [3],
        ),
        waveRetryDelayProvider.overrideWithValue(Duration.zero),
        listeningIdentityProvider.overrideWith((ref) async => 'test-profile'),
        recommendationsProvider.overrideWithBuild(
          (ref, notifier) => RecommendationState(
            items: [Recommendation(track, 'real reason')],
          ),
        ),
        waveControllerProvider.overrideWithBuild(
          (ref, notifier) => const WaveState(active: true),
        ),
        playerControllerProvider.overrideWith(() => player),
        soundcloudApiProvider.overrideWithValue(TestSoundcloud()),
        likedTracksProvider.overrideWith(StubLikedTracks.new),
        authControllerProvider.overrideWithBuild(
          (ref, notifier) =>
              const SoundcloudAuth(clientId: 'test', userToken: 'test-token'),
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
    expect(find.text('picked for your wave'), findsOneWidget);
    await tester.tap(primary);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(player.toggles, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

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
        soundcloudApiProvider.overrideWithValue(TestSoundcloud()),
        likedTracksProvider.overrideWith(StubLikedTracks.new),
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
        testWidgets('status composition $mode at ${size.width} scale $scale', (
          tester,
        ) async {
          final track = realTrack('owned');
          final player = _PlaybackSpy(track);
          container.dispose();
          container = ProviderContainer(
            overrides: [
              recommendationsProvider.overrideWithBuild(
                (ref, notifier) => RecommendationState(
                  items: mode == 'playing'
                      ? [
                          Recommendation(track, 'real reason'),
                          Recommendation(realTrack('next'), 'real reason'),
                        ]
                      : [],
                  error: mode == 'error' ? WaveFailure.network : null,
                ),
              ),
              waveControllerProvider.overrideWithBuild(
                (ref, notifier) => WaveState(active: mode == 'playing'),
              ),
              playerControllerProvider.overrideWith(() => player),
              soundcloudApiProvider.overrideWithValue(TestSoundcloud()),
              likedTracksProvider.overrideWith(StubLikedTracks.new),
              authControllerProvider.overrideWithBuild(
                (ref, notifier) => SoundcloudAuth(
                  clientId: 'test',
                  userToken: mode == 'idle' ? null : 'test-token',
                ),
              ),
            ],
          );
          await show(tester, size: size, scale: scale);
          await tester.pumpAndSettle();
          final toolbar = find.byKey(const ValueKey('wave-toolbar'));
          expect(find.byType(TextField), findsNothing);
          if (mode == 'playing') {
            // a healthy wave shows no status card, just the queue
            expect(toolbar, findsNothing);
            expect(find.text('stop my wave'), findsOneWidget);
          } else {
            expect(
              tester.getRect(toolbar).top,
              greaterThanOrEqualTo(
                tester.getRect(find.byType(WaveHero)).bottom,
              ),
            );
            // the hero carries the status; the toolbar only holds actions
            expect(
              find.descendant(
                of: find.byType(WaveHero),
                matching: find.text(
                  mode == 'idle'
                      ? 'sign in to SoundCloud to build your wave from your likes.'
                      : WaveFailure.network.message,
                ),
              ),
              findsOneWidget,
            );
            expect(
              find.descendant(
                of: toolbar,
                matching: find.text(
                  mode == 'idle' ? 'sign in to SoundCloud' : 'try again',
                ),
              ),
              findsOneWidget,
            );
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  }

  testWidgets(
    'standard wave rows support shared like, repost, pause and seek without losing queue',
    (tester) async {
      final track = realTrack('owned');
      final player = _PlaybackSpy(track);
      final api = _TrackActionsApi();
      container.dispose();
      container = ProviderContainer(
        overrides: [
          recommendationsProvider.overrideWithBuild(
            (ref, notifier) => RecommendationState(
              items: [
                Recommendation(track, 'same real reason'),
                Recommendation(realTrack('next'), 'same real reason'),
                Recommendation(realTrack('third'), 'same real reason'),
              ],
            ),
          ),
          waveControllerProvider.overrideWithBuild(
            (ref, notifier) => const WaveState(active: true),
          ),
          playerControllerProvider.overrideWith(() => player),
          authControllerProvider.overrideWithBuild(
            (ref, notifier) => const SoundcloudAuth(clientId: 'test'),
          ),
          soundcloudApiProvider.overrideWithValue(api),
        ],
      );
      await show(
        tester,
        size: const Size(1280, 800),
        captureKey: const ValueKey('standard-row-capture'),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<TrackRow>(find.byType(TrackRow))
            .map((row) => row.track.id),
        ['owned', 'next'],
      );
      final owned = find.byKey(const ValueKey('wave-row-owned'));
      Finder control(IconData icon) => find.ancestor(
        of: find.descendant(of: owned, matching: find.byIcon(icon)),
        matching: find.byType(Pressable),
      );
      await tester.ensureVisible(owned);
      await tester.tap(control(Icons.favorite_border));
      await tester.pumpAndSettle();
      expect(api.likes, [('owned', true)]);
      expect(container.read(likedTracksProvider), contains('owned'));
      await tester.tap(control(Icons.favorite));
      await tester.pumpAndSettle();
      expect(api.likes, [('owned', true), ('owned', false)]);
      expect(container.read(likedTracksProvider), isNot(contains('owned')));
      await tester.tap(control(Icons.pause));
      await tester.pump();
      expect(player.toggles, 1);
      expect(container.read(playerControllerProvider).isPlaying, isFalse);
      await tester.tap(control(Icons.play_arrow));
      await tester.pump();
      expect(player.toggles, 2);
      final waveform = find.descendant(
        of: owned,
        matching: find.byType(WaveformView),
      );
      await tester.tapAt(tester.getRect(waveform).center);
      await tester.pump();
      expect(player.soughtFraction, closeTo(.5, .02));
      expect(
        container.read(playerControllerProvider).position.inMilliseconds,
        closeTo(track.durationMs / 2, 1000),
      );
      await tester.tap(owned, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('play next'), findsOneWidget);
      expect(find.text('open track page'), findsOneWidget);
      await tester.tap(find.text('repost'));
      await tester.pumpAndSettle();
      expect(api.reposts, [('owned', true)]);
      expect(container.read(repostedTracksProvider), contains('owned'));
      player.publishUpcoming([realTrack('third'), realTrack('next')]);
      await tester.pump();
      expect(
        tester
            .widgetList<TrackRow>(find.byType(TrackRow))
            .map((row) => row.track.id),
        ['owned', 'third', 'next'],
      );
      expect(find.text('same real reason'), findsOneWidget);
      final next = find.byKey(const ValueKey('wave-row-next'));
      await tester.ensureVisible(next);
      final nextPlay = find.ancestor(
        of: find.descendant(of: next, matching: find.byIcon(Icons.play_arrow)),
        matching: find.byType(Pressable),
      );
      await tester.tap(nextPlay);
      await tester.pump();
      expect(player.playedQueue!.map((item) => item.id), [
        'owned',
        'third',
        'next',
      ]);
      expect(container.read(playerControllerProvider).track!.id, 'next');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'standard track buttons expose one named enabled semantic action and update after activation',
    (tester) async {
      final track = realTrack('owned');
      final next = realTrack('next');
      final queue = [track, next];
      final player = _PlaybackSpy(track);
      final api = _TrackActionsApi();
      container.dispose();
      container = ProviderContainer(
        overrides: [
          playerControllerProvider.overrideWith(() => player),
          soundcloudApiProvider.overrideWithValue(api),
          authControllerProvider.overrideWithBuild(
            (ref, notifier) => const SoundcloudAuth(clientId: 'test'),
          ),
        ],
      );
      await show(
        tester,
        size: const Size(960, 640),
        child: Column(
          children: [
            TrackRow(track: track, queue: queue),
            TrackRow(track: next, queue: queue),
          ],
        ),
      );
      await tester.pumpAndSettle();
      void expectButton(String label) {
        final finder = find.semantics.byLabel(label);
        expect(
          finder,
          findsOne,
          reason: 'one actionable node owns the role and accessible name',
        );
        expect(
          finder.evaluate().single,
          isSemantics(
            label: label,
            isButton: true,
            isFocusable: true,
            hasEnabledState: true,
            isEnabled: true,
            hasTapAction: true,
          ),
        );
      }

      expectButton('pause track owned');
      expectButton('play track next');
      expectButton('like track owned');
      expectButton('like track next');
      tester.semantics.tap(find.semantics.byLabel('pause track owned'));
      await tester.pumpAndSettle();
      expect(player.toggles, 1);
      expectButton('play track owned');
      expect(find.semantics.byLabel('pause track owned'), findsNothing);
      tester.semantics.tap(find.semantics.byLabel('like track owned'));
      await tester.pumpAndSettle();
      expect(api.likes, [('owned', true)]);
      expectButton('unlike track owned');
      expect(find.semantics.byLabel('like track owned'), findsNothing);
      expectButton('like track next');
      tester.semantics.tap(find.semantics.byLabel('like track next'));
      await tester.pumpAndSettle();
      expect(api.likes, [('owned', true), ('next', true)]);
      expectButton('unlike track next');
      tester.semantics.tap(find.semantics.byLabel('unlike track owned'));
      await tester.pumpAndSettle();
      expect(api.likes.last, ('owned', false));
      expectButton('like track owned');
      expectButton('unlike track next');
      tester.semantics.tap(find.semantics.byLabel('play track next'));
      await tester.pumpAndSettle();
      expect(player.playedQueue!.map((item) => item.id), ['owned', 'next']);
      expectButton('pause track next');
      expectButton('play track owned');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

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
