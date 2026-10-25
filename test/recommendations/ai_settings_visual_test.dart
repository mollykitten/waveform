import 'dart:io';
import 'dart:ui' as ui;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:waveform_app/app/theme/app_theme.dart';
import 'package:waveform_app/core/recommendations/ai_config.dart';
import 'package:waveform_app/core/recommendations/chatgpt_auth.dart';
import 'package:waveform_app/core/recommendations/providers.dart';
import 'package:waveform_app/features/recommendations/ai_settings_section.dart';
import 'package:waveform_app/shared/widgets/pressable.dart';

class _NoChatGpt extends ChatGptAuth {
  @override
  Future<void> restore() async {}
}

class _Store extends AiConfigStore {
  Completer<void>? pending;
  AiConfig config = const AiConfig(
    endpoint: 'http://localhost:11434',
    model: 'local-model',
  );

  @override
  Future<AiConfig> load() async => config;

  @override
  Future<void> save(AiConfig value) async {
    await pending?.future;
    config = value;
  }
}

// Opt in with build/visual-review/.capture-controls; no permanent goldens.
final _captureEnabled = File(
  'build/visual-review/.capture-controls',
).existsSync();

void main() {
  for (final size in [const Size(1280, 720), const Size(960, 640)]) {
    testWidgets('capture AI settings at ${size.width.toInt()}', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = ProviderContainer(
        overrides: [
          aiConfigStoreProvider.overrideWithValue(_Store()),
          chatGptAuthProvider.overrideWithValue(_NoChatGpt()),
        ],
      );
      addTearDown(container.dispose);
      const capture = ValueKey('settings-capture');
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.dark,
              debugShowCheckedModeBanner: false,
              home: const Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 640,
                    child: SingleChildScrollView(
                      padding: EdgeInsets.all(AppTheme.pagePad),
                      child: AiSettingsSection(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _capture(
        tester,
        capture,
        'ai-settings-${size.width.toInt()}x${size.height.toInt()}.png',
      );
      await tester.tap(find.text('advanced settings'));
      await tester.pumpAndSettle();
      await _capture(
        tester,
        capture,
        'ai-settings-privacy-${size.width.toInt()}x${size.height.toInt()}.png',
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

  testWidgets(
    'compact configuration keeps editing and protocol locked on save',
    (tester) async {
      final store = _Store();
      final container = ProviderContainer(
        overrides: [
          aiConfigStoreProvider.overrideWithValue(store),
          chatGptAuthProvider.overrideWithValue(_NoChatGpt()),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.dark,
            debugShowCheckedModeBanner: false,
            home: const Scaffold(
              body: SingleChildScrollView(child: AiSettingsSection()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('advanced settings'));
      await tester.pumpAndSettle();
      expect(find.byType(DropdownButtonFormField<AiBackend>), findsNothing);
      for (final field in tester.widgetList<TextField>(
        find.byType(TextField),
      )) {
        expect(field.decoration!.enabledBorder, isA<OutlineInputBorder>());
        expect(field.decoration!.counterText, '');
      }
      await tester.tap(find.text('Ollama (native)'));
      await tester.enterText(
        find.byKey(const ValueKey<String>('ai-session-key')),
        'session-test-key',
      );
      store.pending = Completer<void>();
      await tester.ensureVisible(find.text('save custom provider'));
      await tester.tap(find.text('save custom provider'));
      await tester.pump();
      expect(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .every((field) => field.enabled == false),
        isTrue,
      );
      expect(
        tester
            .widgetList<Pressable>(find.byType(Pressable))
            .where((button) => button.enabled)
            .length,
        0,
        reason: 'all custom-provider controls remain locked while saving',
      );
      store.pending!.complete();
      await tester.pumpAndSettle();
      expect(store.config.backend, AiBackend.ollama);
      expect(container.read(aiSettingsProvider).hasSessionKey, isTrue);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey<String>('ai-session-key')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );
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
