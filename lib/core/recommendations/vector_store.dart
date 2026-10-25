import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'listening_event.dart';

bool validVectorId(String id) => RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(id);

/// Real related-edge provenance only; no metadata, credentials or audio URLs.
class VectorProvenance {
  const VectorProvenance(this.weights, this.observedAt);
  final Map<String, double> weights;
  final DateTime observedAt;
}

typedef VectorSnapshot = ({
  Map<String, VectorProvenance> vectors,
  Map<String, VectorProvenance> attributions,
  List<VectorRevision> revisions,
});

class VectorRevision {
  const VectorRevision(this.trackId, this.value);
  final String trackId;
  final VectorProvenance value;
}

/// Per-account, bounded, atomic provenance and immutable session attribution.
/// Facts remain in ListeningStore; replay never cumulatively reapplies a play.
class VectorStore {
  VectorStore({
    Future<Directory> Function()? directory,
    this.maxRecords = 600,
    this.maxAttributions = 2000,
    this.maxRevisions = 1200,
    this.maxBytes = 512 * 1024,
    this.onFailure,
  }) : _directory = directory ?? getApplicationSupportDirectory,
       assert(maxRecords > 0),
       assert(maxAttributions > 0),
       assert(maxRevisions > 0),
       assert(maxBytes > 0);

  final Future<Directory> Function() _directory;
  final int maxRecords;
  final int maxAttributions;
  final int maxRevisions;
  final int maxBytes;
  final void Function(String)? onFailure;
  Future<void> _pending = Future.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _pending.then((_) => action());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<File> _file(String identity) async {
    final directory = await _directory();
    await directory.create(recursive: true);
    return File('${directory.path}/related-vectors-v1-$identity.json');
  }

  Future<Map<String, VectorProvenance>> read(String identity) async =>
      (await readSnapshot(identity)).vectors;

  Map<String, VectorProvenance> _decode(
    List rows,
    int limit, {
    bool attribution = false,
  }) {
    if (rows.length > limit) throw const FormatException();
    final result = <String, VectorProvenance>{};
    for (final row in rows) {
      final id = row['id'] as String;
      final raw = row['weights'] as Map;
      if (!(attribution
              ? RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(id)
              : validVectorId(id)) ||
          (!attribution && raw.isEmpty) ||
          raw.length > 6) {
        throw const FormatException();
      }
      final weights = <String, double>{};
      for (final entry in raw.entries) {
        final key = entry.key as String;
        final value = (entry.value as num).toDouble();
        if (!validVectorId(key) || !value.isFinite || value <= 0 || value > 1) {
          throw const FormatException();
        }
        weights[key] = value;
      }
      result[id] = VectorProvenance(
        weights,
        DateTime.parse(row['observed_at'] as String),
      );
    }
    return result;
  }

  Future<VectorSnapshot> readSnapshot(String identity) => _serial(() async {
    VectorSnapshot empty() => (vectors: {}, attributions: {}, revisions: []);
    if (!validListeningIdentity(identity)) return empty();
    try {
      final file = await _file(identity);
      if (!await file.exists()) return empty();
      if (await file.length() > maxBytes) throw const FormatException();
      final root = jsonDecode(await file.readAsString()) as Map;
      if (root['version'] != 1 || root['identity'] != identity) {
        throw const FormatException();
      }
      final history = root['revisions'] as List? ?? [];
      if (history.length > maxRevisions) throw const FormatException();
      final revisions = <VectorRevision>[];
      for (final row in history) {
        final value = _decode([row], 1).entries.single;
        revisions.add(VectorRevision(value.key, value.value));
      }
      return (
        vectors: _decode(root['vectors'] as List, maxRecords),
        attributions: _decode(
          root['attributions'] as List? ?? [],
          maxAttributions,
          attribution: true,
        ),
        revisions: revisions,
      );
    } catch (_) {
      onFailure?.call('local vector cache unavailable');
      return empty();
    }
  });

  List<Map<String, Object>> _rows(
    Map<String, VectorProvenance> values,
    int limit, {
    bool attribution = false,
  }) {
    final sorted =
        values.entries
            .where(
              (entry) =>
                  (attribution
                      ? RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(entry.key)
                      : validVectorId(entry.key)) &&
                  (attribution || entry.value.weights.isNotEmpty) &&
                  entry.value.weights.length <= 6 &&
                  entry.value.weights.entries.every(
                    (e) =>
                        validVectorId(e.key) &&
                        e.value.isFinite &&
                        e.value > 0 &&
                        e.value <= 1,
                  ),
            )
            .toList()
          ..sort((a, b) => b.value.observedAt.compareTo(a.value.observedAt));
    return sorted
        .take(limit)
        .map(
          (entry) => <String, Object>{
            'id': entry.key,
            'weights': entry.value.weights,
            'observed_at': entry.value.observedAt.toUtc().toIso8601String(),
          },
        )
        .toList();
  }

  /// [check] is rechecked after async steps and immediately before replacement.
  Future<void> write(
    String identity,
    Map<String, VectorProvenance> vectors, {
    Map<String, VectorProvenance> attributions = const {},
    List<VectorRevision> revisions = const [],
    required void Function() check,
  }) => _serial(() async {
    check();
    if (!validListeningIdentity(identity)) return;
    File? temporary;
    try {
      final file = await _file(identity);
      check();
      final rows = _rows(vectors, maxRecords);
      final assignments = _rows(
        attributions,
        maxAttributions,
        attribution: true,
      );
      final sortedRevisions = List<VectorRevision>.of(revisions)
        ..sort((a, b) => b.value.observedAt.compareTo(a.value.observedAt));
      final history = [
        for (final revision in sortedRevisions.take(maxRevisions))
          ..._rows({revision.trackId: revision.value}, 1),
      ];
      String encode() => jsonEncode({
        'version': 1,
        'identity': identity,
        'vectors': rows,
        'attributions': assignments,
        'revisions': history,
      });
      var encoded = encode();
      while (utf8.encode(encoded).length > maxBytes &&
          (rows.isNotEmpty || assignments.isNotEmpty || history.isNotEmpty)) {
        // Prefer session assignments to expendable candidate retrieval data.
        if (rows.isNotEmpty) {
          rows.removeLast();
        } else if (history.isNotEmpty) {
          history.removeLast();
        } else {
          assignments.removeLast();
        }
        encoded = encode();
      }
      if (utf8.encode(encoded).length > maxBytes) return;
      temporary = File('${file.path}.tmp');
      await temporary.writeAsString(encoded, flush: true);
      check();
      await temporary.rename(file.path);
    } catch (_) {
      check();
      onFailure?.call('local vector cache unavailable');
    } finally {
      if (temporary != null) {
        try {
          if (await temporary.exists()) await temporary.delete();
        } catch (_) {
          onFailure?.call('local vector cache unavailable');
        }
      }
    }
  });
}
