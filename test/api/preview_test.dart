import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/api/dto/track_dto.dart';
import 'package:waveform_app/core/api/mappers.dart';

void main() {
  TrackDto parse(List<Map<String, Object>> sources, {String? policy}) =>
      TrackDto.fromJson({
        'id': 1,
        'title': 'preview',
        'duration': 30000,
        'full_duration': 231184,
        'user': {'id': 1, 'username': 'artist'},
        'policy': policy,
        'media': {'transcodings': sources},
      });
  Map<String, Object> source(String url, {bool snipped = false}) => {
    'url': url,
    'snipped': snipped,
    'format': {'protocol': 'hls'},
  };

  test(
    'live SNIP shape excludes preview sources and preserves full duration',
    () {
      final track = parse([
        source('https://x/preview', snipped: true),
      ], policy: 'SNIP').toDomain();
      expect(track.blocked, isTrue);
      expect(track.streamCandidates, isEmpty);
      expect(track.durationMs, 231184);
      expect(track.copyWith(minted: true).blocked, isTrue);
    },
  );

  test('mixed preview and full sources retain full playback', () {
    final track = parse([
      source('https://x/preview', snipped: true),
      source('https://x/full'),
    ]).toDomain();
    expect(track.blocked, isFalse);
    expect(track.streamCandidates, ['https://x/full']);
  });

  test('BLOCK excludes even full candidates', () {
    final track = parse([source('https://x/full')], policy: 'BLOCK').toDomain();
    expect(track.blocked, isTrue);
    expect(track.streamCandidates, isEmpty);
  });

  test('encrypted-only and empty sources retain main generic behavior', () {
    expect(parse([source('https://x/encrypted')]).isBlocked, isFalse);
    expect(parse([]).isBlocked, isFalse);
  });
}
