import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:waveform_app/app/router.dart';
import 'package:waveform_app/core/storage/prefs_store.dart';
import 'package:waveform_app/features/onboarding/onboarding_gate.dart';
import 'package:waveform_app/features/onboarding/onboarding_screen.dart';

/// In-memory prefs: widget callbacks run in the fake-async zone, where the
/// file-backed store's real IO would never complete.
class _MemoryPrefs extends PrefsStore {
  final values = <String, bool>{};

  @override
  Future<bool?> readBool(String key) async => values[key];

  @override
  Future<void> writeBool(String key, bool value) async => values[key] = value;
}

void main() {
  late Directory dir;
  late PrefsStore store;
  late _MemoryPrefs memory;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('onboarding_test');
    store = PrefsStore(directory: () async => dir);
    memory = _MemoryPrefs();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  void useDesktopViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<GoRouter> pumpTour(
    WidgetTester tester,
    OnboardingGate gate, {
    bool reduced = false,
  }) async {
    useDesktopViewport(tester);
    final router = GoRouter(
      initialLocation: '/',
      refreshListenable: gate,
      redirect: onboardingRedirect(gate),
      routes: [
        GoRoute(path: '/', builder: (_, _) => const Text('home')),
        GoRoute(path: '/welcome', builder: (_, _) => const OnboardingScreen()),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [onboardingGateProvider.overrideWithValue(gate)],
        child: MaterialApp.router(
          routerConfig: router,
          builder: (_, child) => MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pump();
    return router;
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('first launch redirects to the onboarding', (tester) async {
    final gate = OnboardingGate(store: memory, seen: false);
    addTearDown(gate.dispose);
    await pumpTour(tester, gate);

    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(find.text('01 / 05 · welcome'), findsOneWidget);
    expect(find.text('home'), findsNothing);
  });

  testWidgets('a seen onboarding opens straight on /', (tester) async {
    final gate = OnboardingGate(store: memory);
    addTearDown(gate.dispose);
    await pumpTour(tester, gate);

    expect(find.text('home'), findsOneWidget);
    expect(find.byType(OnboardingScreen), findsNothing);
  });

  testWidgets('the real router guards every route until seen', (tester) async {
    useDesktopViewport(tester);
    onboardingGate.value = false;
    addTearDown(() => onboardingGate.value = true);
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: appRouter)),
    );
    appRouter.go('/library');
    await tester.pump();
    await tester.pump();

    expect(find.byType(OnboardingScreen), findsOneWidget);
  });

  testWidgets('buttons, keys and dots walk the five steps', (tester) async {
    final gate = OnboardingGate(store: memory, seen: false);
    addTearDown(gate.dispose);
    await pumpTour(tester, gate);

    await tester.tap(find.text('get started'));
    await settle(tester);
    expect(find.text('02 / 05 · account'), findsOneWidget);
    expect(find.text('back'), findsOneWidget);

    await tester.tap(find.text('continue'));
    await settle(tester);
    expect(find.text('03 / 05 · my wave'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    expect(find.text('04 / 05 · shortcuts'), findsOneWidget);
    expect(find.text('finish'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await settle(tester);
    expect(find.text('03 / 05 · my wave'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('go to ready'));
    await settle(tester);
    expect(find.text('05 / 05 · ready'), findsOneWidget);
    expect(find.text('start listening'), findsOneWidget);
    expect(find.text('back'), findsNothing);
  });

  testWidgets('start listening stores the flag and opens /', (tester) async {
    final gate = OnboardingGate(store: memory, seen: false);
    addTearDown(gate.dispose);
    await pumpTour(tester, gate);
    await tester.tap(find.text('get started'));
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('go to ready'));
    await settle(tester);

    await tester.tap(find.text('start listening'));
    await settle(tester);

    expect(find.text('home'), findsOneWidget);
    expect(gate.value, isTrue);
    expect(memory.values[OnboardingGate.prefsKey], isTrue);
  });

  testWidgets('escape skips and stores the flag', (tester) async {
    final gate = OnboardingGate(store: memory, seen: false);
    addTearDown(gate.dispose);
    await pumpTour(tester, gate);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    expect(find.text('home'), findsOneWidget);
    expect(memory.values[OnboardingGate.prefsKey], isTrue);
  });

  testWidgets('reset clears the flag and returns to the tour', (tester) async {
    final gate = OnboardingGate(store: memory);
    addTearDown(gate.dispose);
    await pumpTour(tester, gate);
    expect(find.text('home'), findsOneWidget);

    await gate.reset();
    await settle(tester);

    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(memory.values[OnboardingGate.prefsKey], isFalse);
  });

  testWidgets('restore reads the stored flag', (tester) async {
    final gate = OnboardingGate(store: store);
    addTearDown(gate.dispose);
    await tester.runAsync(gate.restore);
    expect(gate.value, isFalse);

    await tester.runAsync(gate.complete);
    final fresh = OnboardingGate(store: store, seen: false);
    addTearDown(fresh.dispose);
    await tester.runAsync(fresh.restore);
    expect(fresh.value, isTrue);
  });

  testWidgets('reduced motion renders every step without animating', (
    tester,
  ) async {
    final gate = OnboardingGate(store: memory, seen: false);
    addTearDown(gate.dispose);
    await pumpTour(tester, gate, reduced: true);

    for (final step in ['get started', 'continue', 'continue', 'finish']) {
      expect(find.text(step), findsOneWidget);
      await tester.tap(find.text(step));
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
    expect(find.text('start listening'), findsOneWidget);
    // Nothing is left animating: a settle must not time out.
    await tester.pumpAndSettle();
  });
}
