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
  Map<String, Object> source(
    String url, {
    bool snipped = false,
    String protocol = 'hls',
  }) => {
    'url': url,
    'snipped': snipped,
    'format': {'protocol': protocol},
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
      expect(track.copyWith(waveform: const [0.5]).blocked, isTrue);
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

  test('full DRM and plain preview remain playable through DRM', () {
    final track = parse([
      source('https://x/preview', snipped: true),
      source('https://x/drm', protocol: 'ctr-encrypted-hls'),
    ]).toDomain();
    expect(track.blocked, isFalse);
    expect(track.streamCandidates, isEmpty);
    expect(track.drmStreamCandidates, ['https://x/drm']);
  });

  test('encrypted-only and empty sources retain main generic behavior', () {
    final dto = parse([
      source('https://x/stream', protocol: 'ctr-encrypted-hls'),
    ]);
    expect(dto.transcodings.single.isEncrypted, isTrue);
    expect(dto.isBlocked, isFalse);
    expect(dto.toDomain().streamCandidates, isEmpty);
    expect(dto.toDomain().drmStreamCandidates, ['https://x/stream']);
    expect(parse([]).isBlocked, isFalse);
  });

  test('snipped DRM candidates are excluded alongside plain previews', () {
    final track = parse([
      source('https://x/preview', snipped: true),
      source('https://x/drm', protocol: 'ctr-encrypted-hls', snipped: true),
    ]).toDomain();
    expect(track.blocked, isTrue);
    expect(track.streamCandidates, isEmpty);
    expect(track.drmStreamCandidates, isEmpty);
  });

  test('explicit BLOCK excludes full DRM candidates too', () {
    final track = parse([
      source('https://x/full'),
      source('https://x/drm', protocol: 'ctr-encrypted-hls'),
    ], policy: 'BLOCK').toDomain();
    expect(track.blocked, isTrue);
    expect(track.streamCandidates, isEmpty);
    expect(track.drmStreamCandidates, isEmpty);
  });
}
