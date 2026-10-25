import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
