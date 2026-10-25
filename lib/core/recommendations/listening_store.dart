import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'listening_event.dart';

/// Bounded local facts, serialized through one queue and replaced atomically.
/// A failed write preserves the previous complete file. Errors are sanitized.
class ListeningStore {
  ListeningStore({
    Future<Directory> Function()? directory,
    this.maxRecords = 2000,
    this.maxBytes = 2 * 1024 * 1024,
    this.onFailure,
  }) : _directory = directory ?? getApplicationSupportDirectory,
       assert(maxRecords > 0),
       assert(maxBytes > 0);

  static const fileName = 'listening-v1.json';
  final Future<Directory> Function() _directory;
  final int maxRecords;
  final int maxBytes;
  final void Function(String message)? onFailure;
  Future<void> _pending = Future.value();

  Future<File> _file() async {
    final directory = await _directory();
    await directory.create(recursive: true);
    return File('${directory.path}/$fileName');
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Read only the requested account. Unknown attribution returns no facts.
  Future<List<ListeningEvent>> read(String identity) => _serialize(() async {
    if (!validListeningIdentity(identity)) return <ListeningEvent>[];
    try {
      return (await _read(
        await _file(),
      )).where((event) => event.identity == identity).toList(growable: false);
    } catch (_) {
      _failed();
      return <ListeningEvent>[];
    }
  });

  Future<List<ListeningEvent>> _read(File file) async {
    if (!await file.exists()) return [];
    if (await file.length() > maxBytes) {
      _failed();
      return [];
    }
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (json['version'] != 1) {
        _failed();
        return [];
      }
      final rows = json['events'] as List<dynamic>;
      final result = <ListeningEvent>[];
      for (final row in rows.skip(
        rows.length > maxRecords ? rows.length - maxRecords : 0,
      )) {
        try {
          result.add(ListeningEvent.fromJson(row as Map<String, dynamic>));
        } catch (_) {
          _failed();
        }
      }
      return result;
    } catch (_) {
      _failed();
      return [];
    }
  }

  Future<void> append(ListeningEvent event) => _serialize(() async {
    if (!event.isValid) return;
    File? temporary;
    try {
      final file = await _file();
      final events = await _read(file);
      events.removeWhere((old) => old.sessionId == event.sessionId);
      events.add(event);
      if (events.length > maxRecords) {
        events.removeRange(0, events.length - maxRecords);
      }
      var encoded = _encode(events);
      while (utf8.encode(encoded).length > maxBytes && events.isNotEmpty) {
        events.removeAt(0);
        encoded = _encode(events);
      }
      if (utf8.encode(encoded).length > maxBytes) return;
      temporary = File('${file.path}.tmp');
      await temporary.writeAsString(encoded, flush: true);
      await temporary.rename(file.path);
    } catch (_) {
      _failed();
    } finally {
      if (temporary != null) {
        try {
          if (await temporary.exists()) await temporary.delete();
        } catch (_) {
          _failed();
        }
      }
    }
  });

  String _encode(List<ListeningEvent> events) => jsonEncode({
    'version': 1,
    'events': events.map((event) => event.toJson()).toList(),
  });

  void _failed() => onFailure?.call('listening storage unavailable');

  /// Await already enqueued writes on safe lifecycle shutdown paths.
  Future<void> flush() => _pending;
}
