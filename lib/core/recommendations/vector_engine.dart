import 'dart:math' as math;

import '../../shared/models/track.dart';
import '../api/soundcloud_api.dart';
import 'listening_event.dart';
import 'listening_store.dart';
import 'models.dart';
import 'seen_store.dart';
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
    this.seen,
    this.maxRequests = 12,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final SoundcloudApi api;
  final VectorStore store;
  final ListeningStore listening;

  /// Persistent cross-session memory of shown, heard and skipped tracks.
  final SeenStore? seen;

  /// Most recent dislikes that shape ranking.
  static const maxDislikes = 20;

  /// Soft ranking penalties for candidates near disliked tracks: cosine to the
  /// centroid of the disliked tracks' structural vectors, and a gentle factor
  /// for the same artist. Nothing is excluded here; exclusion is a separate
  /// rule of the seen memory. All of this stays on the device.
  void _penalizeDisliked(
    ({
      Map<String, Track> candidates,
      Map<String, Map<String, double>> edges,
      Map<String, double> discounts,
    })
    pool,
    Map<String, StructuralVector> vectors,
    Map<String, VectorProvenance> provenance,
    List<VectorDislike> dislikes,
    Map<String, Track> candidates,
  ) {
    if (dislikes.isEmpty) return;
    final sum = <String, double>{};
    for (final dislike in dislikes) {
      final weights = provenance[dislike.trackId]?.weights;
      if (weights == null) continue;
      final unit = StructuralVector(weights);
      for (final edge in unit.weights.entries) {
        sum[edge.key] = (sum[edge.key] ?? 0) + edge.value;
      }
    }
    final centroid = sum.isEmpty ? null : StructuralVector(sum);
    final artists = <String, int>{};
    for (final dislike in dislikes) {
      final artist = dislike.artist;
      if (artist != null && artist.isNotEmpty) {
        artists[artist] = (artists[artist] ?? 0) + 1;
      }
    }
    for (final track in candidates.values) {
      var factor = 1.0;
      final vector = vectors[track.id];
      if (centroid != null && vector != null) {
        factor *= 1 - .6 * vector.cosine(centroid);
      }
      final count = artists[track.artistHandle.toLowerCase()] ?? 0;
      if (count > 0) factor *= math.pow(.7, math.min(3, count));
      pool.discounts[track.id] = (pool.discounts[track.id] ?? 1) * factor;
    }
  }

  /// Hard cap on SoundCloud requests for one generation.
  final int maxRequests;
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
    List<VectorDislike> dislikes = const [],
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
    // A dislike weakens the interests its track came from, with the same
    // 30-day half-life, but never removes more than 60% of an interest.
    final penalty = {for (final seed in seeds) seed: 0.0};
    for (final dislike in dislikes) {
      final age = _now().difference(dislike.at).inSeconds;
      if (age < 0) continue;
      final decay = math.pow(.5, age / const Duration(days: 30).inSeconds);
      final weights = provenance[dislike.trackId]?.weights ?? const {};
      for (final edge in weights.entries) {
        if (penalty.containsKey(edge.key)) {
          penalty[edge.key] = penalty[edge.key]! + edge.value * decay * .4;
        }
      }
    }
    return [
      for (final seed in seeds)
        VectorInterest(
          seed,
          support[seed]!.clamp(.1, 4.0) * (1 - math.min(.6, penalty[seed]!)),
          observations[seed]!,
        ),
    ];
  }

  Future<List<Recommendation>> generate({
    required List<Track> seeds,
    required String identity,
    required Set<String> excludedTrackIds,
    required void Function() check,
    int limit = 10,
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
    final excluded = {
      ...excludedTrackIds,
      ..._heardCooldown(events, identity, now),
      if (seen != null) ...await _syncSeen(events, identity, now),
    };
    check();
    // Every dislike keeps its track out of the seeds; only the newest few
    // shape the ranking, because edge provenance lives 90 days.
    final allDislikes = [
      if (seen != null)
        for (final row in await seen!.dislikes(identity, 500))
          VectorDislike(row.id, row.at, row.artist),
    ];
    check();
    final blocked = {for (final dislike in allDislikes) dislike.trackId};
    final dislikes = allDislikes.take(maxDislikes).toList();
    final uses = _useByIdentity.putIfAbsent(identity, () => {});
    final picked = _pickSeeds(seeds, events, identity, uses, blocked);
    if (picked.isEmpty) return [];
    // Count use up front so even an empty pool rotates to other seeds.
    for (final seed in picked) {
      uses[seed.id] = (uses[seed.id] ?? 0) + 1;
    }
    if (uses.length > 200) uses.clear();
    final uniqueSeeds = {for (final seed in picked) seed.id: seed};
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
    final pool = await _gather(picked, excluded, check);
    final candidates = pool.candidates;
    final edges = pool.edges;
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
      dislikes: dislikes,
    );
    _penalizeDisliked(pool, vectors, provenance, dislikes, candidates);
    // These edges became known only after retrieval finished. Request start
    // must never masquerade as observation time for an intervening session.
    final observedAt = _now();
    for (final entry in vectors.entries) {
      final previous = provenance[entry.key];
      if (previous != null) revisions.add(VectorRevision(entry.key, previous));
      provenance[entry.key] = VectorProvenance(entry.value.weights, observedAt);
    }
    final selected = rank(
      candidates.values.toList(),
      vectors,
      profiles,
      limit: limit,
      discounts: pool.discounts,
    );
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

  /// Below this many filtered candidates the pool is widened by stages.
  static const minPool = 20;

  final _useByIdentity = <String, Map<String, int>>{};

  /// Tracks heard or skipped recently, straight from the local facts.
  Set<String> _heardCooldown(
    List<ListeningEvent> events,
    String identity,
    DateTime now,
  ) => {
    for (final event in events)
      if (event.identity == identity &&
          event.isValid &&
          _kindOf(event) != null &&
          now.difference(event.endedAt) < _kindOf(event)!.cooldown)
        event.trackId,
  };

  SeenKind? _kindOf(ListeningEvent event) => switch (event.evidence) {
    ListeningEvidence.positive => SeenKind.played,
    ListeningEvidence.negative => SeenKind.skipped,
    ListeningEvidence.neutral => null,
  };

  /// Ids that must not be offered again for [identity]: recent listens and
  /// skips plus the durable seen memory. Used by every recommendation mode.
  Future<Set<String>> memoryExclusions(String identity) async {
    if (!validListeningIdentity(identity)) return {};
    final events = await listening.read(identity);
    final now = _now();
    return {
      ..._heardCooldown(events, identity, now),
      if (seen != null) ...await _syncSeen(events, identity, now),
    };
  }

  /// Copy listening facts into the durable memory and return its cooldown set.
  Future<Set<String>> _syncSeen(
    List<ListeningEvent> events,
    String identity,
    DateTime now,
  ) async {
    final store = seen!;
    final facts = <String, SeenEntry>{};
    for (final event in events) {
      final kind = _kindOf(event);
      if (event.identity != identity || !event.isValid || kind == null) {
        continue;
      }
      facts[event.trackId] = (kind: kind, at: event.endedAt, artist: null);
    }
    await store.recordAll(identity, facts);
    return store.excluded(identity, now);
  }

  /// Choose up to six seeds: caller seeds, then recent positive listens, with
  /// least-used seeds first so consecutive refills explore different roots.
  List<_Seed> _pickSeeds(
    List<Track> callerSeeds,
    List<ListeningEvent> events,
    String identity,
    Map<String, int> uses,
    Set<String> blocked,
  ) {
    final all = <String, _Seed>{};
    for (final track in callerSeeds) {
      if (eligible(track) && !blocked.contains(track.id)) {
        all.putIfAbsent(
          track.id,
          () => _Seed(track.id, track.artistHandle.toLowerCase(), track.genre),
        );
      }
    }
    var listened = 0;
    for (final event in events.reversed) {
      if (listened == 10) break;
      if (event.identity == identity &&
          event.isValid &&
          event.evidence == ListeningEvidence.positive &&
          validVectorId(event.trackId) &&
          !blocked.contains(event.trackId) &&
          !all.containsKey(event.trackId)) {
        all[event.trackId] = _Seed(event.trackId, '', '');
        listened++;
      }
    }
    final ordered = all.values.toList();
    final ranks = {for (var i = 0; i < ordered.length; i++) ordered[i].id: i};
    ordered.sort((a, b) {
      final byUse = (uses[a.id] ?? 0).compareTo(uses[b.id] ?? 0);
      return byUse != 0 ? byUse : ranks[a.id]!.compareTo(ranks[b.id]!);
    });
    final picked = <_Seed>[];
    final artists = <String>{};
    for (final seed in ordered) {
      if (picked.length == 6) break;
      if (seed.artist.isEmpty || artists.add(seed.artist)) picked.add(seed);
    }
    for (final seed in ordered) {
      if (picked.length == 6) break;
      if (!picked.contains(seed)) picked.add(seed);
    }
    return picked;
  }

  /// Staged retrieval: related of seeds, related of the best candidates, then
  /// genre search. Candidates are filtered before ranking. The related
  /// endpoint is read as one page: the API contract exposes no next page.
  Future<
    ({
      Map<String, Track> candidates,
      Map<String, Map<String, double>> edges,
      Map<String, double> discounts,
    })
  >
  _gather(
    List<_Seed> picked,
    Set<String> excluded,
    void Function() check,
  ) async {
    final seedIds = {for (final seed in picked) seed.id};
    final candidates = <String, Track>{};
    final edges = <String, Map<String, double>>{};
    final discounts = <String, double>{};
    var requests = 0;

    void add(Track track, Map<String, double> weights, double discount) {
      if (!eligible(track) ||
          excluded.contains(track.id) ||
          seedIds.contains(track.id)) {
        return;
      }
      candidates.putIfAbsent(track.id, () => track);
      if (discount > (discounts[track.id] ?? 0)) discounts[track.id] = discount;
      final coordinates = edges.putIfAbsent(track.id, () => {});
      for (final weight in weights.entries) {
        final old = coordinates[weight.key] ?? 0;
        if (weight.value > old) coordinates[weight.key] = weight.value;
      }
    }

    Future<List<Track>> related(String id) async {
      if (requests >= maxRequests) return const [];
      requests++;
      check();
      try {
        final result = await api
            .relatedTracks(id)
            .timeout(const Duration(seconds: 15));
        check();
        return result;
      } catch (_) {
        check();
        return const [];
      }
    }

    for (final seed in picked) {
      final tracks = await related(seed.id);
      for (var rank = 0; rank < math.min(12, tracks.length); rank++) {
        add(tracks[rank], {seed.id: 1 / math.sqrt(rank + 1)}, 1);
      }
    }
    if (candidates.length < minPool) {
      final parents = edges.entries.toList()
        ..sort((a, b) {
          double sum(Map<String, double> m) =>
              m.values.fold(0, (s, v) => s + v);
          return sum(b.value).compareTo(sum(a.value));
        });
      for (final parent in parents.take(3)) {
        final tracks = await related(parent.key);
        for (var rank = 0; rank < math.min(12, tracks.length); rank++) {
          add(tracks[rank], {
            for (final e in parent.value.entries)
              e.key: e.value * .5 / math.sqrt(rank + 1),
          }, .6);
        }
      }
    }
    if (candidates.length < minPool) {
      final counts = <String, int>{};
      for (final seed in picked) {
        final genre = seed.genre.trim().toLowerCase();
        if (genre.isNotEmpty) counts[genre] = (counts[genre] ?? 0) + 1;
      }
      final genres = counts.keys.toList()
        ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
      for (final genre in genres.take(2)) {
        if (requests >= maxRequests) break;
        requests++;
        check();
        try {
          final found = await api
              .search(genre)
              .timeout(const Duration(seconds: 15));
          check();
          final roots = {
            for (final seed in picked)
              if (seed.genre.trim().toLowerCase() == genre) seed.id,
          };
          for (var rank = 0; rank < math.min(20, found.tracks.length); rank++) {
            if (roots.isEmpty) break;
            add(found.tracks[rank], {
              roots.first: .3 / math.sqrt(rank + 1),
            }, .3);
          }
        } catch (_) {
          check();
        }
      }
    }
    return (candidates: candidates, edges: edges, discounts: discounts);
  }

  /// Cosine to separate one-seed interest vectors, weighted by bounded support.
  /// Every fifth place explores an underrepresented, less-observed interest.
  List<Track> rank(
    List<Track> candidates,
    Map<String, StructuralVector> vectors,
    List<VectorInterest> profiles, {
    int limit = 10,
    Map<String, double> discounts = const {},
  }) {
    final units = {
      for (final p in profiles) p.seedId: StructuralVector({p.seedId: 1}),
    };
    final coverage = {for (final p in profiles) p.seedId: 0.0};
    final artists = <String, int>{};
    final remaining = {for (final t in candidates) t.id: t};
    final result = <Track>[];
    while (remaining.isNotEmpty && result.length < limit) {
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
        return value * (discounts[track.id] ?? 1);
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

/// A thumbs-down remembered locally: the track, when, and its artist handle.
class VectorDislike {
  const VectorDislike(this.trackId, this.at, this.artist);
  final String trackId;
  final DateTime at;
  final String? artist;
}

class _Seed {
  const _Seed(this.id, this.artist, this.genre);
  final String id;
  final String artist;
  final String genre;
}
