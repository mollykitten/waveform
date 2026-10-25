import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:waveform_app/app/router.dart';

void main() {
  testWidgets('enabling reduced motion settles a route and its dismissal', (
    tester,
  ) async {
    final motion = ValueNotifier(false);
    addTearDown(motion.dispose);
    final productionRoute =
        (appRouter.configuration.routes.first as ShellRoute).routes.first
            as GoRoute;
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const Text('base')),
        GoRoute(
          path: '/next',
          pageBuilder: (context, state) {
            final page =
                productionRoute.pageBuilder!(context, state)
                    as CustomTransitionPage<void>;
            return AppTransitionPage(
              key: state.pageKey,
              transitionDuration: page.transitionDuration,
              reverseTransitionDuration: page.reverseTransitionDuration,
              transitionsBuilder: page.transitionsBuilder,
              child: const Text('destination'),
            );
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        builder: (_, child) => ValueListenableBuilder<bool>(
          valueListenable: motion,
          builder: (_, reduced, _) => MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: child!,
          ),
        ),
      ),
    );
    router.push('/next');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(FadeTransition), findsWidgets);
    final destinationElement = tester.element(find.text('destination'));
    motion.value = true;
    await tester.pump();
    final fade = find.ancestor(
      of: find.text('destination'),
      matching: find.byType(FadeTransition),
    );
    expect(tester.widget<FadeTransition>(fade.first).opacity.value, 1);
    expect(tester.element(find.text('destination')), same(destinationElement));
    router.pop();
    await tester.pump();
    await tester.pump();
    expect(find.text('destination'), findsNothing);
  });
  for (final reducedMotion in [true, false]) {
    testWidgets('route entrance and dismissal, reduced=$reducedMotion', (
      tester,
    ) async {
      final productionRoute =
          (appRouter.configuration.routes.first as ShellRoute).routes.first
              as GoRoute;
      late CustomTransitionPage<void> page;
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const Text('base')),
          GoRoute(
            path: '/next',
            pageBuilder: (context, state) {
              page =
                  productionRoute.pageBuilder!(context, state)
                      as CustomTransitionPage<void>;
              // Exercise the real page transition with an isolated screen.
              return AppTransitionPage(
                key: state.pageKey,
                transitionDuration: page.transitionDuration,
                reverseTransitionDuration: page.reverseTransitionDuration,
                transitionsBuilder: page.transitionsBuilder,
                child: const ColoredBox(
                  key: ValueKey('destination'),
                  color: Colors.orange,
                ),
              );
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          builder: (_, child) => MediaQuery(
            data: MediaQueryData(disableAnimations: reducedMotion),
            child: child!,
          ),
        ),
      );
      router.push('/next');
      await tester.pump();
      await tester.pump();

      final destination = find.byKey(const ValueKey('destination'));
      final fades = find.ancestor(
        of: destination,
        matching: find.byType(FadeTransition),
      );
      if (reducedMotion) {
        expect(page.transitionDuration, Duration.zero);
        expect(page.reverseTransitionDuration, Duration.zero);
        expect(tester.widget<FadeTransition>(fades.first).opacity.value, 1);
      } else {
        expect(page.transitionDuration, const Duration(milliseconds: 240));
        expect(
          page.reverseTransitionDuration,
          const Duration(milliseconds: 160),
        );
        expect(tester.widget<FadeTransition>(fades.first).opacity.value, 0);
        await tester.pump(const Duration(milliseconds: 80));
        expect(
          tester.widget<FadeTransition>(fades.first).opacity.value,
          inExclusiveRange(0, 1),
        );
      }
      await tester.pumpAndSettle();
      expect(destination, findsOneWidget);
      router.pop();
      await tester.pump();
      await tester.pump();
      if (reducedMotion) {
        expect(destination, findsNothing);
      } else {
        expect(destination, findsOneWidget);
        await tester.pump(const Duration(milliseconds: 50));
        expect(destination, findsOneWidget);
      }
      await tester.pumpAndSettle();
      expect(destination, findsNothing);
      expect(find.text('base'), findsOneWidget);
    });
  }
}
