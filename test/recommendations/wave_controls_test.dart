import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/app/theme/app_theme.dart';
import 'package:waveform_app/features/recommendations/wave_controls.dart';

void main() {
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
