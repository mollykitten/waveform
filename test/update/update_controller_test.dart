import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/storage/prefs_store.dart';
import 'package:waveform_app/core/update/update_backend.dart';
import 'package:waveform_app/core/update/update_controller.dart';

class _FakeBackend implements UpdateBackend {
  UpdateOutcome outcome = UpdateOutcome.upToDate;
  Object? error;
  int background = 0;
  int manual = 0;
  @override
  String? availableVersion;

  Future<UpdateOutcome> _answer() async {
    if (error != null) throw error!;
    return outcome;
  }

  @override
  Future<UpdateOutcome> checkInBackground() {
    background++;
    return _answer();
  }

  @override
  Future<UpdateOutcome> checkNow() {
    manual++;
    return _answer();
  }
}

void main() {
  late Directory dir;
  late PrefsStore store;
  late _FakeBackend backend;
  late ProviderContainer container;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('update_prefs');
    store = PrefsStore(directory: () async => dir);
    backend = _FakeBackend();
    container = ProviderContainer(
      overrides: [
        updatePrefsStoreProvider.overrideWithValue(store),
        updateBackendProvider.overrideWithValue(backend),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    dir.deleteSync(recursive: true);
  });

  UpdateController controller() =>
      container.read(updateControllerProvider.notifier);

  final t0 = DateTime.utc(2026, 10, 28, 12);

  test('first auto check runs and records the time', () async {
    await controller().autoCheck(now: t0);

    expect(backend.background, 1);
    expect(container.read(updateControllerProvider).lastCheck, t0);
    expect(
      DateTime.parse((await store.readString(UpdateController.prefsKey))!),
      t0,
    );
  });

  test('a second auto check within 24 hours is skipped', () async {
    await controller().autoCheck(now: t0);
    await controller().autoCheck(now: t0.add(const Duration(hours: 23)));

    expect(backend.background, 1);
    expect(container.read(updateControllerProvider).lastCheck, t0);
  });

  test('after 24 hours it checks again', () async {
    await controller().autoCheck(now: t0);
    final later = t0.add(const Duration(hours: 24));
    await controller().autoCheck(now: later);

    expect(backend.background, 2);
    expect(container.read(updateControllerProvider).lastCheck, later);
  });

  test('a failed check does not count: the next start retries', () async {
    backend.outcome = UpdateOutcome.failed;
    await controller().autoCheck(now: t0);

    expect(await store.readString(UpdateController.prefsKey), isNull);
    expect(container.read(updateControllerProvider).lastCheck, isNull);
    expect(container.read(updateControllerProvider).checking, isFalse);

    backend.outcome = UpdateOutcome.upToDate;
    await controller().autoCheck(now: t0.add(const Duration(minutes: 5)));
    expect(backend.background, 2);
  });

  test('a throwing backend leaves no record and no spinner', () async {
    backend.error = StateError('boom');
    await controller().autoCheck(now: t0);

    expect(await store.readString(UpdateController.prefsKey), isNull);
    expect(container.read(updateControllerProvider).checking, isFalse);
  });

  test('manual check ignores the gate and shows the found version', () async {
    await controller().autoCheck(now: t0);
    backend
      ..outcome = UpdateOutcome.available
      ..availableVersion = '0.5.0';
    await controller().checkNow();

    expect(backend.manual, 1);
    expect(container.read(updateControllerProvider).available, '0.5.0');
  });
}
