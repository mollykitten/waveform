import 'dart:io';

import 'package:auto_updater/auto_updater.dart';
import 'package:dio/dio.dart';

import '../../shared/url_share.dart';
import 'app_version.dart';

/// Результат ручной проверки.
enum UpdateOutcome { upToDate, available, unknown }

/// Один способ проверять и ставить обновления на своей платформе.
abstract class UpdateBackend {
  /// Тихая проверка при старте: Sparkle показывает окно только если есть
  /// обновление.
  Future<UpdateOutcome> checkInBackground();

  /// Проверка по кнопке: нативный бэкенд сам показывает диалог.
  Future<UpdateOutcome> checkNow();

  /// Версия, о которой знает бэкенд (для надписи «доступна vX»); `null` у
  /// нативных бэкендов — они рисуют свой диалог.
  String? get availableVersion => null;
}

/// Под MOCK и в тестах: никакой сети и нативных вызовов.
class NoopUpdateBackend implements UpdateBackend {
  const NoopUpdateBackend();
  @override
  Future<UpdateOutcome> checkInBackground() async => UpdateOutcome.unknown;
  @override
  Future<UpdateOutcome> checkNow() async => UpdateOutcome.unknown;
  @override
  String? get availableVersion => null;
}

/// macOS (Sparkle) и Windows (WinSparkle) через `auto_updater`. Фид на macOS
/// задан в Info.plist (`SUFeedURL`), на Windows — тут.
class SparkleUpdateBackend implements UpdateBackend {
  static const _feedBase =
      'https://github.com/mollykitten/waveform/releases/latest/download/';
  static const windowsFeedUrl = '${_feedBase}appcast-windows.xml';
  static const macosFeedUrl = '${_feedBase}appcast-macos.xml';

  bool _ready = false;

  Future<void> _init() async {
    if (_ready) return;
    await autoUpdater.setFeedURL(
      Platform.isWindows ? windowsFeedUrl : macosFeedUrl,
    );
    // собственный суточный гейт живёт в UpdateController
    await autoUpdater.setScheduledCheckInterval(0);
    _ready = true;
  }

  @override
  Future<UpdateOutcome> checkInBackground() async {
    await _init();
    await autoUpdater.checkForUpdates(inBackground: true);
    return UpdateOutcome.unknown;
  }

  @override
  Future<UpdateOutcome> checkNow() async {
    await _init();
    await autoUpdater.checkForUpdates(inBackground: false);
    return UpdateOutcome.unknown;
  }

  @override
  String? get availableVersion => null;
}

/// Linux: у `auto_updater` нет бэкенда, поэтому смотрим последний релиз через
/// GitHub Releases API. Из AppImage с `appimageupdatetool` в PATH обновляем
/// на месте, иначе открываем страницу релиза.
class GithubUpdateBackend implements UpdateBackend {
  GithubUpdateBackend({
    Dio? dio,
    this.currentVersion = kAppVersion,
    Map<String, String>? environment,
    this.run = Process.start,
    this.open = openExternalUrl,
  }) : _dio = dio ?? Dio(),
       _env = environment ?? Platform.environment;

  static const latestReleaseApi =
      'https://api.github.com/repos/mollykitten/waveform/releases/latest';

  final Dio _dio;
  final String currentVersion;
  final Map<String, String> _env;
  final Future<Process> Function(String, List<String>) run;
  final Future<void> Function(String) open;
  String? _available;

  @override
  String? get availableVersion => _available;

  @override
  Future<UpdateOutcome> checkInBackground() => _check();

  @override
  Future<UpdateOutcome> checkNow() => _check();

  Future<UpdateOutcome> _check() async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        latestReleaseApi,
        options: Options(
          headers: {'Accept': 'application/vnd.github+json'},
          receiveTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 10),
        ),
      );
      final tag = res.data?['tag_name'];
      if (tag is! String || !isNewerVersion(tag, currentVersion)) {
        _available = null;
        return UpdateOutcome.upToDate;
      }
      _available = tag.startsWith('v') ? tag.substring(1) : tag;
      return UpdateOutcome.available;
    } on DioException {
      return UpdateOutcome.unknown;
    }
  }

  /// Ставит найденное обновление: на месте для AppImage, иначе страница
  /// релиза. `true`, если запущен апдейтер.
  Future<bool> installAvailable() async {
    final appImage = _env['APPIMAGE'];
    if (appImage != null && appImage.isNotEmpty && _hasAppImageUpdateTool()) {
      await run('appimageupdatetool', [appImage]);
      return true;
    }
    await open(kReleasesPageUrl);
    return false;
  }

  bool _hasAppImageUpdateTool() {
    final sep = Platform.isWindows ? ';' : ':';
    for (final dir in (_env['PATH'] ?? '').split(sep)) {
      if (dir.isNotEmpty && File('$dir/appimageupdatetool').existsSync()) {
        return true;
      }
    }
    return false;
  }
}
