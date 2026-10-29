import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../log/talker.dart';
import '../storage/prefs_store.dart';
import 'update_backend.dart';

/// Состояние проверки обновлений для экрана настроек.
class UpdateState {
  const UpdateState({this.lastCheck, this.checking = false, this.available});
  final DateTime? lastCheck;
  final bool checking;

  /// Версия, найденная Linux-бэкендом; у Sparkle всегда `null`.
  final String? available;

  UpdateState copyWith({
    DateTime? lastCheck,
    bool? checking,
    String? available,
    bool clearAvailable = false,
  }) => UpdateState(
    lastCheck: lastCheck ?? this.lastCheck,
    checking: checking ?? this.checking,
    available: clearAvailable ? null : (available ?? this.available),
  );
}

/// Выбор бэкенда по платформе. Под `--dart-define=MOCK=true` — no-op.
final updateBackendProvider = Provider<UpdateBackend>((ref) {
  // MOCK и `flutter test` (FLUTTER_TEST) — полный no-op, без сети и плагинов.
  if (const bool.fromEnvironment('MOCK') ||
      Platform.environment.containsKey('FLUTTER_TEST')) {
    return const NoopUpdateBackend();
  }
  if (Platform.isMacOS || Platform.isWindows) {
    final talker = ref.watch(talkerProvider);
    return SparkleUpdateBackend(log: (m) => talker.info('update: $m'));
  }
  if (Platform.isLinux) {
    final talker = ref.watch(talkerProvider);
    return GithubUpdateBackend(log: (m) => talker.warning('update: $m'));
  }
  return const NoopUpdateBackend();
});

/// Где живёт время последней проверки; в тестах подменяется каталогом.
final updatePrefsStoreProvider = Provider<PrefsStore>(
  (ref) => const PrefsStore(),
);

class UpdateController extends Notifier<UpdateState> {
  PrefsStore get _store => ref.read(updatePrefsStoreProvider);
  static const prefsKey = 'updateLastCheck';
  static const interval = Duration(hours: 24);

  @override
  UpdateState build() => const UpdateState();

  /// Автопроверка при старте: не чаще раза в сутки.
  Future<void> autoCheck({DateTime? now}) async {
    final backend = ref.read(updateBackendProvider);
    if (backend is NoopUpdateBackend) return;
    final last = await _readLastCheck();
    final at = now ?? DateTime.now();
    if (last != null && at.difference(last) < interval) {
      state = state.copyWith(lastCheck: last);
      return;
    }
    await _run(() => backend.checkInBackground(), at);
  }

  /// Кнопка «check for updates».
  Future<UpdateOutcome?> checkNow() async {
    final backend = ref.read(updateBackendProvider);
    if (backend is NoopUpdateBackend || state.checking) return null;
    return _run(() => backend.checkNow(), DateTime.now());
  }

  /// Linux: поставить найденное обновление.
  Future<UpdateInstall?> installAvailable() async {
    final backend = ref.read(updateBackendProvider);
    if (backend is! GithubUpdateBackend) return null;
    return backend.installAvailable();
  }

  Future<UpdateOutcome> _run(
    Future<UpdateOutcome> Function() op,
    DateTime at,
  ) async {
    state = state.copyWith(checking: true);
    try {
      final outcome = await op();
      if (outcome == UpdateOutcome.failed) {
        // сбой сети не считается проверкой: следующий запуск попробует снова
        state = state.copyWith(checking: false);
        return outcome;
      }
      final backend = ref.read(updateBackendProvider);
      state = state.copyWith(
        checking: false,
        lastCheck: at,
        available: backend.availableVersion,
        clearAvailable: backend.availableVersion == null,
      );
      await _writeLastCheck(at);
      return outcome;
    } catch (e, st) {
      ref.read(talkerProvider).warning('update check failed', e, st);
      state = state.copyWith(checking: false);
      return UpdateOutcome.failed;
    }
  }

  Future<DateTime?> _readLastCheck() async {
    try {
      final raw = await _store.readString(prefsKey);
      return raw == null ? null : DateTime.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeLastCheck(DateTime at) async {
    try {
      await _store.writeString(prefsKey, at.toUtc().toIso8601String());
    } catch (_) {
      // нет path_provider в тестах — не критично
    }
  }
}

final updateControllerProvider =
    NotifierProvider<UpdateController, UpdateState>(UpdateController.new);
