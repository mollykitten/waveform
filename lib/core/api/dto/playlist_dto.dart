import 'json.dart';
import 'track_dto.dart';
import 'user_dto.dart';

/// SoundCloud api-v2 `playlist` объект (плейлисты и альбомы).
class PlaylistDto {
  const PlaylistDto({
    required this.id,
    required this.title,
    required this.user,
    this.isAlbum = false,
    this.setType,
    this.trackCount = 0,
    this.durationMs = 0,
    this.artworkUrl,
    this.permalinkUrl,
    this.likesCount = 0,
    this.genre,
    this.tracks = const [],
  });

  final int id;
  final String title;
  final UserDto user;
  final bool isAlbum;
  final String? setType; // album / playlist / ep / single
  final int trackCount;
  final int durationMs;
  final String? artworkUrl;
  final String? permalinkUrl;
  final int likesCount;
  final String? genre;
  final List<TrackDto> tracks;

  factory PlaylistDto.fromJson(Map<String, dynamic> j) => PlaylistDto(
    id: asInt(j['id']),
    title: asStr(j['title']),
    user: UserDto.fromJson(asMap(j['user'])),
    isAlbum: asBool(j['is_album']),
    setType: j['set_type'] as String?,
    // У системных плейлистов нет `track_count` — считаем по `tracks[]`.
    trackCount: j['track_count'] == null
        ? asMapList(j['tracks']).length
        : asInt(j['track_count']),
    durationMs: asInt(j['duration']),
    // У системных плейлистов обложка только в `calculated_artwork_url`.
    artworkUrl: (j['artwork_url'] ?? j['calculated_artwork_url']) as String?,
    permalinkUrl: j['permalink_url'] as String?,
    likesCount: asInt(j['likes_count']),
    genre: j['genre'] as String?,
    // В списках треки часто приходят «обрезанными» (только id) — берём полные.
    tracks: asMapList(
      j['tracks'],
    ).where((t) => t.containsKey('title')).map(TrackDto.fromJson).toList(),
  );
}
