import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'atomic_file.dart';

/// Простое локальное хранилище OAuth-токена.
///
/// Раньше использовали `flutter_secure_storage` (Keychain), но на macOS с
/// app-sandbox без development-сертификата он либо не персистит, либо валит
/// сборку (`keychain-access-groups` требует подписанной команды разработчика).
/// Для OSS-десктопа кладём токен файлом в `getApplicationSupportDirectory()`
/// — это контейнер приложения (sandboxed, доступен только этому приложению и
/// текущему пользователю). Файл пишется атомарно (temp + rename) с правами
/// 0600 на POSIX. OAuth-токен SoundCloud легко отзывается.
class TokenStore {
  /// [directory] подменяет каталог в тестах (path_provider там не отвечает).
  const TokenStore({this.directory, this.chmod = chmodOwnerOnly});

  final Future<Directory> Function()? directory;
  final Future<void> Function(String path) chmod;

  static const _fileName = 'sc_oauth_token';

  /// Маркер «пользователь вышел», если файл токена удалить не удалось: пока он
  /// есть, [read] не отдаёт токен и повторяет удаление.
  static const _markerSuffix = '.signed_out';

  /// read/write/delete идут одной цепочкой на процесс: токен читают и вне
  /// AuthController (listening_providers), а чтение чистит `.tmp` — оно не
  /// должно задеть temp-файл идущей записи.
  static Future<void> _tail = Future<void>.value();

  Future<T> _serialize<T>(Future<T> Function() op) {
    final run = _tail.then((_) => op());
    _tail = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<File> _file() async {
    final dir = await (directory ?? getApplicationSupportDirectory)();
    return File('${dir.path}/$_fileName');
  }

  Future<String?> read() => _serialize(_read);

  Future<String?> _read() async {
    final f = await _file();
    final marker = File('${f.path}$_markerSuffix');
    if (await marker.exists()) {
      try {
        await _removeFiles(f);
        await marker.delete();
      } catch (_) {
        // всё ещё не удаляется — токен не отдаём
      }
      return null;
    }
    // Остаток прерванной записи не должен жить на диске.
    await _deleteIfExists(File('${f.path}.tmp'));
    if (!await f.exists()) return null;
    final v = (await f.readAsString()).trim();
    return v.isEmpty ? null : v;
  }

  Future<void> write(String token) => _serialize(() => _write(token));

  Future<void> _write(String token) async {
    final f = await _file();
    final marker = File('${f.path}$_markerSuffix');
    await _deleteIfExists(marker);
    await writeFileAtomic(f, token, chmod: chmod);
  }

  /// Удаляет токен и остаток temp-файла (с одним повтором). Если не вышло —
  /// ставит маркер выхода и бросает ошибку, чтобы вызвавший её залогировал.
  Future<void> delete() => _serialize(_delete);

  Future<void> _delete() async {
    final f = await _file();
    try {
      await _removeFiles(f);
    } catch (_) {
      try {
        await File('${f.path}$_markerSuffix').writeAsString('1', flush: true);
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _removeFiles(File f) async {
    for (var attempt = 0; ; attempt++) {
      try {
        await _deleteIfExists(f);
        await _deleteIfExists(File('${f.path}.tmp'));
        return;
      } on FileSystemException {
        if (attempt >= 1) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  Future<void> _deleteIfExists(File f) async {
    if (await f.exists()) await f.delete();
  }
}
