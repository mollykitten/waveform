import '../../shared/models/artist.dart';
import '../../shared/models/collection.dart';
import '../../shared/models/comment.dart';
import '../../shared/models/feed_post.dart';
import '../../shared/models/track.dart';
import 'dto/comment_dto.dart';
import 'dto/playlist_dto.dart';
import 'dto/track_dto.dart';
import 'dto/user_dto.dart';
import 'dto/page_dto.dart';

/// Маппинг DTO api-v2 → доменные модели приложения.
/// Изолирует UI от формы внешнего API: меняется API — правим только тут.

/// Артворк в высоком разрешении: `...-large.jpg` → `...-t500x500.jpg`.
String? hiResArtwork(String? url) => url?.replaceFirst('-large.', '-t500x500.');

/// URL-ы Widevine-транскодингов GO+ (`ctr-encrypted-hls`), упорядоченные по
/// качеству пресета. Пусто → трек не DRM. Дешифрует ядро scdrm (core/drm/).
List<String> ctrTranscodingUrls(List<TranscodingDto> transcodings) {
  final ctr = [
    for (final t in transcodings)
      if (t.isCtr) t,
  ]..sort((a, b) => a.drmRank.compareTo(b.drmRank));
  return [for (final t in ctr) t.url];
}

/// ISO-дата → человекочитаемое «N days ago».
String relativeTime(String? iso) {
  if (iso == null) return '';
  final dt = DateTime.tryParse(iso);
  if (dt == null) return '';
  final d = DateTime.now().difference(dt);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} minutes ago';
  if (d.inHours < 24) return '${d.inHours} hours ago';
  if (d.inDays < 7) return '${d.inDays} days ago';
  if (d.inDays < 30) return '${d.inDays ~/ 7} weeks ago';
  if (d.inDays < 365) return '${d.inDays ~/ 30} months ago';
  return '${d.inDays ~/ 365} years ago';
}

extension TrackDtoMapper on TrackDto {
  Track toDomain() => Track(
    id: '$id',
    title: title,
    artist: (publisherArtist != null && publisherArtist!.trim().isNotEmpty)
        ? publisherArtist!.trim()
        : user.username,
    artistPermalink: user.permalink,
    durationMs: durationMs,
    likes: likesCount,
    reposts: repostsCount,
    plays: playbackCount,
    // Процедурная заглушка по id — мгновенный плейсхолдер; реальная форма
    // лениво подгружается из [waveformUrl] виджетом LiveWaveform.
    waveform: Track.generateWaveform(id),
    waveformUrl: waveformUrl,
    coverUrl: hiResArtwork(artworkUrl),
    permalinkUrl: permalinkUrl,
    // HLS-кандидаты сначала, progressive — как фолбэк (часть HLS-ссылок 404).
    // Зашифрованные (DRM) транскодинги исключаем — just_audio их не играет.
    streamCandidates: [
      for (final t in transcodings)
        if (t.isHls && !t.isEncrypted) t.url,
      for (final t in transcodings)
        if (!t.isHls && !t.isEncrypted) t.url,
    ],
    drmStreamCandidates: ctrTranscodingUrls(transcodings),
    genre: (genre == null || genre!.isEmpty) ? 'electronic' : genre!,
    postedAt: relativeTime(createdAt),
    description: description ?? '',
  );
}

extension UserDtoMapper on UserDto {
  Artist toDomain() => Artist(
    id: '$id',
    handle: permalink, // слаг для /resolve, а не отображаемое имя
    name: username,
    followers: followersCount,
    trackCount: trackCount,
    likesCount: likesCount,
    playlistCount: playlistCount,
    followingsCount: followingsCount,
    verified: verified,
    avatarUrl: hiResArtwork(avatarUrl),
  );
}

extension PlaylistDtoMapper on PlaylistDto {
  Collection toDomain() => Collection(
    id: '$id',
    title: title,
    subtitle: user.username,
    kind: (isAlbum || setType == 'album')
        ? CollectionKind.album
        : CollectionKind.playlist,
    trackCount: trackCount,
    coverUrl: hiResArtwork(artworkUrl),
  );
}

extension CommentDtoMapper on CommentDto {
  Comment toDomain() => Comment(
    id: '$id',
    author: user.username,
    timecodeMs: timestampMs,
    text: body,
  );
}

extension StreamItemDtoMapper on StreamItemDto {
  /// Только трек-элементы ленты → FeedPost (плейлисты пока пропускаем).
  FeedPost? toFeedPost() {
    final t = track;
    if (!isTrack || t == null) return null;
    return FeedPost(
      id: '${t.id}-$type',
      actor: actor?.username ?? t.user.username,
      action: isRepost ? FeedAction.reposted : FeedAction.posted,
      timeAgo: relativeTime(createdAt),
      track: t.toDomain(),
      tag: (t.genre == null || t.genre!.isEmpty) ? 'music' : t.genre!,
      comments: t.commentCount,
    );
  }
}

extension PageMapper<T> on PageDto<T> {
  List<R> mapList<R>(R Function(T) f) => collection.map(f).toList();
}

extension TrackListFeedMapper on List<Track> {
  /// Анонимная лента: треки как посты «posted».
  List<FeedPost> toFeedPosts() => [
    for (final t in this)
      FeedPost(
        id: t.id,
        actor: t.artist,
        action: FeedAction.posted,
        timeAgo: t.postedAt,
        track: t,
        tag: t.genre,
      ),
  ];
}
