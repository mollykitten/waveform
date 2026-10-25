import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/app/theme/app_theme.dart';
import 'package:waveform_app/core/recommendations/ai_config.dart';
import 'package:waveform_app/core/recommendations/providers.dart';
import 'package:waveform_app/features/recommendations/ai_settings_section.dart';
import 'package:waveform_app/shared/widgets/pressable.dart';

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

void main() {
  testWidgets(
    'compact configuration keeps editing and protocol locked on save',
    (tester) async {
      final store = _Store();
      final container = ProviderContainer(
        overrides: [aiConfigStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.dark,
            home: const Scaffold(
              body: SingleChildScrollView(child: AiSettingsSection()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TextButton), findsNothing);
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
      await tester.tap(find.text('save AI settings'));
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
        1,
        reason: 'only the privacy disclosure remains interactive',
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
