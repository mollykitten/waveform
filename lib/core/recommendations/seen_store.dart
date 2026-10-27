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
  skipped(Duration(days: 30)),

  /// Explicit thumbs-down from the wave; a long, effectively sticky memory.
  disliked(Duration(days: 365));

  const SeenKind(this.cooldown);
  final Duration cooldown;
}

/// One remembered track. [artist] is a bounded lowercase handle kept only for
/// dislikes, to soften later offers from the same artist.
typedef SeenEntry = ({SeenKind kind, DateTime at, String? artist});

/// Per-account (one file each), bounded, atomic memory of tracks the wave
/// must not repeat.
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

  /// Dislikes are kept ahead of every other entry, up to this many.
  static const maxDisliked = 500;
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

  bool _active(SeenEntry value, DateTime now) =>
      now.difference(value.at) < value.kind.cooldown;

  /// Latest remembered state per track. Unknown accounts return nothing.
  Future<Map<String, SeenEntry>> read(String identity) =>
      _serial(() async => (await _read(identity)).entries);

  /// Rows that fail to parse are skipped one by one. A transient IO error
  /// yields `writable: false` so nothing is overwritten. A structurally
  /// broken file is moved to `.bak` and the memory starts afresh.
  Future<({Map<String, SeenEntry> entries, bool writable})> _read(
    String identity,
  ) async {
    final entries = <String, SeenEntry>{};
    if (!validListeningIdentity(identity)) {
      return (entries: entries, writable: false);
    }
    final File file;
    final String text;
    try {
      file = await _file(identity);
      if (!await file.exists()) return (entries: entries, writable: true);
      if (await file.length() > maxBytes) return await _broken(file);
      text = await file.readAsString();
    } on FileSystemException {
      onFailure?.call('seen tracks storage unavailable');
      return (entries: entries, writable: false);
    }
    try {
      final root = jsonDecode(text) as Map;
      if (root['version'] != 1 || root['identity'] != identity) {
        return await _broken(file);
      }
      for (final row in root['entries'] as List) {
        try {
          final id = row['id'] as String;
          if (!validVectorId(id)) continue;
          entries[id] = (
            kind: SeenKind.values.byName(row['kind'] as String),
            at: DateTime.parse(row['at'] as String),
            artist: row['artist'] as String?,
          );
        } catch (_) {
          onFailure?.call('seen tracks storage had an unreadable row');
        }
      }
      return (entries: entries, writable: true);
    } catch (_) {
      return await _broken(file);
    }
  }

  Future<({Map<String, SeenEntry> entries, bool writable})> _broken(
    File file,
  ) async {
    onFailure?.call('seen tracks storage was corrupt, kept as .bak');
    try {
      await file.rename('${file.path}.bak');
      return (entries: <String, SeenEntry>{}, writable: true);
    } on FileSystemException {
      return (entries: <String, SeenEntry>{}, writable: false);
    }
  }

  /// Merge [ids] as [kind] at [at]. A longer cooldown is never shortened by a
  /// shorter one; expired and overflowing entries are dropped.
  Future<void> record(
    String identity,
    SeenKind kind,
    Iterable<String> ids,
    DateTime at,
  ) => recordAll(identity, {
    for (final id in ids) id: (kind: kind, at: at, artist: null),
  });

  /// Remember a thumbs-down for [trackId] (and its artist) on this account.
  Future<void> dislike(
    String identity,
    String trackId,
    String artist,
    DateTime at,
  ) {
    final handle = artist.trim().toLowerCase();
    return recordAll(identity, {
      trackId: (
        kind: SeenKind.disliked,
        at: at,
        artist: handle.length > 64 ? handle.substring(0, 64) : handle,
      ),
    });
  }

  /// Undo a dislike. Other kinds of memory for the track stay as they are.
  Future<void> undislike(String identity, String trackId) => _serial(() async {
    final loaded = await _read(identity);
    final entry = loaded.entries[trackId];
    if (!loaded.writable || entry?.kind != SeenKind.disliked) return;
    loaded.entries.remove(trackId);
    await _write(identity, loaded.entries);
  });

  /// Newest dislikes first, at most [limit].
  Future<List<({String id, DateTime at, String? artist})>> dislikes(
    String identity,
    int limit,
  ) async {
    final entries = await read(identity);
    final rows = [
      for (final e in entries.entries)
        if (e.value.kind == SeenKind.disliked)
          (id: e.key, at: e.value.at, artist: e.value.artist),
    ]..sort((a, b) => b.at.compareTo(a.at));
    return rows.take(limit).toList();
  }

  /// Merge many facts in one atomic write.
  Future<void> recordAll(String identity, Map<String, SeenEntry> facts) =>
      _serial(() async {
        if (!validListeningIdentity(identity) || facts.isEmpty) return;
        final loaded = await _read(identity);
        if (!loaded.writable) return;
        final entries = loaded.entries;
        for (final fact in facts.entries) {
          if (!validVectorId(fact.key)) continue;
          final old = entries[fact.key];
          final oldEnd = old?.at.add(old.kind.cooldown);
          final end = fact.value.at.add(fact.value.kind.cooldown);
          if (oldEnd == null || end.isAfter(oldEnd)) {
            entries[fact.key] = fact.value;
          }
        }
        await _write(identity, entries);
      });

  /// Dislikes first (newest, capped), then everything else by recency; size
  /// pressure trims from the tail, so ordinary entries go before dislikes.
  Future<void> _write(String identity, Map<String, SeenEntry> entries) async {
    File? temporary;
    try {
      int newest(String a, String b) =>
          entries[b]!.at.compareTo(entries[a]!.at);
      final disliked =
          entries.keys
              .where((id) => entries[id]!.kind == SeenKind.disliked)
              .toList()
            ..sort(newest);
      final others =
          entries.keys
              .where((id) => entries[id]!.kind != SeenKind.disliked)
              .toList()
            ..sort(newest);
      var keep = [
        ...disliked.take(maxDisliked),
        ...others,
      ].take(maxRecords).toList();
      String encode() => jsonEncode({
        'version': 1,
        'identity': identity,
        'entries': [
          for (final id in keep)
            {
              'id': id,
              'kind': entries[id]!.kind.name,
              'at': entries[id]!.at.toUtc().toIso8601String(),
              'artist': ?entries[id]!.artist,
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
  }

  /// Delete one account's memory, e.g. on its logout or consent revocation.
  /// Other accounts keep theirs, so switching A to B and back loses nothing.
  Future<void> forget(String identity) => _serial(() async {
    if (!validListeningIdentity(identity)) return;
    try {
      final file = await _file(identity);
      if (await file.exists()) await file.delete();
    } catch (_) {
      onFailure?.call('seen tracks storage unavailable');
    }
  });
}
