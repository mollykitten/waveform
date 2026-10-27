import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'listening_event.dart';
import 'vector_store.dart';

/// Why a track is remembered; each kind has its own cooldown.
enum SeenKind {
  /// Offered by the wave (even if never played).
  shown(Duration(days: 7)),

  /// Listened to for at least 30 s or 70%.
  played(Duration(days: 45)),

  /// Manually skipped early.
  skipped(Duration(days: 30));

  const SeenKind(this.cooldown);
  final Duration cooldown;
}

/// Per-account, bounded, atomic memory of tracks the wave must not repeat.
/// Holds ids and timestamps only. It outlives the wave session and the
/// bounded [ListeningStore], so a restart never re-offers a heard track.
class SeenStore {
  SeenStore({
    Future<Directory> Function()? directory,
    this.maxRecords = 3000,
    this.maxBytes = 512 * 1024,
    this.onFailure,
  }) : _directory = directory ?? getApplicationSupportDirectory,
       assert(maxRecords > 0),
       assert(maxBytes > 0);

  final Future<Directory> Function() _directory;
  final int maxRecords;
  final int maxBytes;
  final void Function(String message)? onFailure;
  Future<void> _pending = Future.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _pending.then((_) => action());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<File> _file(String identity) async {
    final directory = await _directory();
    await directory.create(recursive: true);
    return File('${directory.path}/seen-tracks-v1-$identity.json');
  }

  /// Ids still inside their cooldown at [now].
  Future<Set<String>> excluded(String identity, DateTime now) async {
    final entries = await read(identity);
    return {
      for (final entry in entries.entries)
        if (_active(entry.value, now)) entry.key,
    };
  }

  bool _active(({SeenKind kind, DateTime at}) value, DateTime now) =>
      now.difference(value.at) < value.kind.cooldown;

  /// Latest remembered state per track. Unknown accounts return nothing.
  Future<Map<String, ({SeenKind kind, DateTime at})>> read(String identity) =>
      _serial(() => _read(identity));

  Future<Map<String, ({SeenKind kind, DateTime at})>> _read(
    String identity,
  ) async {
    if (!validListeningIdentity(identity)) return {};
    try {
      final file = await _file(identity);
      if (!await file.exists()) return {};
      if (await file.length() > maxBytes) throw const FormatException();
      final root = jsonDecode(await file.readAsString()) as Map;
      if (root['version'] != 1 || root['identity'] != identity) {
        throw const FormatException();
      }
      final result = <String, ({SeenKind kind, DateTime at})>{};
      for (final row in root['entries'] as List) {
        final id = row['id'] as String;
        if (!validVectorId(id)) continue;
        result[id] = (
          kind: SeenKind.values.byName(row['kind'] as String),
          at: DateTime.parse(row['at'] as String),
        );
      }
      return result;
    } catch (_) {
      onFailure?.call('seen tracks storage unavailable');
      return {};
    }
  }

  /// Merge [ids] as [kind] at [at]. A longer cooldown is never shortened by a
  /// shorter one; expired and overflowing entries are dropped.
  Future<void> record(
    String identity,
    SeenKind kind,
    Iterable<String> ids,
    DateTime at,
  ) => recordAll(identity, {for (final id in ids) id: (kind: kind, at: at)});

  /// Merge many facts in one atomic write.
  Future<void> recordAll(
    String identity,
    Map<String, ({SeenKind kind, DateTime at})> facts,
  ) => _serial(() async {
    if (!validListeningIdentity(identity) || facts.isEmpty) return;
    File? temporary;
    try {
      final entries = await _read(identity);
      for (final fact in facts.entries) {
        if (!validVectorId(fact.key)) continue;
        final old = entries[fact.key];
        final oldEnd = old?.at.add(old.kind.cooldown);
        final end = fact.value.at.add(fact.value.kind.cooldown);
        if (oldEnd == null || end.isAfter(oldEnd)) {
          entries[fact.key] = fact.value;
        }
      }
      final latest = entries.keys.toList()
        ..sort((a, b) => entries[b]!.at.compareTo(entries[a]!.at));
      var keep = latest.take(maxRecords).toList();
      String encode() => jsonEncode({
        'version': 1,
        'identity': identity,
        'entries': [
          for (final id in keep)
            {
              'id': id,
              'kind': entries[id]!.kind.name,
              'at': entries[id]!.at.toUtc().toIso8601String(),
            },
        ],
      });
      var encoded = encode();
      while (utf8.encode(encoded).length > maxBytes && keep.isNotEmpty) {
        keep = keep.sublist(0, keep.length - keep.length ~/ 10 - 1);
        encoded = encode();
      }
      final file = await _file(identity);
      temporary = File('${file.path}.tmp');
      await temporary.writeAsString(encoded, flush: true);
      await temporary.rename(file.path);
    } catch (_) {
      onFailure?.call('seen tracks storage unavailable');
    } finally {
      if (temporary != null) {
        try {
          if (await temporary.exists()) await temporary.delete();
        } catch (_) {
          onFailure?.call('seen tracks storage unavailable');
        }
      }
    }
  });

  /// Drop every file of other accounts so a switch leaves no stale memory.
  Future<void> clearOthers(String identity) => _serial(() async {
    try {
      final directory = await _directory();
      if (!await directory.exists()) return;
      final keep = 'seen-tracks-v1-$identity.json';
      await for (final entity in directory.list()) {
        final name = entity.uri.pathSegments.last;
        if (entity is File &&
            name.startsWith('seen-tracks-v1-') &&
            name != keep) {
          await entity.delete();
        }
      }
    } catch (_) {
      onFailure?.call('seen tracks storage unavailable');
    }
  });
}
