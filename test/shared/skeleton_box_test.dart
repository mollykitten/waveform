import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/shared/widgets/skeleton_box.dart';

double _opacity(WidgetTester tester) {
  final container = tester.widget<Container>(
    find.descendant(
      of: find.byType(SkeletonBox),
      matching: find.byType(Container),
    ),
  );
  return (container.decoration! as BoxDecoration).color!.a;
}

Widget _host({bool disableAnimations = false, Widget? child}) {
  return MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: child ?? const SkeletonBox(width: 160, height: 24)),
    ),
  );
}

void main() {
  testWidgets('normal motion pulses forward and reverses over 1200ms', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    expect(_opacity(tester), closeTo(0.45, 0.000001));
    expect(tester.binding.transientCallbackCount, 1);

    await tester.pump(const Duration(milliseconds: 300));
    expect(
      _opacity(tester),
      closeTo(0.45 + 0.35 * Curves.easeInOut.transform(0.25), 0.000001),
    );
    await tester.pump(const Duration(milliseconds: 900));
    expect(_opacity(tester), closeTo(0.8, 0.000001));
    await tester.pump(const Duration(milliseconds: 600));
    expect(_opacity(tester), closeTo(0.625, 0.000001));
    await tester.pump(const Duration(milliseconds: 600));
    expect(_opacity(tester), closeTo(0.45, 0.000001));

    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  for (final useSystemFlag in [false, true]) {
    final source = useSystemFlag ? 'system flag' : 'MediaQuery';
    testWidgets('$source stops and resumes motion without remounting', (
      tester,
    ) async {
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      Future<void> setReducedMotion(bool disabled) async {
        if (useSystemFlag) {
          tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
              FakeAccessibilityFeatures(disableAnimations: disabled);
          await tester.pumpWidget(
            MediaQuery.fromView(
              view: tester.view,
              child: const Directionality(
                textDirection: TextDirection.ltr,
                child: Center(child: SkeletonBox(width: 160, height: 24)),
              ),
            ),
          );
        } else {
          await tester.pumpWidget(_host(disableAnimations: disabled));
        }
        expect(
          MediaQuery.disableAnimationsOf(
            tester.element(find.byType(SkeletonBox)),
          ),
          disabled,
        );
      }

      await setReducedMotion(false);
      final state = tester.state(find.byType(SkeletonBox));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_opacity(tester), greaterThan(0.45));

      for (var cycle = 0; cycle < 2; cycle++) {
        await setReducedMotion(true);
        expect(tester.state(find.byType(SkeletonBox)), same(state));
        expect(_opacity(tester), closeTo(0.625, 0.000001));
        expect(tester.binding.transientCallbackCount, 0);
        await tester.pump(const Duration(milliseconds: 1800));
        expect(_opacity(tester), closeTo(0.625, 0.000001));
        expect(tester.binding.transientCallbackCount, 0);

        await setReducedMotion(false);
        expect(tester.state(find.byType(SkeletonBox)), same(state));
        expect(tester.binding.transientCallbackCount, 1);
        await tester.pump();
        final resumed = _opacity(tester);
        await tester.pump(const Duration(milliseconds: 300));
        expect(_opacity(tester), isNot(closeTo(resumed, 0.000001)));
        expect(tester.binding.transientCallbackCount, 1);
      }

      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    });
  }

  for (final circular in [false, true]) {
    testWidgets('preserves geometry with circular=$circular in both modes', (
      tester,
    ) async {
      for (final disabled in [false, true]) {
        await tester.pumpWidget(
          _host(
            disableAnimations: disabled,
            child: SkeletonBox(width: 160, height: 24, circular: circular),
          ),
        );
        final containerFinder = find.descendant(
          of: find.byType(SkeletonBox),
          matching: find.byType(Container),
        );
        final container = tester.widget<Container>(containerFinder);
        final decoration = container.decoration! as BoxDecoration;
        expect(tester.getSize(containerFinder), const Size(160, 24));
        expect(
          decoration.shape,
          circular ? BoxShape.circle : BoxShape.rectangle,
        );
        expect(
          decoration.borderRadius,
          circular ? isNull : BorderRadius.circular(3),
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('system reduced motion renders a static loading placeholder', (
    tester,
  ) async {
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(
      tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );
    await tester.pumpWidget(
      MediaQuery.fromView(
        view: tester.view,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: SkeletonBox(width: 160, height: 24)),
        ),
      ),
    );
    expect(
      MediaQuery.disableAnimationsOf(tester.element(find.byType(SkeletonBox))),
      isTrue,
    );
    final initial = _opacity(tester);

    await tester.pump(const Duration(milliseconds: 600));

    expect(_opacity(tester), initial);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
