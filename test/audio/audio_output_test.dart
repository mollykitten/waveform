import 'dart:async';

import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/audio/audio_output.dart';
import 'package:waveform_app/features/player/widgets/audio_output_picker.dart';

Map<String, Object?> snapshot({String? uid, bool preserve = false}) => {
  'supported': true,
  'devices': [
    {'uid': 'usb', 'name': 'USB speakers', 'transport': 'usb'},
  ],
  'requestedUid': uid,
  'effectiveUid': uid ?? 'built-in',
  'preservePlayer': preserve,
  'airPlayActive': false,
};

class FakeOutput implements AudioOutputPlatform {
  FakeOutput({this.supported = true});
  @override
  final bool supported;
  final controller = StreamController<Object?>.broadcast();
  final selected = <String?>[];
  Completer<Object?>? pendingSelection;
  Completer<Object?>? pendingAirPlay;
  Object? failure;
  int airPlayCalls = 0;
  @override
  Stream<Object?> get events => controller.stream;
  @override
  Future<Object?> getState() async => snapshot();
  @override
  Future<Object?> setDevice(String? uid) async {
    selected.add(uid);
    if (failure case final error?) throw error;
    return pendingSelection?.future ?? Future.value(snapshot(uid: uid));
  }

  @override
  Future<Object?> showAirPlay() async {
    airPlayCalls++;
    if (failure case final error?) throw error;
    return pendingAirPlay?.future ?? Future.value(snapshot(preserve: true));
  }
}

class MemoryPreferences implements AudioOutputPreferences {
  Completer<String?>? pendingRead;
  final writes = <String?>[];
  @override
  Future<String?> read() async => pendingRead?.future;
  @override
  Future<void> write(String? uid) async => writes.add(uid);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeOutput platform;
  late MemoryPreferences preferences;
  late ProviderContainer container;

  setUp(() {
    platform = FakeOutput();
    preferences = MemoryPreferences();
    container = ProviderContainer(
      overrides: [
        audioOutputPlatformProvider.overrideWithValue(platform),
        audioOutputPreferencesProvider.overrideWithValue(preferences),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await platform.controller.close();
  });

  Future<void> initialize() async {
    container.read(audioOutputProvider);
    await Future<void>.delayed(Duration.zero);
  }

  test('decodes real devices and preserves unknown disconnected UID', () {
    final state = AudioOutputState.fromMap({
      ...snapshot(uid: 'disconnected'),
      'devices': [
        {'uid': 'new', 'name': 'Future device', 'transport': 123},
        {'name': 'malformed'},
      ],
    });
    expect(state.devices.single.transport, 'unknown');
    expect(state.requestedUid, 'disconnected');
    expect(state.selectedName, contains('unavailable'));
    expect(state.effectiveUid, 'disconnected');
  });

  test(
    'production preferences leave persistence to the native snapshot',
    () async {
      const preferences = NativeAudioOutputPreferences();
      await preferences.write('stale-dart-device');
      expect(await preferences.read(), isNull);
      final nativeState = AudioOutputState.fromMap(snapshot(uid: 'usb'));
      expect(nativeState.requestedUid, 'usb');
    },
  );

  test('new selection wins over delayed preference restoration', () async {
    preferences.pendingRead = Completer<String?>();
    await initialize();
    await container.read(audioOutputProvider.notifier).selectDevice('usb');
    preferences.pendingRead!.complete('old');
    await Future<void>.delayed(Duration.zero);
    expect(platform.selected, ['usb']);
    expect(container.read(audioOutputProvider).requestedUid, 'usb');
    expect(preferences.writes, ['usb']);
  });

  test('unknown preserved route does not claim system default or AirPlay', () {
    final state = AudioOutputState.fromMap({
      ...snapshot(preserve: true),
      'effectiveUid': null,
    });
    expect(state.selectedName, 'route unconfirmed');
  });

  test('serializes selections and ignores superseded response', () async {
    await initialize();
    final firstReply = Completer<Object?>();
    platform.pendingSelection = firstReply;
    final controller = container.read(audioOutputProvider.notifier);
    final first = controller.selectDevice('old');
    await Future<void>.delayed(Duration.zero);
    final second = controller.selectDevice('usb');
    platform.pendingSelection = null;
    firstReply.complete(snapshot(uid: 'old'));
    await Future.wait([first, second]);
    expect(platform.selected, ['old', 'usb']);
    expect(container.read(audioOutputProvider).requestedUid, 'usb');
    expect(preferences.writes, ['usb']);
  });

  test(
    'AirPlay retains player synchronously and clears local preference',
    () async {
      await initialize();
      final controller = container.read(audioOutputProvider.notifier);
      final operation = controller.showAirPlay();
      expect(controller.preservePlayer, isTrue);
      expect(platform.airPlayCalls, 0);
      await operation;
      expect(preferences.writes, [null]);
      platform.controller.add(snapshot());
      await Future<void>.delayed(Duration.zero);
      expect(controller.preservePlayer, isTrue);
      await controller.selectDevice('usb');
      expect(controller.preservePlayer, isFalse);
    },
  );

  test(
    'disposal ignores outstanding response and does not persist it',
    () async {
      await initialize();
      platform.pendingSelection = Completer<Object?>();
      final operation = container
          .read(audioOutputProvider.notifier)
          .selectDevice('usb');
      await Future<void>.delayed(Duration.zero);
      container.dispose();
      platform.pendingSelection!.complete(snapshot(uid: 'usb'));
      await operation;
      expect(preferences.writes, isEmpty);
      // A second dispose is safe for ProviderContainer.
    },
  );

  test(
    'failed selection keeps real route and displays readable error',
    () async {
      await initialize();
      platform.failure = PlatformException(
        code: 'failed',
        message: 'uid-secret',
      );
      await container.read(audioOutputProvider.notifier).selectDevice('usb');
      final state = container.read(audioOutputProvider);
      expect(state.requestedUid, isNull);
      expect(state.message, contains('Please try again'));
      expect(state.message, isNot(contains('uid-secret')));
      expect(preferences.writes, isEmpty);
    },
  );

  for (final airPlay in [false, true]) {
    test(
      'hotplug snapshot wins over delayed reply: AirPlay=$airPlay',
      () async {
        await initialize();
        final reply = Completer<Object?>();
        if (airPlay) {
          platform.pendingAirPlay = reply;
        } else {
          platform.pendingSelection = reply;
        }
        final controller = container.read(audioOutputProvider.notifier);
        final operation = airPlay
            ? controller.showAirPlay()
            : controller.selectDevice('usb');
        await Future<void>.delayed(Duration.zero);
        platform.controller.add({
          ...snapshot(uid: airPlay ? null : 'usb'),
          'devices': <Object?>[],
          'effectiveUid': 'new-default',
          'message': 'device_unavailable',
        });
        await Future<void>.delayed(Duration.zero);
        reply.complete(snapshot(uid: 'stale', preserve: airPlay));
        await operation;
        final state = container.read(audioOutputProvider);
        expect(state.devices, isEmpty);
        expect(state.effectiveUid, 'new-default');
        expect(state.message, 'device_unavailable');
        expect(preferences.writes, [airPlay ? null : 'usb']);
      },
    );
  }

  for (final error in <Object>[
    PlatformException(code: 'no_active_player'),
    PlatformException(code: 'unsupported'),
    MissingPluginException(),
  ]) {
    test(
      'deterministic AirPlay failure restores preservation: $error',
      () async {
        await initialize();
        platform.failure = error;
        final controller = container.read(audioOutputProvider.notifier);
        final operation = controller.showAirPlay();
        expect(controller.preservePlayer, isTrue);
        await operation;
        expect(controller.preservePlayer, isFalse);
        expect(container.read(audioOutputProvider).preservePlayer, isFalse);
        expect(preferences.writes, isEmpty);
      },
    );
  }

  test(
    'deterministic failure retains a prior AirPlay preservation latch',
    () async {
      await initialize();
      final controller = container.read(audioOutputProvider.notifier);
      await controller.showAirPlay();
      platform.failure = PlatformException(code: 'no_active_player');
      await controller.showAirPlay();
      expect(controller.preservePlayer, isTrue);
    },
  );

  test(
    'superseded optimistic AirPlay clicks do not survive rejection',
    () async {
      await initialize();
      platform.failure = PlatformException(code: 'no_active_player');
      final controller = container.read(audioOutputProvider.notifier);
      final first = controller.showAirPlay();
      final second = controller.showAirPlay();
      expect(controller.preservePlayer, isTrue);
      await Future.wait([first, second]);
      expect(platform.airPlayCalls, 1);
      expect(controller.preservePlayer, isFalse);
      expect(container.read(audioOutputProvider).preservePlayer, isFalse);
    },
  );

  test('ambiguous AirPlay failure retains preservation', () async {
    await initialize();
    platform.failure = PlatformException(code: 'unknown');
    final controller = container.read(audioOutputProvider.notifier);
    await controller.showAirPlay();
    expect(controller.preservePlayer, isTrue);
    expect(preferences.writes, isEmpty);
    platform.failure = PlatformException(code: 'no_active_player');
    await controller.showAirPlay();
    expect(controller.preservePlayer, isTrue);
  });

  test('routing transaction settles binding before native AirPlay', () async {
    await initialize();
    final controller = container.read(audioOutputProvider.notifier);
    final binding = Completer<void>();
    final events = <String>[];
    final transaction = controller.routingTransaction(() async {
      events.add('bind B');
      await binding.future;
      if (controller.preservePlayer) events.add('rebind A');
    });
    await Future<void>.delayed(Duration.zero);
    final picker = controller.showAirPlay();
    expect(controller.preservePlayer, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(platform.airPlayCalls, 0);
    binding.complete();
    await Future.wait([transaction, picker]);
    expect(events, ['bind B', 'rebind A']);
    expect(platform.airPlayCalls, 1);
  });

  test(
    'routing transaction failure does not poison subsequent routing',
    () async {
      await initialize();
      final controller = container.read(audioOutputProvider.notifier);
      await expectLater(
        controller.routingTransaction<void>(
          () async => throw StateError('bind'),
        ),
        throwsStateError,
      );
      await controller.selectDevice('usb');
      expect(platform.selected, ['usb']);
    },
  );

  test('disposal skips queued native routing', () async {
    await initialize();
    final controller = container.read(audioOutputProvider.notifier);
    final binding = Completer<void>();
    final transaction = controller.routingTransaction(() => binding.future);
    await Future<void>.delayed(Duration.zero);
    final picker = controller.showAirPlay();
    await Future<void>.delayed(Duration.zero);
    container.dispose();
    binding.complete();
    await Future.wait([transaction, picker]);
    expect(platform.airPlayCalls, 0);
    expect(preferences.writes, isEmpty);
  });

  test('device events update fallback and reconnect state', () async {
    await initialize();
    platform.controller.add({
      ...snapshot(uid: 'usb'),
      'devices': <Object?>[],
      'effectiveUid': 'built-in',
      'message': 'device_unavailable',
    });
    await Future<void>.delayed(Duration.zero);
    final fallback = container.read(audioOutputProvider);
    expect(fallback.requestedUid, 'usb');
    expect(fallback.effectiveUid, 'built-in');
    expect(fallback.selectedName, contains('unavailable'));
    platform.controller.add(snapshot(uid: 'usb'));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(audioOutputProvider).selectedName, 'USB speakers');
    expect(preferences.writes, isEmpty);
  });

  testWidgets('menu exposes selected name, keyboard access and real devices', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: AudioOutputPicker())),
      ),
    );
    await tester.pump();
    await container.read(audioOutputProvider.notifier).selectDevice('usb');
    await tester.pump();
    expect(find.text('USB speakers'), findsNothing);
    expect(find.byTooltip('Audio output: USB speakers'), findsOneWidget);
    expect(find.bySemanticsLabel('Audio output: USB speakers'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('system default'), findsOneWidget);
    expect(find.text('AirPlay…'), findsOneWidget);
    final usbItem = find.widgetWithText(PopupMenuItem<String>, 'USB speakers');
    final selectedUsb = find.descendant(
      of: usbItem,
      matching: find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.selected == true,
      ),
    );
    expect(selectedUsb, findsOneWidget);
    expect(
      tester.getSemantics(selectedUsb).flagsCollection.isSelected,
      Tristate.isTrue,
    );
    final defaultItem = find.widgetWithText(
      PopupMenuItem<String>,
      'system default',
    );
    final unselectedDefault = find.descendant(
      of: defaultItem,
      matching: find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.selected == false,
      ),
    );
    expect(unselectedDefault, findsOneWidget);
    expect(
      tester.getSemantics(unselectedDefault).flagsCollection.isSelected,
      Tristate.isFalse,
    );
    await tester.tap(
      find.widgetWithText(PopupMenuItem<String>, 'system default'),
    );
    await tester.pumpAndSettle();
    expect(platform.selected, ['usb', null]);
    semantics.dispose();
  });

  testWidgets('unsupported platform has explanation and no fake devices', (
    tester,
  ) async {
    final unsupported = ProviderContainer(
      overrides: [
        audioOutputPlatformProvider.overrideWithValue(
          FakeOutput(supported: false),
        ),
      ],
    );
    addTearDown(unsupported.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: unsupported,
        child: const MaterialApp(home: Scaffold(body: AudioOutputPicker())),
      ),
    );
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    expect(find.textContaining('unavailable on this platform'), findsWidgets);
    expect(find.text('system default'), findsNothing);
    expect(find.text('AirPlay…'), findsNothing);
  });
}
