import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:waveform_app/shared/widgets/form_controls.dart';
import 'visual_test_fonts.dart';
import 'package:waveform_app/app/theme/app_theme.dart';
import 'package:waveform_app/features/recommendations/wave_controls.dart';

void main() {
  setUpAll(installVisualTestFonts);
  testWidgets('connection card offers connect and then disconnect', (
    tester,
  ) async {
    var connected = false;
    var connectCalls = 0;
    var disconnectCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => WaveConnectionCard(
              connected: connected,
              busy: false,
              onConnect: () {
                connectCalls++;
                setState(() => connected = true);
              },
              onDisconnect: () {
                disconnectCalls++;
                setState(() => connected = false);
              },
            ),
          ),
        ),
      ),
    );
    expect(find.text('continue with ChatGPT'), findsOneWidget);
    expect(connectCalls, 0);
    await tester.tap(find.text('continue with ChatGPT'));
    await tester.pump();
    expect(connectCalls, 1);
    expect(find.text('connected'), findsOneWidget);
    expect(find.text('continue with ChatGPT'), findsNothing);
    await tester.tap(find.text('disconnect ChatGPT'));
    await tester.pump();
    expect(disconnectCalls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('mood stays collapsed and is optional', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(body: WaveMoodField(controller: controller)),
      ),
    );
    expect(find.byType(TextField), findsNothing);
    expect(controller.text, isEmpty);
    await tester.tap(find.text('add a mood (optional)'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('wave-mood')),
      'a quiet evening',
    );
    expect(controller.text, 'a quiet evening');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'form action preserves bounds while busy and keyboard activation',
    (tester) async {
      var calls = 0;
      var busy = false;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: Center(
              child: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return FormAction(
                    label: 'continue with ChatGPT',
                    busyLabel: 'connecting…',
                    busy: busy,
                    onTap: () => calls++,
                  );
                },
              ),
            ),
          ),
        ),
      );
      final original = tester.getSize(find.byType(FormAction));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(calls, 1);
      update(() => busy = true);
      await tester.pump();
      expect(tester.getSize(find.byType(FormAction)), original);
      await tester.tap(find.text('connecting…'));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(calls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'mood keeps the editing focus used by the player shortcut guard',
    (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: WaveMoodField(controller: controller, expanded: true),
          ),
        ),
      );
      final label = tester.getRect(find.text('what are you in the mood for?'));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorStateOfType<EditableTextState>(),
        isNotNull,
        reason:
            'AppShell disables player shortcuts while EditableText owns focus',
      );
      await tester.enterText(find.byType(TextField), 'quiet evening');
      await tester.pump();
      expect(controller.text, contains(' '));
      expect(tester.getRect(find.text('what are you in the mood for?')), label);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('consent explains metadata and destination before approval', (
    tester,
  ) async {
    bool? approved;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                approved = await showWaveListeningConsent(
                  context,
                  destination: 'ChatGPT',
                );
              },
              child: const Text('play my wave'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('play my wave'));
    await tester.pumpAndSettle();
    expect(approved, isNull);
    final reject = find.ancestor(
      of: find.text('not now'),
      matching: find.byType(FormAction),
    );
    final accept = find.ancestor(
      of: find.text('allow and play'),
      matching: find.byType(FormAction),
    );
    expect(tester.getRect(accept).left - tester.getRect(reject).right, 8);

    expect(find.text('sent to ChatGPT'), findsOneWidget);
    expect(
      find.textContaining('recent listening and current track'),
      findsOneWidget,
    );
    await tester.tap(find.text('not now'));
    await tester.pumpAndSettle();
    expect(approved, isFalse);
    await tester.tap(find.text('play my wave'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('allow and play'));
    await tester.pumpAndSettle();
    expect(approved, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
