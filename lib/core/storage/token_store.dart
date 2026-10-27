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
  const TokenStore({this.directory});

  final Future<Directory> Function()? directory;

  static const _fileName = 'sc_oauth_token';

  Future<File> _file() async {
    final dir = await (directory ?? getApplicationSupportDirectory)();
    return File('${dir.path}/$_fileName');
  }

  Future<String?> read() async {
    final f = await _file();
    if (!await f.exists()) return null;
    final v = (await f.readAsString()).trim();
    return v.isEmpty ? null : v;
  }

  Future<void> write(String token) async =>
      writeFileAtomic(await _file(), token);

  Future<void> delete() async {
    final f = await _file();
    if (await f.exists()) await f.delete();
  }
}
