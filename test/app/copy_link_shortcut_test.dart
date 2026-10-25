import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:waveform_app/app/app.dart';
import 'package:waveform_app/app/router.dart';
import 'package:waveform_app/app/shortcut_bindings.dart';
import 'package:waveform_app/core/api/liked_tracks.dart';
import 'package:waveform_app/core/api/mock_soundcloud_api.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/audio/audio_engine.dart';
import 'package:waveform_app/core/deeplinks/clipboard_watcher.dart';
import 'package:waveform_app/core/log/talker.dart';
import 'package:waveform_app/features/player/player_controller.dart';
import 'package:waveform_app/features/player/player_ui_state.dart';
import 'package:waveform_app/shared/intents.dart';
import 'package:waveform_app/shared/models/track.dart';

import '../support/fake_audio_engine.dart';
import '../support/stub_liked_tracks.dart';

class _Watcher implements ClipboardWatcher {
  final seen = <String>[];
  @override
  void markSeen(String url) => seen.add(url);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Track _track(String id, String? url) => Track(
  id: id,
  title: 'Shortcut track $id',
  artist: 'Artist',
  durationMs: 100000,
  likes: 0,
  reposts: 0,
  plays: 0,
  waveform: const [0.3, 0.5],
  permalinkUrl: url,
);

void main() {
  for (final isMac in [true, false]) {
    test('copy shortcut uses correct modifier: isMac=$isMac', () {
      final shortcuts = buildShortcuts(isMac: isMac, location: '/');
      final entries = shortcuts.entries.where((e) => e.value is CopyLinkIntent);
      expect(entries, hasLength(1));
      final activator = entries.single.key as SingleActivator;
      expect(activator.trigger, LogicalKeyboardKey.keyC);
      expect(activator.shift, isTrue);
      expect(activator.meta, isMac);
      expect(activator.control, !isMac);
    });
  }

  for (final collapsed in [false, true]) {
    testWidgets('real shell copy shortcut and focused Space preserve playback: '
        'collapsed=$collapsed', (tester) async {
      final copied = <String>[];
      final watcher = _Watcher();
      final engine = FakeAudioEngine();
      addTearDown(engine.dispose);
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
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
      // The shell's beep-suppressing Focus must let MaterialApp handle Tab.
      final shellFocus = tester
          .widgetList<Focus>(find.byType(Focus))
          .map((focus) => focus.focusNode)
          .whereType<FocusNode>()
          .singleWhere((node) => node.debugLabel == 'app-shell');
      shellFocus.requestFocus();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, same(shellFocus));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final firstControl = FocusManager.instance.primaryFocus;
      expect(firstControl, isNot(same(shellFocus)));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, isNot(same(firstControl)));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, same(firstControl));
      shellFocus.requestFocus();
      await tester.pump();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(WaveformApp)),
      );
      if (collapsed) {
        container.read(playerCollapsedProvider.notifier).collapse();
      }
      final controller = container.read(playerControllerProvider.notifier);
      final a = _track('a', 'https://soundcloud.com/artist/a');
      final b = _track('b', 'https://soundcloud.com/artist/b');
      controller.play(a, queue: [a, b]);
      await tester.pump();

      Future<void> shortcut() async {
        final modifier = Platform.isMacOS
            ? LogicalKeyboardKey.metaLeft
            : LogicalKeyboardKey.controlLeft;
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(modifier);
        await tester.pump();
      }

      for (final current in [a, b]) {
        if (current == b) controller.next();
        await tester.pump();
        final before = container.read(playerControllerProvider);
        await shortcut();
        expect(copied.last, current.permalinkUrl);
        expect(watcher.seen.last, current.permalinkUrl);
        expect(find.text('link copied'), findsOneWidget);
        expect(appRouter.routeInformationProvider.value.uri.path, '/');
        expect(container.read(playerControllerProvider), same(before));
        await tester.pump(const Duration(seconds: 5));
      }

      // Focus the real button: its local Space must win over shell play/pause.
      final copyIcon = find.descendant(
        of: find.byType(IconButton),
        matching: find.byIcon(Icons.link),
      );
      Focus.of(tester.element(copyIcon)).requestFocus();
      await tester.pump();
      final beforeSpace = container.read(playerControllerProvider);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(copied, [a.permalinkUrl, b.permalinkUrl, b.permalinkUrl]);
      expect(container.read(playerControllerProvider), same(beforeSpace));
      await tester.pump(const Duration(seconds: 5));

      for (final url in [null, '']) {
        controller.play(_track('missing', url));
        await tester.pump();
        final count = copied.length;
        await shortcut();
        expect(copied, hasLength(count));
        expect(find.text('nothing to copy'), findsOneWidget);
        await tester.pump(const Duration(seconds: 5));
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    });
  }
}
