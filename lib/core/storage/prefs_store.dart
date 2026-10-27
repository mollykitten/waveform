import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'atomic_file.dart';

/// Простые пользовательские настройки (вид списка, тема, прочее), JSON-файлом
/// в `getApplicationSupportDirectory()` рядом с токеном. Один файл —
/// `prefs.json`, ключи плоские строки.
///
/// Используется и в [ViewModeController], и (в будущем) в экране настроек.
/// В тестах path_provider не отвечает — вызовы оборачивать через `unawaited`.
class PrefsStore {
  /// [directory] подменяет каталог в тестах (path_provider там не отвечает).
  const PrefsStore({this.directory});

  final Future<Directory> Function()? directory;

  static const _fileName = 'prefs.json';

  /// Все операции read-modify-write идут по одной цепочке — параллельные
  /// `writeString`/`remove` не теряют друг друга. Цепочка общая на процесс:
  /// файл один, а экземпляры [PrefsStore] const и без состояния.
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

  /// Битый JSON не затираем: сохраняем копию `.bak`, чтобы настройки можно
  /// было восстановить, и стартуем с пустого набора.
  Future<Map<String, dynamic>> _load() async {
    final f = await _file();
    if (!await f.exists()) return <String, dynamic>{};
    try {
      final j = jsonDecode(await f.readAsString());
      if (j is Map) return Map<String, dynamic>.from(j);
    } catch (_) {
      // падаем в ветку с бэкапом ниже
    }
    try {
      await f.copy('${f.path}.bak');
    } catch (_) {}
    return <String, dynamic>{};
  }

  Future<String?> readString(String key) => _serialize(() async {
    final v = (await _load())[key];
    return v is String ? v : null;
  });

  Future<bool?> readBool(String key) => _serialize(() async {
    final v = (await _load())[key];
    return v is bool ? v : null;
  });

  Future<void> writeString(String key, String value) => _write(key, value);

  Future<void> writeBool(String key, bool value) => _write(key, value);

  Future<void> _write(String key, Object value) => _serialize(() async {
    final m = await _load();
    m[key] = value;
    await writeFileAtomic(await _file(), jsonEncode(m));
  });

  Future<void> remove(String key) => _serialize(() async {
    final m = await _load();
    if (m.remove(key) == null) return;
    await writeFileAtomic(await _file(), jsonEncode(m));
  });
}
