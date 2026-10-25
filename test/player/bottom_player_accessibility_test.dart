import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/api/liked_tracks.dart';
import 'package:waveform_app/core/audio/audio_engine.dart';
import 'package:waveform_app/features/player/player_controller.dart';
import 'package:waveform_app/features/player/player_ui_state.dart';
import 'package:waveform_app/features/player/widgets/bottom_player.dart';
import 'package:waveform_app/shared/models/track.dart';

import '../support/fake_audio_engine.dart';
import '../support/stub_liked_tracks.dart';

void main() {
  testWidgets('collapse and expand controls have accessible names and work', (
    tester,
  ) async {
    final engine = FakeAudioEngine();
    addTearDown(engine.dispose);
    final semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          audioEngineProvider.overrideWithValue(engine),
          likedTracksProvider.overrideWith(StubLikedTracks.new),
        ],
        child: const MaterialApp(
          home: Scaffold(bottomNavigationBar: BottomPlayer()),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(BottomPlayer)),
    );
    container
        .read(playerControllerProvider.notifier)
        .play(
          Track(
            id: 'a11y',
            title: 'Accessibility track',
            artist: 'Artist',
            durationMs: 60000,
            likes: 0,
            reposts: 0,
            plays: 0,
            waveform: const [0.3, 0.5],
          ),
        );
    await tester.pump();

    expect(find.byTooltip('collapse player'), findsOneWidget);
    final collapse = find.bySemanticsLabel('collapse player').first;
    expect(tester.getSemantics(collapse).flagsCollection.isButton, isTrue);
    Focus.of(tester.element(find.byIcon(Icons.expand_more))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(container.read(playerCollapsedProvider), isTrue);
    expect(find.byTooltip('expand player'), findsOneWidget);
    final expand = find.bySemanticsLabel('expand player').first;
    expect(tester.getSemantics(expand).flagsCollection.isButton, isTrue);
    Focus.of(tester.element(find.byIcon(Icons.expand_less))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(container.read(playerCollapsedProvider), isFalse);
    semantics.dispose();
  });
}
