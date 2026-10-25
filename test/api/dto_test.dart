import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/api/dto/comment_dto.dart';
import 'package:waveform_app/core/api/dto/page_dto.dart';
import 'package:waveform_app/core/api/dto/playlist_dto.dart';
import 'package:waveform_app/core/api/dto/track_dto.dart';
import 'package:waveform_app/core/api/mappers.dart';
import 'package:waveform_app/shared/models/feed_post.dart';

/// Фикстуры смоделированы по реальной форме api-v2 (референс: yt-dlp soundcloud.py
/// + публичные гисты эндпоинтов). Заменить на снятые реальные ответы при интеграции.
const _trackJson = '''
{
  "id": 250011541,
  "title": "Subharmonic Drift",
  "duration": 254000,
  "full_duration": 254000,
  "genre": "Ambient",
  "created_at": "2020-01-01T10:00:00Z",
  "artwork_url": "https://i1.sndcdn.com/artworks-000123-large.jpg",
  "waveform_url": "https://wave.sndcdn.com/abc.json",
  "permalink_url": "https://soundcloud.com/voidwave/subharmonic-drift",
  "description": "all hardware, one take",
  "playback_count": 341000,
  "likes_count": 12400,
  "reposts_count": 892,
  "comment_count": 9,
  "streamable": true,
  "policy": "ALLOW",
  "user": {
    "id": 778,
    "username": "voidwave",
    "permalink": "voidwave",
    "avatar_url": "https://i1.sndcdn.com/avatars-000-large.jpg",
    "followers_count": 53600,
    "followings_count": 227,
    "track_count": 79,
    "verified": true
  },
  "media": {
    "transcodings": [
      {"url": "https://api-v2.soundcloud.com/media/.../stream/progressive",
       "preset": "mp3_0_0",
       "format": {"protocol": "progressive", "mime_type": "audio/mpeg"}},
      {"url": "https://api-v2.soundcloud.com/media/.../stream/hls",
       "preset": "opus_0_0",
       "format": {"protocol": "hls", "mime_type": "audio/ogg; codecs=\\"opus\\""}}
    ]
  }
}
''';

const _playlistJson = '''
{
  "id": 99001,
  "title": "A Love Letter to You",
  "is_album": true,
  "set_type": "album",
  "track_count": 11,
  "duration": 2200000,
  "likes_count": 4500,
  "artwork_url": "https://i1.sndcdn.com/artworks-pl-large.jpg",
  "user": {"id": 5, "username": "trippie redd", "permalink": "trippie"},
  "tracks": [{"id": 1, "title": "intro", "duration": 60000, "user": {"id":5,"username":"trippie redd","permalink":"trippie"}}]
}
''';

const _commentJson = '''
{"id": 7, "body": "this drop is unreal", "timestamp": 12000, "created_at": "2024-01-01T00:00:00Z",
 "track_id": 250011541, "user": {"id": 1, "username": "k-machina", "permalink": "kmachina"}}
''';

const _streamJson = '''
{
  "collection": [
    {"type": "track-repost", "created_at": "2024-05-01T00:00:00Z",
     "user": {"id": 2, "username": "hyperforms", "permalink": "hyperforms"},
     "track": {"id": 1, "title": "Peekaboo", "duration": 157000, "genre": "Dubstep",
               "playback_count": 595, "comment_count": 9,
               "user": {"id": 3, "username": "bd hbt", "permalink": "bdhbt"}}},
    {"type": "playlist", "created_at": "2024-05-01T00:00:00Z",
     "playlist": {"id": 50, "title": "set", "user": {"id": 9, "username": "dj", "permalink": "dj"}}}
  ],
  "next_href": "https://api-v2.soundcloud.com/stream?offset=xyz"
}
''';

void main() {
  group('TrackDto', () {
    final dto = TrackDto.fromJson(jsonDecode(_trackJson));

    test('parses core fields', () {
      expect(dto.id, 250011541);
      expect(dto.title, 'Subharmonic Drift');
      expect(dto.durationMs, 254000);
      expect(dto.playbackCount, 341000);
      expect(dto.likesCount, 12400);
      expect(dto.user.username, 'voidwave');
      expect(dto.user.verified, true);
    });

    test('parses transcodings', () {
      expect(dto.transcodings.length, 2);
      expect(dto.transcodings.any((t) => t.isHls), true);
    });

    test('stream candidates order HLS before progressive', () {
      final t = dto.toDomain();
      // Несмотря на progressive-first в JSON, HLS должен идти первым кандидатом.
      expect(t.streamCandidates.length, 2);
      expect(t.streamCandidates.first.endsWith('/stream/hls'), true);
      expect(t.streamCandidates.last.endsWith('/stream/progressive'), true);
      expect(t.streamUrl, t.streamCandidates.first);
    });

    test('excludes encrypted (DRM) transcodings from candidates', () {
      const json = '''
{
  "id": 1, "title": "drm track", "duration": 1000,
  "user": {"id": 1, "username": "u", "permalink": "u"},
  "media": {"transcodings": [
    {"url": "https://x/stream/hls", "preset": "opus_0_0",
     "format": {"protocol": "hls", "mime_type": "audio/ogg"}},
    {"url": "https://x/stream/cbc-encrypted-hls", "preset": "aac_160k",
     "format": {"protocol": "hls", "mime_type": "audio/mp4"}},
    {"url": "https://x/stream/progressive", "preset": "mp3_0_0",
     "format": {"protocol": "progressive", "mime_type": "audio/mpeg"}}
  ]}
}''';
      final t = TrackDto.fromJson(jsonDecode(json)).toDomain();
      expect(t.streamCandidates, [
        'https://x/stream/hls',
        'https://x/stream/progressive',
      ]);
    });

    test(
      'GO+ ctr-encrypted-hls → drmStreamCandidates по приоритету пресетов',
      () {
        const json = '''
{
  "id": 2, "title": "go+ track", "duration": 1000,
  "user": {"id": 1, "username": "u", "permalink": "u"},
  "media": {"transcodings": [
    {"url": "https://x/stream/ctr-abr", "preset": "abr_sq",
     "format": {"protocol": "ctr-encrypted-hls", "mime_type": "audio/mpegurl"}},
    {"url": "https://x/stream/ctr-96", "preset": "aac_96k",
     "format": {"protocol": "ctr-encrypted-hls", "mime_type": "audio/mp4"}},
    {"url": "https://x/stream/ctr-160", "preset": "aac_160k",
     "format": {"protocol": "ctr-encrypted-hls", "mime_type": "audio/mp4"}},
    {"url": "https://x/stream/hls", "preset": "opus_0_0",
     "format": {"protocol": "hls", "mime_type": "audio/ogg"}}
  ]}
}''';
        final t = TrackDto.fromJson(jsonDecode(json)).toDomain();
        // Зашифрованные не попадают в ordinary-кандидаты (just_audio их не ест).
        expect(t.streamCandidates, ['https://x/stream/hls']);
        // Честный AAC вперёд, abr-мастер — последним.
        expect(t.drmStreamCandidates, [
          'https://x/stream/ctr-160',
          'https://x/stream/ctr-96',
          'https://x/stream/ctr-abr',
        ]);
      },
    );

    test('maps to domain Track', () {
      final t = dto.toDomain();
      expect(t.id, '250011541');
      expect(t.artist, 'voidwave');
      expect(t.plays, 341000);
      expect(t.likes, 12400);
      expect(t.reposts, 892);
      expect(t.genre, 'Ambient');
      expect(t.coverUrl, contains('-t500x500.'));
      expect(t.postedAt, contains('ago'));
      expect(t.waveform, isNotEmpty);
    });
  });

  group('PlaylistDto', () {
    test('album maps to album kind', () {
      final dto = PlaylistDto.fromJson(jsonDecode(_playlistJson));
      expect(dto.isAlbum, true);
      expect(dto.trackCount, 11);
      final c = dto.toDomain();
      expect(c.subtitle, 'trippie redd');
      expect(c.kind.name, 'album');
    });
  });

  group('CommentDto', () {
    test('maps timecode and author', () {
      final c = CommentDto.fromJson(jsonDecode(_commentJson)).toDomain();
      expect(c.author, 'k-machina');
      expect(c.timecodeMs, 12000);
      expect(c.text, 'this drop is unreal');
    });
  });

  group('publisher_metadata.artist', () {
    test('publisher_metadata.artist overrides uploader username', () {
      final json =
          jsonDecode('''
  {
    "id": 1, "title": "T", "duration": 1000, "full_duration": 1000,
    "permalink_url": "https://soundcloud.com/up/t",
    "user": {"id": 7, "username": "uploader_acct", "permalink": "uploader_acct"},
    "publisher_metadata": {"artist": "Real Artist Name"}
  }''')
              as Map<String, dynamic>;
      final track = TrackDto.fromJson(json).toDomain();
      expect(track.artist, 'Real Artist Name'); // display = metadata
      expect(track.artistPermalink, 'uploader_acct'); // link = uploader
    });

    test('falls back to username when publisher artist absent/blank', () {
      final json =
          jsonDecode('''
  {
    "id": 2, "title": "T2", "duration": 1000,
    "user": {"id": 8, "username": "soloacct", "permalink": "soloacct"},
    "publisher_metadata": {"artist": "  "}
  }''')
              as Map<String, dynamic>;
      final track = TrackDto.fromJson(json).toDomain();
      expect(track.artist, 'soloacct');
    });

    test('no publisher_metadata at all falls back to username', () {
      final json =
          jsonDecode('''
  {
    "id": 3, "title": "T3", "duration": 1000,
    "user": {"id": 9, "username": "plainacct", "permalink": "plainacct"}
  }''')
              as Map<String, dynamic>;
      final track = TrackDto.fromJson(json).toDomain();
      expect(track.artist, 'plainacct');
    });
  });

  group('Stream page', () {
    final page = PageDto.parse(jsonDecode(_streamJson), StreamItemDto.fromJson);

    test('parses collection + pagination', () {
      expect(page.collection.length, 2);
      expect(page.nextHref, contains('offset'));
    });

    test('maps track-repost to FeedPost, skips playlist', () {
      final posts = page.collection
          .map((e) => e.toFeedPost())
          .whereType<FeedPost>()
          .toList();
      expect(posts.length, 1);
      expect(posts.first.actor, 'hyperforms');
      expect(posts.first.action, FeedAction.reposted);
      expect(posts.first.track.title, 'Peekaboo');
      expect(posts.first.tag, 'Dubstep');
    });
  });
}
