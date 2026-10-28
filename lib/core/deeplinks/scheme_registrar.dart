import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:talker_flutter/talker_flutter.dart';

/// Регистрирует схему `waveform://` в ОС на Windows и Linux при запуске: ни
/// установщика, ни пакета у нас нет (zip / tar.gz), так что это единственный
/// способ получить системный хэндлер. На macOS схема объявлена в Info.plist.
///
/// Только релизные сборки: debug-бинарник не должен перехватывать схему у
/// установленной версии.
class SchemeRegistrar {
  const SchemeRegistrar({required this.executable, required this.talker});

  /// Путь к исполняемому файлу, на который указывает регистрация.
  final String executable;
  final Talker talker;

  static const scheme = 'waveform';
  static const desktopFileName = 'com.waveform.waveform_app.desktop';

  Future<void> register() async {
    if (!kReleaseMode) return;
    try {
      if (Platform.isWindows) await _registerWindows();
      if (Platform.isLinux) await _registerLinux();
    } catch (e, st) {
      talker.warning('scheme registration failed', e, st);
    }
  }

  /// Значение `shell\open\command`: исполняемый файл и ссылка аргументом.
  @visibleForTesting
  String get windowsCommand => '"$executable" "%1"';

  Future<void> _registerWindows() async {
    const key = r'HKCU\Software\Classes\waveform';
    final current = await Process.run('reg', [
      'query',
      '$key\\shell\\open\\command',
      '/ve',
    ]);
    if (current.exitCode == 0 &&
        (current.stdout as String).contains(windowsCommand)) {
      return;
    }
    final writes = <List<String>>[
      ['add', key, '/ve', '/d', 'URL:Waveform', '/f'],
      ['add', key, '/v', 'URL Protocol', '/d', '', '/f'],
      ['add', '$key\\shell\\open\\command', '/ve', '/d', windowsCommand, '/f'],
    ];
    for (final args in writes) {
      final r = await Process.run('reg', args);
      if (r.exitCode != 0) {
        throw ProcessException('reg', args, '${r.stderr}', r.exitCode);
      }
    }
  }

  /// Содержимое `.desktop` с обработчиком схемы. `%u` — сюда ОС кладёт ссылку.
  @visibleForTesting
  String get desktopEntry =>
      '[Desktop Entry]\n'
      'Type=Application\n'
      'Name=Waveform\n'
      'Comment=Minimal SoundCloud client\n'
      'Exec="$executable" %u\n'
      'Terminal=false\n'
      'Categories=AudioVideo;Audio;Player;\n'
      'MimeType=x-scheme-handler/$scheme;\n';

  Future<void> _registerLinux() async {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return;
    final dir = Directory('$home/.local/share/applications');
    final file = File('${dir.path}/$desktopFileName');
    if (await file.exists() && await file.readAsString() == desktopEntry) {
      return;
    }
    await dir.create(recursive: true);
    await file.writeAsString(desktopEntry);
    await Process.run('xdg-mime', [
      'default',
      desktopFileName,
      'x-scheme-handler/$scheme',
    ]);
    // Не везде есть: без него кэш обновится при следующем логине.
    try {
      await Process.run('update-desktop-database', [dir.path]);
    } on ProcessException {
      return;
    }
  }
}
