import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/shared/widgets/toast.dart';

void main() {
  for (final reducedMotion in [true, false]) {
    testWidgets('toast entrance and action, reduced=$reducedMotion', (
      tester,
    ) async {
      late BuildContext toastContext;
      var actions = 0;
      final motion = ValueNotifier(reducedMotion);
      addTearDown(motion.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => ValueListenableBuilder<bool>(
            valueListenable: motion,
            builder: (_, reduced, _) => MediaQuery(
              data: MediaQueryData(disableAnimations: reduced),
              child: child!,
            ),
          ),
          home: Builder(
            builder: (context) {
              toastContext = context;
              return const Scaffold();
            },
          ),
        ),
      );
      showToast(
        toastContext,
        'saved',
        action: (label: 'undo', onTap: () => actions++),
        duration: const Duration(seconds: 1),
      );
      addTearDown(() async {
        await tester.pump(const Duration(seconds: 1));
      });
      await tester.pump();
      final opacity = find.ancestor(
        of: find.text('saved'),
        matching: find.byType(Opacity),
      );
      expect(
        tester.widget<Opacity>(opacity.first).opacity,
        reducedMotion ? 1 : 0,
      );
      await tester.pump(const Duration(milliseconds: 50));
      if (!reducedMotion) {
        expect(
          tester.widget<Opacity>(opacity.first).opacity,
          inExclusiveRange(0, 1),
        );
        motion.value = true;
        await tester.pump();
        expect(tester.widget<Opacity>(opacity.first).opacity, 1);
      }
      await tester.pump(const Duration(milliseconds: 200));
      final actionFocusWidget = tester.widget<Focus>(
        find
            .ancestor(of: find.text('undo'), matching: find.byType(Focus))
            .first,
      );
      actionFocusWidget.focusNode!.requestFocus();
      await tester.pump();
      final actionFocus = FocusManager.instance.primaryFocus;
      expect(actionFocus?.debugLabel, 'Pressable');
      final actionElement = tester.element(find.text('undo'));
      for (final reduced in [false, true, false]) {
        motion.value = reduced;
        await tester.pump();
        expect(tester.widget<Opacity>(opacity.first).opacity, 1);
        expect(FocusManager.instance.primaryFocus, same(actionFocus));
        expect(tester.element(find.text('undo')), same(actionElement));
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(actions, 1);
      expect(find.text('saved'), findsNothing);
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
