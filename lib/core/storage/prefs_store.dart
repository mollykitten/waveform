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

  /// Битый JSON (`FormatException`) не затираем: сохраняем копию `.bak`, если
  /// там ещё нет валидной, и стартуем с пустого набора. Ошибки файловой
  /// системы (например, блокировка на Windows) пробрасываем: продолжать запись
  /// после них значит затереть prefs одним ключом.
  Future<Map<String, dynamic>> _load() async {
    final f = await _file();
    if (!await f.exists()) return <String, dynamic>{};
    final raw = await f.readAsString();
    try {
      final j = jsonDecode(raw);
      if (j is Map) return Map<String, dynamic>.from(j);
    } on FormatException {
      // битый JSON — в ветку с бэкапом ниже
    }
    await _backupCorrupt(f);
    return <String, dynamic>{};
  }

  Future<void> _backupCorrupt(File f) async {
    final bak = File('${f.path}.bak');
    if (await bak.exists()) {
      try {
        if (jsonDecode(await bak.readAsString()) is Map) return;
      } on FormatException {
        // старый .bak тоже битый — перезапишем
      }
    }
    await f.copy(bak.path);
  }

  Future<String?> readString(String key) => _serialize(() async {
    try {
      final v = (await _load())[key];
      return v is String ? v : null;
    } on FileSystemException {
      return null;
    }
  });

  Future<bool?> readBool(String key) => _serialize(() async {
    try {
      final v = (await _load())[key];
      return v is bool ? v : null;
    } on FileSystemException {
      return null;
    }
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
