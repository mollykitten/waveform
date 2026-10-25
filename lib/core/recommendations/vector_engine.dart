import 'dart:math' as math;

import '../../shared/models/track.dart';
import '../api/soundcloud_api.dart';
import 'listening_event.dart';
import 'listening_store.dart';
import 'models.dart';
import 'vector_store.dart';

/// Coordinates identify actual source seeds, never hashed musical features.
class StructuralVector {
  StructuralVector(Map<String, double> edges) : weights = _normalize(edges);
  final Map<String, double> weights;

  static Map<String, double> _normalize(Map<String, double> edges) {
    final norm = math.sqrt(edges.values.fold<double>(0, (s, v) => s + v * v));
    return Map.unmodifiable({
      if (norm > 0)
        for (final e in edges.entries) e.key: e.value / norm,
    });
  }

  double cosine(StructuralVector other) => weights.entries.fold<double>(
    0,
    (sum, e) => sum + e.value * (other.weights[e.key] ?? 0),
  );
}

/// One identifiable seed interest with bounded, time-decayed local support.
class VectorInterest {
  const VectorInterest(this.seedId, this.support, this.observations);
  final String seedId;
  final double support;
  final double observations;
}

/// Local graph retrieval and multi-interest learning. It does not inspect audio
/// or send listening facts to a model. All returned tracks are live API objects.
class VectorEngine {
  VectorEngine({
    required this.api,
    required this.store,
    required this.listening,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final SoundcloudApi api;
  final VectorStore store;
  final ListeningStore listening;
  final DateTime Function() _now;

  static bool eligible(Track track) =>
      validVectorId(track.id) &&
      track.title.trim().isNotEmpty &&
      track.artist.trim().isNotEmpty &&
      !track.blocked &&
      track.streamCandidates.isNotEmpty;

  /// Replay at most the bounded fact store, deduplicating sessions. Distinct
  /// interests keep separate support instead of collapsing into one centroid.
  List<VectorInterest> interests(
    List<String> seeds,
    Map<String, VectorProvenance> provenance,
    List<ListeningEvent> events,
    String identity, {
    Map<String, VectorProvenance>? attributions,
  }) {
    final support = {for (final seed in seeds) seed: 1.0};
    final observations = {for (final seed in seeds) seed: 0.0};
    final seen = <String>{};
    for (final event in events.reversed) {
      if (event.identity != identity ||
          !seen.add(event.sessionId) ||
          !event.isValid ||
          event.evidence == ListeningEvidence.neutral) {
        continue;
      }
      final age = _now().difference(event.endedAt).inSeconds;
      if (age < 0) continue;
      final decay = math.pow(.5, age / const Duration(days: 30).inSeconds);
      final attributed =
          (attributions == null
              ? provenance[event.trackId]?.weights
              : attributions[event.sessionId]?.weights) ??
          <String, double>{};
      // Listening to this exact track is direct evidence for its own seed
      // interest even when the earlier related-graph context was unknown.
      final vector = {
        ...attributed,
        if (support.containsKey(event.trackId)) event.trackId: 1.0,
      };
      for (final edge in vector.entries) {
        if (!support.containsKey(edge.key)) continue;
        final amount = edge.value * decay;
        observations[edge.key] = observations[edge.key]! + amount;
        final sign = event.evidence == ListeningEvidence.positive ? 1.0 : -1.5;
        support[edge.key] = support[edge.key]! + sign * amount;
      }
    }
    return [
      for (final seed in seeds)
        VectorInterest(
          seed,
          support[seed]!.clamp(.1, 4.0),
          observations[seed]!,
        ),
    ];
  }

  Future<List<Recommendation>> generate({
    required List<Track> seeds,
    required String identity,
    required Set<String> excludedTrackIds,
    required void Function() check,
  }) async {
    check();
    if (!validListeningIdentity(identity)) return [];
    final snapshot = await store.readSnapshot(identity);
    final provenance = snapshot.vectors;
    final attributions = snapshot.attributions;
    final revisions = snapshot.revisions;
    check();
    final events = await listening.read(identity);
    check();
    final now = _now();
    provenance.removeWhere(
      (_, value) => now.difference(value.observedAt) > const Duration(days: 90),
    );
    revisions.removeWhere(
      (revision) =>
          now.difference(revision.value.observedAt) > const Duration(days: 90),
    );
    final uniqueSeeds = <String, Track>{};
    // Prefer different known artists, then fill any spare seed slots.
    final artists = <String>{};
    for (final seed in seeds) {
      if (eligible(seed) && artists.add(seed.artistHandle.toLowerCase())) {
        uniqueSeeds.putIfAbsent(seed.id, () => seed);
      }
      if (uniqueSeeds.length == 6) break;
    }
    for (final seed in seeds) {
      if (uniqueSeeds.length == 6) break;
      if (eligible(seed)) uniqueSeeds.putIfAbsent(seed.id, () => seed);
    }
    if (uniqueSeeds.isEmpty) return [];
    final sessions = events.map((e) => e.sessionId).toSet();
    attributions.removeWhere((session, _) => !sessions.contains(session));
    for (final event in events) {
      if (event.identity != identity || !event.isValid) continue;
      attributions.putIfAbsent(event.sessionId, () {
        final applicable =
            [
                  ?provenance[event.trackId],
                  for (final revision in revisions)
                    if (revision.trackId == event.trackId) revision.value,
                ]
                .where((value) => !value.observedAt.isAfter(event.startedAt))
                .toList()
              ..sort((a, b) => b.observedAt.compareTo(a.observedAt));
        // Unknown historical context stays unknown forever. A later related
        // response cannot invent an attribution for an earlier play session.
        final weights = uniqueSeeds.containsKey(event.trackId)
            ? {event.trackId: 1.0}
            : applicable.isNotEmpty
            ? applicable.first.weights
            : <String, double>{};
        return VectorProvenance(Map.of(weights), event.endedAt);
      });
    }
    final candidates = <String, Track>{};
    final edges = <String, Map<String, double>>{};
    for (final seed in uniqueSeeds.values) {
      check();
      List<Track> related;
      try {
        related = await api
            .relatedTracks(seed.id)
            .timeout(const Duration(seconds: 15));
      } catch (_) {
        check();
        continue;
      }
      check();
      // Never follow next_href or expand returned tracks recursively.
      for (var rank = 0; rank < math.min(12, related.length); rank++) {
        final track = related[rank];
        if (!eligible(track) ||
            excludedTrackIds.contains(track.id) ||
            uniqueSeeds.containsKey(track.id)) {
          continue;
        }
        candidates.putIfAbsent(track.id, () => track);
        final coordinates = edges.putIfAbsent(track.id, () => {});
        coordinates.putIfAbsent(seed.id, () => 1 / math.sqrt(rank + 1));
      }
    }
    if (candidates.isEmpty) return [];
    final vectors = {
      for (final edge in edges.entries) edge.key: StructuralVector(edge.value),
    };
    // Capture the attribution under which feedback was originally collected.
    // Newly observed edges must not retroactively reinterpret old sessions.
    final profiles = interests(
      uniqueSeeds.keys.toList(),
      provenance,
      events,
      identity,
      attributions: attributions,
    );
    // These edges became known only after retrieval finished. Request start
    // must never masquerade as observation time for an intervening session.
    final observedAt = _now();
    for (final entry in vectors.entries) {
      final previous = provenance[entry.key];
      if (previous != null) revisions.add(VectorRevision(entry.key, previous));
      provenance[entry.key] = VectorProvenance(entry.value.weights, observedAt);
    }
    final selected = rank(candidates.values.toList(), vectors, profiles);
    check();
    await store.write(
      identity,
      provenance,
      attributions: attributions,
      revisions: revisions,
      check: check,
    );
    check();
    return [
      for (final track in selected)
        Recommendation(
          track,
          'from related tracks, ranked using local listening interests',
        ),
    ];
  }

  /// Cosine to separate one-seed interest vectors, weighted by bounded support.
  /// Every fifth place explores an underrepresented, less-observed interest.
  List<Track> rank(
    List<Track> candidates,
    Map<String, StructuralVector> vectors,
    List<VectorInterest> profiles,
  ) {
    final units = {
      for (final p in profiles) p.seedId: StructuralVector({p.seedId: 1}),
    };
    final coverage = {for (final p in profiles) p.seedId: 0.0};
    final artists = <String, int>{};
    final remaining = {for (final t in candidates) t.id: t};
    final result = <Track>[];
    while (remaining.isNotEmpty && result.length < 10) {
      final explore = result.length % 5 == 4;
      double score(Track track) {
        final vector = vectors[track.id];
        if (vector == null) return -1;
        var value = 0.0;
        for (final profile in profiles) {
          final similarity = vector.cosine(units[profile.seedId]!);
          final weight = explore
              ? 1 / (1 + profile.observations)
              : profile.support;
          value += similarity * weight / (1 + coverage[profile.seedId]!);
        }
        return value;
      }

      final available = remaining.values
          .where(
            (track) => (artists[track.artistHandle.toLowerCase()] ?? 0) < 2,
          )
          .toList();
      if (available.isEmpty) break;
      available.sort((a, b) {
        final comparison = score(b).compareTo(score(a));
        return comparison == 0 ? a.id.compareTo(b.id) : comparison;
      });
      final chosen = available.first;
      result.add(chosen);
      remaining.remove(chosen.id);
      final artist = chosen.artistHandle.toLowerCase();
      artists[artist] = (artists[artist] ?? 0) + 1;
      for (final p in profiles) {
        coverage[p.seedId] =
            coverage[p.seedId]! + vectors[chosen.id]!.cosine(units[p.seedId]!);
      }
    }
    return result;
  }
}
