import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:waveform_app/core/api/mock_soundcloud_api.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/audio/audio_engine.dart';
import 'package:waveform_app/core/log/talker.dart';
import 'package:waveform_app/features/omnibox/omnibox_providers.dart';
import 'package:waveform_app/shared/widgets/top_bar.dart';
import 'package:waveform_app/shared/widgets/window_controls.dart';

import '../support/fake_audio_engine.dart';

void main() {
  testWidgets('top bar keeps account at the right edge across window widths', (
    tester,
  ) async {
    final engine = FakeAudioEngine();
    addTearDown(engine.dispose);
    tester.view.physicalSize = const Size(960, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          audioEngineProvider.overrideWithValue(engine),
          soundcloudApiProvider.overrideWithValue(const MockSoundcloudApi()),
          talkerProvider.overrideWithValue(Talker()),
        ],
        child: const MaterialApp(
          home: Scaffold(body: TopBar(location: '/')),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(TopBar)),
    );

    // On windows/linux the caption buttons reserve extra room on the right.
    final inset = needsWindowControls ? 16 + windowControlsWidth : 16.0;
    final account = find
        .ancestor(of: find.text('log in'), matching: find.byType(Container))
        .first;
    for (final width in [960.0, 1280.0, 1600.0]) {
      tester.view.physicalSize = Size(width, 720);
      await tester.pump();

      expect(find.text('home'), findsOneWidget);
      expect(find.text('discover'), findsOneWidget);
      final search = find.text('search tracks, artists, playlists…');
      expect(search, findsOneWidget);
      expect(tester.getRect(search).width, greaterThan(0));
      expect(find.byTooltip('logs'), findsOneWidget);
      expect(find.byTooltip('queue'), findsOneWidget);
      expect(find.byTooltip('settings'), findsOneWidget);
      expect(find.text('log in'), findsOneWidget);
      expect(tester.getRect(account).right, closeTo(width - inset, 0.5));
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.text('search tracks, artists, playlists…'));
    await tester.pump();
    expect(container.read(omniboxOpenProvider), isTrue);
  });
}
