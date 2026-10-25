import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:waveform_app/app/theme/app_theme.dart';
import 'package:waveform_app/app/theme/colors.dart';
import 'package:waveform_app/core/audio/audio_output.dart';
import 'package:waveform_app/features/player/widgets/audio_output_picker.dart';

import 'audio_output_test.dart' show FakeOutput, MemoryPreferences, snapshot;

// Opt in with build/visual-review/.capture-controls; no permanent goldens.
final _captureEnabled = File(
  'build/visual-review/.capture-controls',
).existsSync();

void main() {
  for (final size in [const Size(1280, 720), const Size(960, 640)]) {
    testWidgets('capture output popup at ${size.width.toInt()}', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
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
      const capture = ValueKey('output-capture');
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.dark,
              debugShowCheckedModeBanner: false,
              home: Scaffold(
                body: Align(
                  alignment: Alignment.bottomRight,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: AudioOutputPicker(compact: size.width < 1100),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await container.read(audioOutputProvider.notifier).selectDevice('usb');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await _capture(
        tester,
        capture,
        'audio-output-popup-${size.width.toInt()}x${size.height.toInt()}.png',
      );
      expect(tester.takeException(), isNull);
    }, skip: !_captureEnabled);
  }

  setUpAll(() async {
    if (!_captureEnabled) return;
    final cache = Directory('build/visual-review/controls-font-cache');
    await cache.create(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => cache.absolute.path,
        );
    await HttpOverrides.runWithHttpOverrides(() async {
      AppTheme.dark;
      AppTheme.mono();
      await GoogleFonts.pendingFonts();
    }, _FontHttpOverrides());
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

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
          debugShowCheckedModeBanner: false,
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
            debugShowCheckedModeBanner: false,
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
            debugShowCheckedModeBanner: false,
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

Future<void> _capture(WidgetTester tester, Key key, String filename) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('build/visual-review');
    await directory.create(recursive: true);
    await File(
      '${directory.path}/$filename',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

// Fetch real font files before widget tests; their default client returns 400.
class _FontHttpOverrides extends HttpOverrides {}
