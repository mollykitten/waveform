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

import '../support/fake_audio_engine.dart';

void main() {
  testWidgets('search trigger follows edits to the shared controller', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          audioEngineProvider.overrideWithValue(FakeAudioEngine()),
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
    final controller = container.read(omniboxControllerProvider);
    expect(find.text('search tracks, artists, playlists…'), findsOneWidget);

    controller.text = 'ambient mix';
    await tester.pump();
    expect(find.text('ambient mix'), findsOneWidget);
    expect(find.text('search tracks, artists, playlists…'), findsNothing);

    controller.clear();
    await tester.pump();
    expect(find.text('search tracks, artists, playlists…'), findsOneWidget);
    expect(find.text('ambient mix'), findsNothing);
  });
}
