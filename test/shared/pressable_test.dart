import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/app/theme/colors.dart';
import 'package:waveform_app/shared/widgets/pressable.dart';

const _pressableKey = ValueKey('pressable');

Future<void> _pumpPressable(
  WidgetTester tester, {
  bool enabled = true,
  bool reducedMotion = false,
  VoidCallback? onTap,
  VoidCallback? onParentTap,
  double scale = 0.97,
}) async {
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(disableAnimations: reducedMotion),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: GestureDetector(
            onTap: onParentTap,
            child: Pressable(
              key: _pressableKey,
              enabled: enabled,
              onTap: onTap,
              scale: scale,
              child: const SizedBox(
                width: 100,
                height: 60,
                child: ColoredBox(color: Colors.orange),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

AnimatedScale _animation(WidgetTester tester) =>
    tester.widget<AnimatedScale>(find.byType(AnimatedScale));

double _renderedScale(WidgetTester tester) =>
    tester.widget<ScaleTransition>(find.byType(ScaleTransition)).scale.value;

Future<TestGesture> _press(WidgetTester tester) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byKey(_pressableKey)),
  );
  // Allow the tap-down deadline and press animation to finish.
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
  return gesture;
}

void main() {
  testWidgets('tab focuses button and Enter and Space activate once', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Pressable(onTap: () => taps++, child: const Text('activate')),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(taps, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(taps, 2);
  });

  testWidgets('button exposes one enabled semantic tap action', (tester) async {
    final semantics = tester.ensureSemantics();
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Pressable(onTap: () => taps++, child: const Text('activate')),
        ),
      ),
    );
    expect(
      tester.getSemantics(find.text('activate')),
      matchesSemantics(
        label: 'activate',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasTapAction: true,
      ),
    );
    final node = tester.getSemantics(find.text('activate'));
    node.owner!.performAction(node.id, SemanticsAction.tap);
    expect(taps, 1);
    semantics.dispose();
  });

  testWidgets('disabled button is skipped and cannot activate', (tester) async {
    final semantics = tester.ensureSemantics();
    var disabledTaps = 0;
    var enabledTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Pressable(
                enabled: false,
                onTap: () => disabledTaps++,
                child: const Text('disabled'),
              ),
              Pressable(
                onTap: () => enabledTaps++,
                child: const Text('enabled'),
              ),
            ],
          ),
        ),
      ),
    );
    expect(
      tester.getSemantics(find.text('disabled')),
      matchesSemantics(
        label: 'disabled',
        isButton: true,
        hasEnabledState: true,
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(disabledTaps, 0);
    expect(enabledTaps, 2);
    semantics.dispose();
  });

  testWidgets('focused button consumes repeats and parent Space shortcut', (
    tester,
  ) async {
    var taps = 0;
    var globalTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.space): () => globalTaps++,
          },
          child: Scaffold(
            body: Pressable(onTap: () => taps++, child: const Text('activate')),
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    expect(taps, 1);
    expect(globalTaps, 0);
  });

  testWidgets('structural wrapper preserves child button and text input', (
    tester,
  ) async {
    var taps = 0;
    final controller = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Pressable(
            child: Column(
              children: [
                TextButton(onPressed: () => taps++, child: const Text('child')),
                TextField(controller: controller),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(taps, 1);
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'typed text');
    expect(controller.text, 'typed text');
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('nested button handles keyboard and pointer without parent tap', (
    tester,
  ) async {
    var parentTaps = 0;
    var childTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Pressable(
            onTap: () => parentTaps++,
            child: TextButton(
              onPressed: () => childTaps++,
              child: const Text('child'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('child'));
    await tester.pump();
    Focus.of(tester.element(find.text('child'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(childTaps, 2);
    expect(parentTaps, 0);
  });

  testWidgets('focused button shows border and disabling releases focus', (
    tester,
  ) async {
    var enabled = true;
    var taps = 0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Pressable(
                enabled: enabled,
                onTap: () => taps++,
                child: const Text('activate'),
              );
            },
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final decoration =
        tester
                .widget<DecoratedBox>(
                  find.descendant(
                    of: find.byType(Pressable),
                    matching: find.byType(DecoratedBox),
                  ),
                )
                .decoration
            as BoxDecoration;
    expect(decoration.border!.top.color, AppColors.acid);
    expect(decoration.border!.top.width, 0.5);
    update(() => enabled = false);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(taps, 0);
    expect(FocusManager.instance.primaryFocus?.debugLabel, isNot('Pressable'));
  });

  testWidgets('active wrapper does not steal Space from focused text field', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Pressable(onTap: () => taps++, child: const TextField()),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(taps, 0);
    expect(tester.testTextInput.isVisible, isTrue);
  });

  testWidgets('active press keeps default scale, timing and single tap', (
    tester,
  ) async {
    var taps = 0;
    await _pumpPressable(tester, onTap: () => taps++);
    expect(_renderedScale(tester), 1);

    final gesture = await _press(tester);
    expect(_animation(tester).scale, 0.97);
    expect(_renderedScale(tester), closeTo(0.97, 0.0001));
    expect(_animation(tester).duration, const Duration(milliseconds: 90));
    expect(_animation(tester).curve, Curves.easeOut);
    expect(taps, 0);

    await gesture.up();
    await tester.pump();
    expect(_animation(tester).scale, 1);
    expect(_animation(tester).duration, const Duration(milliseconds: 220));
    expect(_animation(tester).curve, Curves.easeOutBack);
    await tester.pumpAndSettle();
    expect(_renderedScale(tester), 1);
    expect(taps, 1);
  });

  testWidgets('pointer cancellation releases scale without invoking tap', (
    tester,
  ) async {
    var taps = 0;
    await _pumpPressable(tester, onTap: () => taps++);
    final gesture = await _press(tester);
    expect(_renderedScale(tester), closeTo(0.97, 0.0001));

    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(_renderedScale(tester), 1);
    expect(taps, 0);
  });

  for (final disabled in [true, false]) {
    final reason = disabled ? 'disabled' : 'no callback';
    testWidgets('$reason does not compress or consume parent tap', (
      tester,
    ) async {
      var taps = 0;
      var parentTaps = 0;
      await _pumpPressable(
        tester,
        enabled: !disabled,
        onTap: disabled ? () => taps++ : null,
        onParentTap: () => parentTaps++,
      );

      final gesture = await _press(tester);
      expect(_animation(tester).scale, 1);
      expect(_renderedScale(tester), 1);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(taps, 0);
      expect(parentTaps, 1);
    });

    testWidgets('$reason during press resets scale even after reactivation', (
      tester,
    ) async {
      var taps = 0;
      void onTap() => taps++;
      await _pumpPressable(tester, onTap: onTap);
      final gesture = await _press(tester);
      expect(_renderedScale(tester), closeTo(0.97, 0.0001));

      await _pumpPressable(
        tester,
        enabled: !disabled,
        onTap: disabled ? onTap : null,
      );
      expect(_animation(tester).scale, 1);
      await tester.pumpAndSettle();
      expect(_renderedScale(tester), 1);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(taps, 0);

      await _pumpPressable(tester, onTap: onTap);
      await tester.pumpAndSettle();
      expect(_renderedScale(tester), 1);
      await tester.tap(find.byKey(_pressableKey));
      await tester.pumpAndSettle();
      expect(taps, 1);
      expect(_renderedScale(tester), 1);
    });
  }

  testWidgets('reduced motion has no scale animation but still taps once', (
    tester,
  ) async {
    var taps = 0;
    await _pumpPressable(tester, reducedMotion: true, onTap: () => taps++);
    expect(_animation(tester).duration, Duration.zero);
    final gesture = await _press(tester);
    expect(_animation(tester).scale, 1);
    expect(_animation(tester).duration, Duration.zero);
    expect(_renderedScale(tester), 1);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(_renderedScale(tester), 1);
    expect(_animation(tester).duration, Duration.zero);
    expect(taps, 1);
  });

  testWidgets(
    'enabling reduced motion during press immediately restores scale',
    (tester) async {
      var taps = 0;
      void onTap() => taps++;
      await _pumpPressable(tester, onTap: onTap);
      final gesture = await _press(tester);
      expect(_renderedScale(tester), closeTo(0.97, 0.0001));

      await _pumpPressable(tester, reducedMotion: true, onTap: onTap);
      await tester.pump();
      expect(_animation(tester).duration, Duration.zero);
      expect(_renderedScale(tester), 1);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(taps, 1);
    },
  );

  testWidgets('active press honors custom scale', (tester) async {
    await _pumpPressable(tester, onTap: () {}, scale: 0.9);
    final gesture = await _press(tester);
    expect(_renderedScale(tester), closeTo(0.9, 0.0001));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(_renderedScale(tester), 1);
  });
}
