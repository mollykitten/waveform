import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'listening_event.dart';
import 'vector_store.dart' show validVectorId;

/// One co-liker candidate: a track id with its neighbour-weight score and the
/// unix seconds of the newest neighbour like (the tie-breaker).
class CoLikerCandidate {
  const CoLikerCandidate(this.trackId, this.score, this.likedAt);
  final String trackId;
  final double score;
  final int likedAt;
}

/// A finished co-liker run for one account.
class CoLikersSnapshot {
  const CoLikersSnapshot(this.builtAt, this.candidates);
  final DateTime builtAt;
  final List<CoLikerCandidate> candidates;
}

/// Per-account, bounded, atomic cache of co-liker candidates. It holds our
/// own track ids and scores only: other users' ids (likers, neighbours) are
/// never written to disk.
class CoLikersStore {
  CoLikersStore({
    Future<Directory> Function()? directory,
    this.maxCandidates = 300,
    this.onFailure,
  }) : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;
  final int maxCandidates;
  final void Function(String)? onFailure;
  Future<void> _pending = Future.value();

  /// How long a finished run is reused before the next background refresh.
  static const ttl = Duration(hours: 24);

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _pending.then((_) => action());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<File?> _file(String identity) async {
    if (!validListeningIdentity(identity) || identity == 'anonymous') {
      return null;
    }
    final directory = await _directory();
    await directory.create(recursive: true);
    return File('${directory.path}/co-likers-v1-$identity.json');
  }

  /// The stored run, or null when missing, unreadable or invalid.
  Future<CoLikersSnapshot?> read(String identity) => _serial(() async {
    try {
      final file = await _file(identity);
      if (file == null || !await file.exists()) return null;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map ||
          json['version'] != 1 ||
          json['identity'] != identity) {
        return null;
      }
      final rows = json['candidates'] as List;
      if (rows.length > maxCandidates) return null;
      return CoLikersSnapshot(DateTime.parse(json['built_at'] as String), [
        for (final row in rows) _decode(row as Map),
      ]);
    } catch (_) {
      onFailure?.call('co-likers cache unreadable');
      return null;
    }
  });

  CoLikerCandidate _decode(Map row) {
    final id = row['id'] as String;
    final score = (row['score'] as num).toDouble();
    if (!validVectorId(id) || !score.isFinite || score <= 0) {
      throw const FormatException('invalid co-liker candidate');
    }
    return CoLikerCandidate(id, score, row['t'] as int);
  }

  /// Replace the account's cache. Candidates beyond [maxCandidates] are
  /// dropped lowest score first.
  Future<void> write(
    String identity,
    DateTime builtAt,
    List<CoLikerCandidate> candidates,
  ) => _serial(() async {
    File? temporary;
    try {
      final file = await _file(identity);
      if (file == null) return;
      final rows = [
        for (final c in candidates.take(maxCandidates))
          if (validVectorId(c.trackId))
            {'id': c.trackId, 'score': c.score, 't': c.likedAt},
      ];
      temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({
          'version': 1,
          'identity': identity,
          'built_at': builtAt.toUtc().toIso8601String(),
          'candidates': rows,
        }),
        flush: true,
      );
      await temporary.rename(file.path);
    } catch (_) {
      onFailure?.call('co-likers cache unavailable');
    } finally {
      try {
        if (temporary != null && await temporary.exists()) {
          await temporary.delete();
        }
      } catch (_) {
        onFailure?.call('co-likers cache unavailable');
      }
    }
  });

  /// Delete one account's cache (e.g. on logout).
  Future<void> forget(String identity) => _serial(() async {
    try {
      final file = await _file(identity);
      if (file == null) return;
      for (final path in [file.path, '${file.path}.tmp']) {
        final target = File(path);
        if (await target.exists()) await target.delete();
      }
    } catch (_) {
      onFailure?.call('co-likers cache unavailable');
    }
  });
}
