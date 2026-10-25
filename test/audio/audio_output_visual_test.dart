import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/app/theme/app_theme.dart';
import 'package:waveform_app/app/theme/colors.dart';
import 'package:waveform_app/core/audio/audio_output.dart';
import 'package:waveform_app/features/player/widgets/audio_output_picker.dart';

import 'audio_output_test.dart' show FakeOutput, MemoryPreferences, snapshot;

void main() {
  testWidgets('disconnected route retains fallback and AirPlay explanation', (
    tester,
  ) async {
    final platform = FakeOutput();
    final container = ProviderContainer(
      overrides: [
        audioOutputPlatformProvider.overrideWithValue(platform),
        audioOutputPreferencesProvider.overrideWithValue(MemoryPreferences()),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await platform.controller.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(body: AudioOutputPicker(compact: true)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    platform.controller.add({
      ...snapshot(uid: 'disconnected', preserve: true),
      'devices': <Object?>[],
      'message': 'device_unavailable',
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Saved output is disconnected.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Gapless and crossfade are paused'),
      findsOneWidget,
    );
    expect(find.text('USB speakers'), findsNothing);
    expect(find.text('system default'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unsupported platform offers explanation without device actions',
    (tester) async {
      final platform = FakeOutput(supported: false);
      final container = ProviderContainer(
        overrides: [audioOutputPlatformProvider.overrideWithValue(platform)],
      );
      addTearDown(() async {
        container.dispose();
        await platform.controller.close();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.dark,
            home: const Scaffold(body: AudioOutputPicker()),
          ),
        ),
      );
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(find.textContaining('unavailable on this platform'), findsWidgets);
      expect(find.text('system default'), findsNothing);
      expect(find.text('AirPlay…'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final compact in [false, true]) {
    testWidgets('styled output menu routes real devices (compact: $compact)', (
      tester,
    ) async {
      final platform = FakeOutput();
      final container = ProviderContainer(
        overrides: [
          audioOutputPlatformProvider.overrideWithValue(platform),
          audioOutputPreferencesProvider.overrideWithValue(MemoryPreferences()),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await platform.controller.close();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.dark,
            home: Scaffold(body: AudioOutputPicker(compact: compact)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('USB speakers'), findsOneWidget);
      expect(find.byType(CheckedPopupMenuItem<String>), findsNothing);
      expect(find.byIcon(Icons.check), findsOneWidget);
      final menu = tester.widget<PopupMenuButton<String>>(
        find.byType(PopupMenuButton<String>),
      );
      expect(menu.color, AppColors.surface);
      expect(menu.elevation, 0);
      expect((menu.shape! as RoundedRectangleBorder).side.width, 0.5);
      await tester.tap(find.text('USB speakers'));
      await tester.pumpAndSettle();
      expect(platform.selected, ['usb']);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('AirPlay…'));
      await tester.pumpAndSettle();
      expect(platform.airPlayCalls, 1);
      expect(container.read(audioOutputProvider).preservePlayer, isTrue);
      expect(tester.takeException(), isNull);
    });
  }
}
