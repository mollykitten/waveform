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
import 'package:waveform_app/core/recommendations/models.dart';
import 'package:waveform_app/core/recommendations/providers.dart';
import 'package:waveform_app/features/player/player_controller.dart';
import 'package:waveform_app/features/recommendations/recommendations_screen.dart';
import 'package:waveform_app/features/recommendations/widgets/wave_hero.dart';
import 'package:waveform_app/shared/widgets/pressable.dart';
import 'package:waveform_app/shared/widgets/top_bar.dart';
import 'package:waveform_app/shared/widgets/track_row.dart';
import 'package:waveform_app/features/recommendations/wave_controller.dart';

import '../support/fake_audio_engine.dart';
import '../support/stub_liked_tracks.dart';
import 'pool_service.dart';
import 'support.dart';

void main() {
  late ProviderContainer container;
  late TestSoundcloud api;
  late PoolService service;
  late FakeAudioEngine engine;
  var signedIn = false;

  setUp(() {
    signedIn = true;
    api = TestSoundcloud();
    service = PoolService(api)..scripted = [4];
    engine = FakeAudioEngine();
    container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWithBuild(
          (ref, notifier) => SoundcloudAuth(
            clientId: 'ui-test',
            userToken: signedIn ? 'synthetic-test-account' : null,
          ),
        ),
        waveRetryDelayProvider.overrideWithValue(Duration.zero),
        listeningIdentityProvider.overrideWith(
          (ref) async => 'ui-test-profile',
        ),
        recommendationServiceProvider.overrideWithValue(service),
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

  Future<void> settle(WidgetTester tester) => tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 2),
  );

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

  Future<void> play(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('wave-primary')));
    await settle(tester);
  }

  testWidgets('anonymous visitors see a quiet prompt and no play action', (
    tester,
  ) async {
    signedIn = false;
    await show(tester);
    expect(find.text('my wave'), findsOneWidget);
    expect(find.byType(WaveHero), findsOneWidget);
    expect(
      find.text('sign in to SoundCloud to build your wave from your likes.'),
      findsOneWidget,
    );
    expect(find.text('sign in to SoundCloud'), findsOneWidget);
    expect(
      tester
          .widget<Pressable>(find.byKey(const ValueKey('wave-primary')))
          .enabled,
      isFalse,
    );
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('ChatGPT'), findsNothing);
    expect(service.calls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('one tap plays a real queue with no dialog or settings', (
    tester,
  ) async {
    final current = realTrack('current');
    container.read(playerControllerProvider.notifier).play(current);
    await show(tester);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('tune your wave'), findsNothing);
    await play(tester);
    expect(service.calls, 1);
    final player = container.read(playerControllerProvider.notifier);
    expect(container.read(playerControllerProvider).track?.id, 't1');
    expect(player.upcomingTracks.map((t) => t.id), ['t2', 't3', 't4']);
    expect(engine.lastLoadedUrl, 'https://play.invalid/stream.mp3');
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('stop my wave'), findsOneWidget);
    expect(find.text('a possible fit'), findsWidgets);
    expect(find.byKey(const ValueKey('wave-row-t2')), findsOneWidget);
    // an owned wave pauses and resumes instead of regenerating
    await tester.tap(find.byKey(const ValueKey('wave-primary')));
    await tester.pump();
    expect(container.read(playerControllerProvider).isPlaying, isFalse);
    expect(service.calls, 1);
    container.read(waveControllerProvider.notifier).cancel();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('960x640 shows the result queue without overflow', (
    tester,
  ) async {
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
    await play(tester);
    await tester.scrollUntilVisible(
      find.byType(TrackRow).first,
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byType(TrackRow), findsWidgets);
    expect(tester.takeException(), isNull);
    container.read(waveControllerProvider.notifier).cancel();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('played wave tracks leave the list', (tester) async {
    await show(tester);
    await play(tester);
    expect(find.byKey(const ValueKey('wave-row-t1')), findsOneWidget);
    container.read(playerControllerProvider.notifier).next();
    await settle(tester);
    expect(container.read(playerControllerProvider).track?.id, 't2');
    // The refill found nothing and gave up, so the wave is inactive now.
    expect(container.read(waveControllerProvider).active, isFalse);
    expect(find.byKey(const ValueKey('wave-row-t1')), findsNothing);
    expect(find.byKey(const ValueKey('wave-row-t2')), findsOneWidget);
    container.read(waveControllerProvider.notifier).cancel();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a failure shows a safe retry and leaves the player alone', (
    tester,
  ) async {
    service.failure = WaveFailure.source;
    await show(tester);
    await play(tester);
    expect(find.textContaining('could not reach SoundCloud'), findsOneWidget);
    expect(find.text('try again'), findsOneWidget);
    expect(find.textContaining('PRIVATE'), findsNothing);
    expect(container.read(playerControllerProvider).track, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'wave refills after screen disposal and continues beyond two batches',
    (tester) async {
      service.scripted = [4, 4, 4, 4];
      await show(tester);
      await play(tester);
      expect(service.calls, greaterThanOrEqualTo(1));
      await tester.pumpWidget(const SizedBox.shrink());
      final player = container.read(playerControllerProvider.notifier);
      for (var i = 0; i < 10; i++) {
        player.next();
        await settle(tester);
      }
      // The script holds four batches; once spent, later searches are empty.
      expect(service.calls, greaterThanOrEqualTo(4));
      expect(container.read(recommendationsProvider).items, hasLength(16));
      container.read(waveControllerProvider.notifier).cancel();
      final settled = service.calls;
      player.toggle();
      player.toggle();
      await settle(tester);
      expect(service.calls, settled);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
