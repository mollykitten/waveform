import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/app/theme/app_theme.dart';
import 'package:waveform_app/shared/models/collection.dart';
import 'package:waveform_app/shared/widgets/collection_card.dart';

void main() {
  for (final reducedMotion in [true, false]) {
    testWidgets('collection hover fade, reduced=$reducedMotion', (
      tester,
    ) async {
      final motion = ValueNotifier(reducedMotion);
      addTearDown(motion.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: motion,
            builder: (_, reduced, child) => MediaQuery(
              data: MediaQueryData(disableAnimations: reduced),
              child: child!,
            ),
            child: const Scaffold(
              body: Center(
                child: CollectionCard(
                  item: Collection(
                    id: 'test',
                    title: 'collection',
                    subtitle: 'artist',
                    kind: CollectionKind.playlist,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.addPointer(location: const Offset(0, 0));
      addTearDown(pointer.removePointer);
      final fade = find
          .descendant(
            of: find.byType(CollectionCard),
            matching: find.byType(FadeTransition),
          )
          .first;
      await pointer.moveTo(tester.getCenter(find.byType(CollectionCard)));
      await tester.pump();
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).duration,
        reducedMotion ? Duration.zero : AppTheme.motion,
      );
      await tester.pump();
      expect(
        tester.widget<FadeTransition>(fade).opacity.value,
        reducedMotion ? 1 : 0,
      );
      await tester.pumpAndSettle();
      expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
      await pointer.moveTo(const Offset(0, 0));
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<FadeTransition>(fade).opacity.value,
        reducedMotion ? 0 : 1,
      );
      await tester.pumpAndSettle();
      expect(tester.widget<FadeTransition>(fade).opacity.value, 0);
      if (!reducedMotion) {
        await pointer.moveTo(tester.getCenter(find.byType(CollectionCard)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          tester.widget<FadeTransition>(fade).opacity.value,
          inExclusiveRange(0, 1),
        );
        motion.value = true;
        await tester.pump();
        expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
      }
    });
  }
}
