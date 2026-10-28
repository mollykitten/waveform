import 'dart:async';
import 'dart:io';

import 'package:auto_updater/auto_updater.dart';
import 'package:dio/dio.dart';

import '../../shared/url_share.dart';
import 'app_version.dart';

/// Результат ручной проверки.
enum UpdateOutcome { upToDate, available, unknown, failed }

/// Что случилось после «update» на Linux.
enum UpdateInstall { started, openedReleasePage }

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
class SparkleUpdateBackend with UpdaterListener implements UpdateBackend {
  SparkleUpdateBackend({this.log});

  /// Пишет события апдейтера в лог приложения (Sparkle сам глотает ошибки
  /// старта).
  final void Function(String message)? log;

  /// Подмена фида на время локальной проверки:
  /// `--dart-define=UPDATE_FEED_URL=http://127.0.0.1:8765/appcast-macos.xml`.
  static const _feedOverride = String.fromEnvironment('UPDATE_FEED_URL');

  static const _feedBase =
      'https://github.com/mollykitten/waveform/releases/latest/download/';
  static const windowsFeedUrl = '${_feedBase}appcast-windows.xml';
  static const macosFeedUrl = '${_feedBase}appcast-macos.xml';

  bool _ready = false;

  Future<void> _init() async {
    if (_ready) return;
    autoUpdater.addListener(this);
    await autoUpdater.setFeedURL(
      _feedOverride.isNotEmpty
          ? _feedOverride
          : (Platform.isWindows ? windowsFeedUrl : macosFeedUrl),
    );
    // собственный суточный гейт живёт в UpdateController
    await autoUpdater.setScheduledCheckInterval(0);
    _ready = true;
  }

  @override
  void onUpdaterError(UpdaterError? error) => log?.call('error: $error');
  @override
  void onUpdaterCheckingForUpdate(Appcast? appcast) =>
      log?.call('checking for update');
  @override
  void onUpdaterUpdateAvailable(AppcastItem? appcastItem) =>
      log?.call('update available: ${appcastItem?.displayVersionString}');
  @override
  void onUpdaterUpdateNotAvailable(UpdaterError? error) =>
      log?.call('no update available');
  @override
  void onUpdaterUpdateDownloaded(AppcastItem? appcastItem) =>
      log?.call('update downloaded');
  @override
  void onUpdaterBeforeQuitForUpdate(AppcastItem? appcastItem) =>
      log?.call('quitting to install the update');

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
    this.log,
  }) : _dio = dio ?? Dio(),
       _env = environment ?? Platform.environment;

  static const latestReleaseApi =
      'https://api.github.com/repos/mollykitten/waveform/releases/latest';

  final Dio _dio;
  final String currentVersion;
  final Map<String, String> _env;
  final Future<Process> Function(String, List<String>) run;
  final Future<void> Function(String) open;
  final void Function(String message)? log;
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
    } on DioException catch (e) {
      log?.call('release check failed: ${e.message ?? e.type}');
      return UpdateOutcome.failed;
    }
  }

  /// Ставит найденное обновление: на месте для AppImage, иначе страница
  /// релиза.
  Future<UpdateInstall> installAvailable() async {
    final appImage = _env['APPIMAGE'];
    if (appImage != null && appImage.isNotEmpty && _hasAppImageUpdateTool()) {
      final process = await run('appimageupdatetool', [
        '--overwrite',
        appImage,
      ]);
      // выводы надо вычитывать, иначе долгая загрузка забьёт пайп и встанет
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      unawaited(process.exitCode);
      return UpdateInstall.started;
    }
    await open(kReleasesPageUrl);
    return UpdateInstall.openedReleasePage;
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
