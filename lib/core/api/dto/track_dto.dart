import 'json.dart';
import 'user_dto.dart';

/// Одна запись `media.transcodings[]` — источник стрима (HLS/progressive).
class TranscodingDto {
  const TranscodingDto({
    required this.url,
    required this.preset,
    required this.protocol,
    required this.mimeType,
  });

  final String url;
  final String preset; // mp3_0_0 / opus_0_0 / aac_...
  final String protocol; // hls / progressive
  final String mimeType;

  bool get isHls => protocol == 'hls';

  /// Зашифрованный (DRM) поток — `cbc-encrypted-hls` / `ctr-encrypted-hls`.
  /// just_audio/AVPlayer его не проигрывает («unsupported URL»), поэтому такие
  /// транскодинги нельзя предлагать как источник.
  bool get isEncrypted =>
      protocol.contains('encrypted') || url.contains('encrypted');

  factory TranscodingDto.fromJson(Map<String, dynamic> j) {
    final format = asMap(j['format']);
    return TranscodingDto(
      url: asStr(j['url']),
      preset: asStr(j['preset']),
      protocol: asStr(format['protocol']),
      mimeType: asStr(format['mime_type']),
    );
  }
}

/// SoundCloud api-v2 `track` объект.
class TrackDto {
  const TrackDto({
    required this.id,
    required this.title,
    required this.durationMs,
    required this.user,
    this.genre,
    this.createdAt,
    this.artworkUrl,
    this.waveformUrl,
    this.permalinkUrl,
    this.description,
    this.playbackCount = 0,
    this.likesCount = 0,
    this.repostsCount = 0,
    this.commentCount = 0,
    this.streamable = true,
    this.publisherArtist,
    this.transcodings = const [],
  });

  final int id;
  final String title;
  final int durationMs;
  final UserDto user;
  final String? genre;
  final String? createdAt;
  final String? artworkUrl;
  final String? waveformUrl;
  final String? permalinkUrl;
  final String? description;
  final int playbackCount;
  final int likesCount;
  final int repostsCount;
  final int commentCount;
  final bool streamable;

  /// `publisher_metadata.artist` — реальный исполнитель (может отличаться от
  /// загрузившего). Web показывает именно его. null/пусто → берём username.
  final String? publisherArtist;
  final List<TranscodingDto> transcodings;

  factory TrackDto.fromJson(Map<String, dynamic> j) {
    final media = asMap(j['media']);
    return TrackDto(
      id: asInt(j['id']),
      title: asStr(j['title']),
      // api-v2 отдаёт duration в мс; full_duration — без сниппета.
      durationMs: asInt(j['full_duration'] ?? j['duration']),
      user: UserDto.fromJson(asMap(j['user'])),
      genre: j['genre'] as String?,
      createdAt: j['created_at'] as String?,
      artworkUrl: j['artwork_url'] as String?,
      waveformUrl: j['waveform_url'] as String?,
      permalinkUrl: j['permalink_url'] as String?,
      description: j['description'] as String?,
      playbackCount: asInt(j['playback_count']),
      likesCount: asInt(j['likes_count'] ?? j['favoritings_count']),
      repostsCount: asInt(j['reposts_count']),
      commentCount: asInt(j['comment_count']),
      streamable: asBool(j['streamable'], true),
      publisherArtist: () {
        final v = asMap(j['publisher_metadata'])['artist'];
        return v is String && v.trim().isNotEmpty ? v : null;
      }(),
      transcodings: asMapList(
        media['transcodings'],
      ).map(TranscodingDto.fromJson).toList(),
    );
  }
}
