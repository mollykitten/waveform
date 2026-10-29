import 'package:flutter/material.dart';
import 'dart:ui' show Tristate;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/api/liked_tracks.dart';
import 'package:waveform_app/core/audio/audio_engine.dart';
import 'package:waveform_app/features/player/player_controller.dart';
import 'package:waveform_app/features/queue/queue_panel.dart';
import 'package:waveform_app/shared/models/track.dart';
import 'package:waveform_app/shared/widgets/pressable.dart';

import '../support/fake_audio_engine.dart';
import '../support/stub_liked_tracks.dart';

Track t(String id) => Track(
  id: id,
  title: 'T$id',
  artist: 'A',
  durationMs: 100000,
  likes: 0,
  reposts: 0,
  plays: 0,
  waveform: const <double>[],
);

Future<ProviderContainer> pumpPanel(WidgetTester tester) async {
  final engine = FakeAudioEngine();
  addTearDown(engine.dispose);
  tester.view.physicalSize = const Size(600, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        audioEngineProvider.overrideWithValue(engine),
        likedTracksProvider.overrideWith(StubLikedTracks.new),
      ],
      child: const MaterialApp(home: Scaffold(body: QueuePanel())),
    ),
  );
  final container = ProviderScope.containerOf(
    tester.element(find.byType(QueuePanel)),
  );
  container
      .read(playerControllerProvider.notifier)
      .play(t('1'), queue: [t('1'), t('2'), t('3'), t('4')]);
  await tester.pump();
  return container;
}

List<String> upcoming(ProviderContainer c) => c
    .read(playerControllerProvider.notifier)
    .upcomingTracks
    .map((x) => x.id)
    .toList();

Finder action(String verb, String id) => find.byTooltip(
  verb == 'remove' ? 'remove T$id from queue' : 'move T$id $verb',
);

Finder button(Finder f) =>
    find.descendant(of: f, matching: find.byType(Pressable));

Future<void> activate(WidgetTester tester, Finder f) async {
  Focus.of(
    tester.element(find.descendant(of: f, matching: find.byType(Icon))),
  ).requestFocus();
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('actions are named buttons; boundaries are disabled', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpPanel(tester);

    for (final id in ['2', '3', '4']) {
      expect(action('up', id), findsOneWidget);
      expect(action('down', id), findsOneWidget);
      expect(action('remove', id), findsOneWidget);
    }
    bool enabled(Finder f) =>
        tester.getSemantics(button(f)).flagsCollection.isEnabled ==
        Tristate.isTrue;
    expect(enabled(action('up', '2')), isFalse);
    expect(enabled(action('down', '2')), isTrue);
    expect(enabled(action('up', '4')), isTrue);
    expect(enabled(action('down', '4')), isFalse);
    expect(
      tester
          .getSemantics(button(action('remove', '3')))
          .flagsCollection
          .isButton,
      isTrue,
    );
    semantics.dispose();
  });

  testWidgets('keyboard move up/down reorders and keeps current track', (
    tester,
  ) async {
    final c = await pumpPanel(tester);

    await activate(tester, action('down', '2'));
    expect(upcoming(c), ['3', '2', '4']);
    await activate(tester, action('up', '4'));
    expect(upcoming(c), ['3', '4', '2']);
    expect(c.read(playerControllerProvider).track?.id, '1');
  });

  testWidgets('boundary buttons cannot activate', (tester) async {
    final c = await pumpPanel(tester);

    await tester.tap(action('up', '2'), warnIfMissed: false);
    await tester.tap(action('down', '4'), warnIfMissed: false);
    await tester.pump();
    expect(upcoming(c), ['2', '3', '4']);
  });

  testWidgets('focus stays on the moved row when its button disables', (
    tester,
  ) async {
    final c = await pumpPanel(tester);

    await activate(tester, action('up', '3'));
    expect(upcoming(c), ['3', '2', '4']);
    // 'move up' of the first row is now disabled; focus must not be lost.
    final focused = FocusManager.instance.primaryFocus;
    expect(focused, isNotNull);
    expect(focused!.debugLabel, 'queue row 3');
  });

  testWidgets('remove moves focus to neighbour, then to empty state', (
    tester,
  ) async {
    final c = await pumpPanel(tester);

    await activate(tester, action('remove', '3'));
    expect(upcoming(c), ['2', '4']);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'queue row 4');

    await activate(tester, action('remove', '4'));
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'queue row 2');

    await activate(tester, action('remove', '2'));
    expect(upcoming(c), isEmpty);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'queue empty');
    expect(c.read(playerControllerProvider).track?.id, '1');
  });
}
