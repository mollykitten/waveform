import 'dart:collection';

import 'models.dart';

/// Interleave candidates by source instead of mixing their scores: each
/// source ranks on its own scale, and a fixed weighted blend of those scales
/// hurt the stronger source in the pilots. The cycle gives related 50%, co-
/// likers 25% and stream 25% of every prefix. A source with nothing left
/// hands its slot to the next source in the ring, so quotas are never wasted.
///
/// A track is taken once, and no artist gets more than [maxPerArtist] tracks
/// in the result.
List<Recommendation> blendBySource(
  Map<WaveSource, List<Recommendation>> lists, {
  required int limit,
  int maxPerArtist = 2,
}) {
  const ring = [WaveSource.related, WaveSource.coLikers, WaveSource.stream];
  const cycle = [
    WaveSource.related,
    WaveSource.coLikers,
    WaveSource.stream,
    WaveSource.related,
  ];
  final queues = {
    for (final source in ring)
      source: Queue<Recommendation>.of(lists[source] ?? const []),
  };
  final taken = <String>{};
  final artists = <String, int>{};
  final result = <Recommendation>[];

  Recommendation? pop(WaveSource source) {
    final queue = queues[source]!;
    while (queue.isNotEmpty) {
      final item = queue.removeFirst();
      final artist = item.track.artistHandle.toLowerCase();
      if (taken.contains(item.track.id) ||
          (artists[artist] ?? 0) >= maxPerArtist) {
        continue;
      }
      taken.add(item.track.id);
      artists[artist] = (artists[artist] ?? 0) + 1;
      return item;
    }
    return null;
  }

  while (result.length < limit) {
    var progressed = false;
    for (final slot in cycle) {
      if (result.length >= limit) break;
      final start = ring.indexOf(slot);
      for (var step = 0; step < ring.length; step++) {
        final item = pop(ring[(start + step) % ring.length]);
        if (item != null) {
          result.add(item);
          progressed = true;
          break;
        }
      }
    }
    if (!progressed) break;
  }
  return result;
}
