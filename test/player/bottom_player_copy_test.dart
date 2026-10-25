import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:waveform_app/app/app.dart';
import 'package:waveform_app/app/router.dart';
import 'package:waveform_app/core/api/mock_soundcloud_api.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/api/liked_tracks.dart';
import 'package:waveform_app/core/audio/audio_engine.dart';
import 'package:waveform_app/core/audio/playback_prefs.dart';
import 'package:waveform_app/core/deeplinks/clipboard_watcher.dart';
import 'package:waveform_app/core/log/talker.dart';
import 'package:waveform_app/features/player/player_controller.dart';
import 'package:waveform_app/features/player/player_ui_state.dart';
import 'package:waveform_app/features/player/widgets/bottom_player.dart';
import 'package:waveform_app/shared/models/track.dart';

import '../support/fake_audio_engine.dart';
import '../support/stub_liked_tracks.dart';

Track track(String id, {String? url}) => Track(
  id: id,
  title: 'Track $id',
  artist: 'Artist',
  durationMs: 100000,
  likes: 0,
  reposts: 0,
  plays: 0,
  waveform: const [0.2, 0.6, 0.4],
  permalinkUrl: url,
);

class _Watcher implements ClipboardWatcher {
  final seen = <String>[];
  @override
  void markSeen(String url) => seen.add(url);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  final clipboard = <String>[];
  late _Watcher watcher;
  late FakeAudioEngine engine;

  setUp(() {
    clipboard.clear();
    watcher = _Watcher();
    engine = FakeAudioEngine();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    engine.dispose();
  });

  Future<ProviderContainer> pumpPlayer(
    WidgetTester tester, {
    bool collapsed = false,
    double width = 1280,
    Track? initial,
    TargetPlatform platform = TargetPlatform.macOS,
  }) async {
    tester.view.physicalSize = Size(width, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          audioEngineProvider.overrideWithValue(engine),
          likedTracksProvider.overrideWith(StubLikedTracks.new),
          clipboardWatcherProvider.overrideWith((ref) => watcher),
        ],
        child: MaterialApp(
          theme: ThemeData.dark().copyWith(platform: platform),
          home: const Scaffold(
            body: Center(child: Text('stay on this page')),
            bottomNavigationBar: BottomPlayer(),
          ),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(BottomPlayer)),
    );
    if (collapsed) {
      container.read(playerCollapsedProvider.notifier).collapse();
    }
    if (initial != null) {
      container.read(playerControllerProvider.notifier).play(initial);
    }
    await tester.pump();
    return container;
  }

  Future<void> copyAndCheck(
    WidgetTester tester,
    ProviderContainer container,
    String url,
  ) async {
    final before = container.read(playerControllerProvider);
    await tester.tap(find.byIcon(Icons.link));
    await tester.pump();
    expect(clipboard.last, url);
    expect(watcher.seen.last, url);
    expect(find.text('link copied'), findsOneWidget);
    expect(find.text('stay on this page'), findsOneWidget);
    // Copy must not toggle playback, seek, or mutate the queue/state.
    expect(container.read(playerControllerProvider), same(before));
    expect(engine.lastSeek, isNull);
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets('expanded player copies exact permalink without navigation', (
    tester,
  ) async {
    const url = 'https://soundcloud.com/artist/a%20b?secret_token=s-test#t=2';
    final container = await pumpPlayer(tester, initial: track('1', url: url));
    await copyAndCheck(tester, container, url);
  });

  for (final collapsed in [false, true]) {
    testWidgets('real app player button copies permalink without route or '
        'playback changes: collapsed=$collapsed', (tester) async {
      const url = 'https://soundcloud.com/artist/a%20b?token=copy-test#t=12';
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            soundcloudApiProvider.overrideWithValue(const MockSoundcloudApi()),
            audioEngineProvider.overrideWithValue(engine),
            likedTracksProvider.overrideWith(StubLikedTracks.new),
            clipboardWatcherProvider.overrideWith((ref) => watcher),
            talkerProvider.overrideWithValue(Talker()),
          ],
          child: const WaveformApp(),
        ),
      );
      appRouter.go('/');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(WaveformApp)),
      );
      if (collapsed) {
        container.read(playerCollapsedProvider.notifier).collapse();
      }
      container
          .read(playerControllerProvider.notifier)
          .play(track('route-copy', url: url));
      await tester.pump();

      final before = container.read(playerControllerProvider);
      final routeBefore = appRouter.routeInformationProvider.value.uri;
      await tester.tap(find.byIcon(Icons.link));
      await tester.pump();

      expect(clipboard, [url]);
      expect(watcher.seen, [url]);
      expect(appRouter.routeInformationProvider.value.uri, routeBefore);
      expect(container.read(playerControllerProvider), same(before));
      expect(find.text('link copied'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 5));
    });
  }

  for (final collapsed in [false, true]) {
    for (final width in [920.0, 960.0, 1280.0, 1600.0]) {
      testWidgets('copy survives resize: collapsed=$collapsed width=$width', (
        tester,
      ) async {
        const url = 'https://soundcloud.com/artist/current';
        final container = await pumpPlayer(
          tester,
          collapsed: collapsed,
          width: width,
          initial: track('1', url: url),
        );
        await copyAndCheck(tester, container, url);
        expect(tester.takeException(), isNull);
      });
    }

    for (final url in [null, '', '   ']) {
      testWidgets('unavailable URL disables copy: $url collapsed=$collapsed', (
        tester,
      ) async {
        await pumpPlayer(
          tester,
          collapsed: collapsed,
          initial: track('missing', url: url),
        );
        final button = tester.widget<IconButton>(find.byType(IconButton));
        expect(button.onPressed, isNull);
        await tester.tap(find.byIcon(Icons.link));
        await tester.pump();
        expect(clipboard, isEmpty);
        expect(watcher.seen, isEmpty);
        expect(find.text('link copied'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('copy tracks next, queue replacement and crossfade swap: '
        'collapsed=$collapsed', (tester) async {
      final a = track('a', url: 'https://soundcloud.com/artist/a');
      final b = track('b', url: 'https://soundcloud.com/artist/b');
      final c = track('c', url: 'https://soundcloud.com/artist/c');
      final container = await pumpPlayer(tester, collapsed: collapsed);
      final controller = container.read(playerControllerProvider.notifier);
      controller.play(a, queue: [a, b]);
      await tester.pump();
      await copyAndCheck(tester, container, a.permalinkUrl!);
      controller.next();
      await tester.pump();
      await copyAndCheck(tester, container, b.permalinkUrl!);
      controller.play(c, queue: [c, a]);
      await tester.pump();
      await copyAndCheck(tester, container, c.permalinkUrl!);
      engine.preloadReady = true;
      container.read(playbackPrefsProvider.notifier).setCrossfadeMs(3000);
      engine.emitPosition(const Duration(milliseconds: 98000));
      await tester.pump();
      expect(engine.swapCount, 1);
      expect(container.read(playerControllerProvider).track, same(a));
      await copyAndCheck(tester, container, a.permalinkUrl!);
      controller.toggle();
      await tester.pump();
      expect(container.read(playerControllerProvider).isPlaying, isFalse);
      await copyAndCheck(tester, container, a.permalinkUrl!);
    });

    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      testWidgets('copy semantics, Tab/Enter and tooltip: '
          '$platform collapsed=$collapsed', (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          const url = 'https://soundcloud.com/artist/keyboard';
          final container = await pumpPlayer(
            tester,
            collapsed: collapsed,
            platform: platform,
            initial: track('key', url: url),
          );
          final tooltip = platform == TargetPlatform.macOS
              ? 'copy link · ⌘⇧C'
              : 'copy link · Ctrl+Shift+C';
          expect(find.byTooltip(tooltip), findsOneWidget);
          final node = tester.getSemantics(find.byType(IconButton));
          expect(node.label, 'Copy link');
          expect(node.flagsCollection.isButton, isTrue);
          expect(node.flagsCollection.isEnabled, Tristate.isTrue);
          expect(node.flagsCollection.isFocused, isNot(Tristate.none));
          final copyContext = tester.element(find.byIcon(Icons.link));
          final copyFocus = Focus.of(copyContext);
          final tabStops = FocusScope.of(
            copyContext,
          ).traversalDescendants.length;
          // Playback controls before Copy are keyboard accessible too.
          // Traverse the real focus order instead of assuming Copy is first.
          for (var i = 0; i < tabStops && !copyFocus.hasFocus; i++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pump();
          }
          expect(copyFocus.hasFocus, isTrue);
          expect(clipboard, isEmpty);
          final before = container.read(playerControllerProvider);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pump();
          expect(clipboard, [url]);
          expect(container.read(playerControllerProvider), same(before));
          await tester.pump(const Duration(seconds: 5));
        } finally {
          semantics.dispose();
        }
      });
    }
  }

  testWidgets('copy enablement follows URL changes without stale callbacks', (
    tester,
  ) async {
    final container = await pumpPlayer(tester, initial: track('missing'));
    final controller = container.read(playerControllerProvider.notifier);
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
    const url = 'https://soundcloud.com/artist/now-available';
    controller.play(track('available', url: url));
    await tester.pump();
    await copyAndCheck(tester, container, url);
    controller.play(track('empty', url: ''));
    await tester.pump();
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
    await tester.tap(find.byIcon(Icons.link));
    await tester.pump();
    expect(clipboard, [url]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('idle player is safe in both layouts', (tester) async {
    final container = await pumpPlayer(tester);
    expect(find.byIcon(Icons.link), findsNothing);
    container.read(playerCollapsedProvider.notifier).collapse();
    await tester.pump();
    final button = tester.widget<IconButton>(find.byType(IconButton));
    expect(button.onPressed, isNull);
    await tester.tap(find.byIcon(Icons.link));
    await tester.pump();
    expect(clipboard, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('collapsed player also offers direct permalink copy', (
    tester,
  ) async {
    const url = 'https://soundcloud.com/artist/second';
    final container = await pumpPlayer(
      tester,
      collapsed: true,
      initial: track('2', url: url),
    );
    expect(find.byIcon(Icons.link), findsOneWidget);
    await copyAndCheck(tester, container, url);
  });
}
