import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/recommendations/models.dart';
import 'package:waveform_app/core/recommendations/wave_blend.dart';

import 'support.dart';

List<Recommendation> list(WaveSource source, String prefix, int count) => [
  for (var i = 0; i < count; i++)
    Recommendation(
      realTrack('$prefix$i', artist: '$prefix$i'),
      source.reason,
      source: source,
    ),
];

Map<WaveSource, int> counts(List<Recommendation> items) => {
  for (final source in WaveSource.values)
    source: items.where((i) => i.source == source).length,
};

void main() {
  test('half related, a quarter each from stream and co-likers', () {
    final out = blendBySource({
      WaveSource.related: list(WaveSource.related, 'r', 20),
      WaveSource.stream: list(WaveSource.stream, 's', 20),
      WaveSource.coLikers: list(WaveSource.coLikers, 'c', 20),
    }, limit: 20);
    expect(out, hasLength(20));
    expect(counts(out), {
      WaveSource.related: 10,
      WaveSource.stream: 5,
      WaveSource.coLikers: 5,
    });
    // every prefix of a batch keeps the proportions, not just the whole list
    expect(counts(out.take(8).toList()), {
      WaveSource.related: 4,
      WaveSource.stream: 2,
      WaveSource.coLikers: 2,
    });
  });

  test('an empty source hands its quota to the others', () {
    final out = blendBySource({
      WaveSource.related: list(WaveSource.related, 'r', 20),
      WaveSource.stream: list(WaveSource.stream, 's', 20),
    }, limit: 20);
    expect(out, hasLength(20));
    expect(counts(out)[WaveSource.coLikers], 0);
    expect(counts(out)[WaveSource.related], 10);
    expect(counts(out)[WaveSource.stream], 10);
  });

  test('a single source fills the whole batch', () {
    final out = blendBySource({
      WaveSource.coLikers: list(WaveSource.coLikers, 'c', 7),
    }, limit: 20);
    expect(out, hasLength(7));
    expect(counts(out)[WaveSource.coLikers], 7);
  });

  test('a track is taken once, and an artist at most twice', () {
    final shared = realTrack('same', artist: 'same');
    final out = blendBySource({
      WaveSource.related: [
        Recommendation(shared, 'a'),
        for (var i = 0; i < 4; i++)
          Recommendation(realTrack('a$i', artist: 'loud'), 'a'),
      ],
      WaveSource.stream: [
        Recommendation(shared, 's', source: WaveSource.stream),
      ],
    }, limit: 10);
    expect(out.where((r) => r.track.id == 'same'), hasLength(1));
    expect(out.where((r) => r.track.artistHandle == 'loud'), hasLength(2));
  });

  test('nothing in, nothing out', () {
    expect(blendBySource({}, limit: 10), isEmpty);
  });

  test('scores are never mixed: each source keeps its own order', () {
    final out = blendBySource({
      WaveSource.related: list(WaveSource.related, 'r', 6),
      WaveSource.coLikers: list(WaveSource.coLikers, 'c', 6),
    }, limit: 12);
    expect(
      out.where((r) => r.source == WaveSource.coLikers).map((r) => r.track.id),
      ['c0', 'c1', 'c2', 'c3', 'c4', 'c5'],
    );
  });
}
