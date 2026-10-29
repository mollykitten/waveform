import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:waveform_app/core/api/mock_soundcloud_api.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/audio/audio_engine.dart';
import 'package:waveform_app/core/log/talker.dart';
import 'package:waveform_app/features/omnibox/omnibox_dropdown.dart';
import 'package:waveform_app/features/omnibox/omnibox_providers.dart';

import '../support/fake_audio_engine.dart';

void main() {
  for (final reducedMotion in [true, false]) {
    testWidgets('omnibox entrance and escape, reduced=$reducedMotion', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          audioEngineProvider.overrideWithValue(FakeAudioEngine()),
          soundcloudApiProvider.overrideWithValue(const MockSoundcloudApi()),
          talkerProvider.overrideWithValue(Talker()),
        ],
      );
      addTearDown(container.dispose);
      container.read(omniboxOpenProvider.notifier).open();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: (_, child) => MediaQuery(
              data: MediaQueryData(disableAnimations: reducedMotion),
              child: child!,
            ),
            home: Scaffold(
              body: Consumer(
                builder: (_, ref, _) => ref.watch(omniboxOpenProvider)
                    ? const OmniboxDropdown()
                    : const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      );
      final fade = find
          .descendant(
            of: find.byType(OmniboxDropdown),
            matching: find.byType(FadeTransition),
          )
          .first;
      final scale = find
          .descendant(
            of: find.byType(OmniboxDropdown),
            matching: find.byType(ScaleTransition),
          )
          .first;
      expect(
        tester.widget<FadeTransition>(fade).opacity.value,
        reducedMotion ? 1 : 0,
      );
      expect(
        tester.widget<ScaleTransition>(scale).scale.value,
        reducedMotion ? 1 : 0.96,
      );
      await tester.pump(const Duration(milliseconds: 50));
      if (!reducedMotion) {
        expect(
          tester.widget<FadeTransition>(fade).opacity.value,
          inExclusiveRange(0, 1),
        );
      }
      await tester.pump(const Duration(milliseconds: 200));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(OmniboxDropdown), findsNothing);
      expect(container.read(omniboxOpenProvider), isFalse);
    });
  }

  testWidgets('enabling reduced motion settles an opening omnibox', (
    tester,
  ) async {
    final reducedMotion = ValueNotifier(false);
    addTearDown(reducedMotion.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          audioEngineProvider.overrideWithValue(FakeAudioEngine()),
          soundcloudApiProvider.overrideWithValue(const MockSoundcloudApi()),
          talkerProvider.overrideWithValue(Talker()),
        ],
        child: MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: reducedMotion,
            builder: (_, reduced, child) => MediaQuery(
              data: MediaQueryData(disableAnimations: reduced),
              child: child!,
            ),
            child: const Scaffold(body: OmniboxDropdown()),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final fade = find
        .descendant(
          of: find.byType(OmniboxDropdown),
          matching: find.byType(FadeTransition),
        )
        .first;
    expect(
      tester.widget<FadeTransition>(fade).opacity.value,
      inExclusiveRange(0, 1),
    );
    reducedMotion.value = true;
    await tester.pump();
    expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
    reducedMotion.value = false;
    await tester.pump();
    expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
  });
}
