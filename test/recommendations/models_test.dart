import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/recommendations/models.dart';

import 'support.dart';

void main() {
  test('strict plans accept only one or two bounded unique search strings', () {
    expect(parseSearchPlan('{"queries":["ambient"]}'), ['ambient']);
    for (final input in [
      '```json\n{"queries":["ambient"]}\n```',
      '{"queries":[]}',
      '{"queries":["a","b","c"]}',
      '{"queries":["a","a"]}',
      '{"queries":[42]}',
      '{"queries":["https://evil.invalid"]}',
      '{"queries":["a"],"tool":"leak credentials"}',
      jsonEncode({
        'queries': ['x' * 121],
      }),
    ]) {
      expect(() => parseSearchPlan(input), throwsA(AiFailure.malformed));
    }
  });

  test(
    'ranking returns original objects and rejects adversarial IDs/fields',
    () {
      final track = realTrack('1');
      final valid = '{"recommendations":[{"id":"1","reason":"try this"}]}';
      expect(parseRanking(valid, [track]).single.track, same(track));
      for (final input in [
        '{"recommendations":[{"id":"invented","reason":"x"}]}',
        '{"recommendations":[{"id":1,"reason":"x"}]}',
        '{"recommendations":[{"id":"1","reason":""}]}',
        '{"recommendations":[{"id":"1","reason":"https://evil.invalid"}]}',
        '{"recommendations":[{"id":"1","reason":"x","url":"evil"}]}',
        '{"recommendations":[{"id":"1","reason":"x"},'
            '{"id":"1","reason":"duplicate"}]}',
        jsonEncode({
          'recommendations': [
            {'id': '1', 'reason': 'x' * 241},
          ],
        }),
        jsonEncode({
          'recommendations': List.generate(
            11,
            (_) => {'id': '1', 'reason': 'x'},
          ),
        }),
      ]) {
        expect(
          () => parseRanking(input, [track]),
          throwsA(AiFailure.malformed),
        );
      }
    },
  );

  test('metadata whitelist excludes all URLs, descriptions and streams', () {
    final data = jsonEncode(trackMetadata(realTrack('1')));
    expect(
      jsonDecode(data).keys,
      unorderedEquals(['id', 'title', 'artist', 'genre']),
    );
    expect(data, isNot(contains('PRIVATE')));
    expect(data, isNot(contains('STREAM_SECRET')));
    expect(
      boundedText('hello https://private.invalid/path\nworld', 12),
      'hello  world',
    );
    expect(boundedText('🎧' * 500, 20).runes.length, 20);
    expect(
      () => validatedMood('visit https://private.invalid'),
      throwsA(AiFailure.configuration),
    );
    expect(() => validatedMood('x' * 501), throwsA(AiFailure.configuration));
  });
}
