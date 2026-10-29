import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/api/liked_tracks.dart';
import 'package:waveform_app/core/audio/audio_engine.dart';
import 'package:waveform_app/features/library/library_screen.dart';
import 'package:waveform_app/features/player/player_controller.dart';
import 'package:waveform_app/shared/models/track.dart';
import 'package:waveform_app/shared/widgets/cover_art.dart';

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

void main() {
  late ProviderContainer container;
  final likes = [t('1'), t('2'), t('3')];

  Future<void> pump(WidgetTester tester) async {
    container = ProviderContainer(
      overrides: [
        audioEngineProvider.overrideWithValue(FakeAudioEngine()),
        likedTracksProvider.overrideWith(StubLikedTracks.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: LikeTile(track: likes[1], queue: likes),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('hover reveals play and one tap starts the likes queue', (
    tester,
  ) async {
    await pump(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    final opacity = find.byType(AnimatedOpacity);
    expect(tester.widget<AnimatedOpacity>(opacity).opacity, 0);
    await mouse.moveTo(tester.getCenter(find.byType(CoverArt)));
    await tester.pump();
    expect(tester.widget<AnimatedOpacity>(opacity).opacity, 1);

    await tester.tap(find.byType(CoverArt));
    await tester.pump();
    final pc = container.read(playerControllerProvider.notifier);
    expect(container.read(playerControllerProvider).track?.id, '2');
    expect(pc.upcomingTracks.map((x) => x.id), ['3']);
    expect(pc.queueSnapshot.map((x) => x.id), ['1', '2', '3']);
  });
}
