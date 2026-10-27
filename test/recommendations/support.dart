import 'package:waveform_app/core/api/soundcloud_api.dart';
import 'package:waveform_app/shared/models/track.dart';

Track realTrack(
  String id, {
  bool blocked = false,
  String artist = 'artist',
  bool playable = true,
  int plays = 1000,
  int likes = 50,
}) => Track(
  id: id,
  title: 'track $id',
  artist: artist,
  durationMs: 120000,
  likes: likes,
  reposts: 0,
  plays: plays,
  waveform: const [0.3, 0.5],
  genre: 'ambient',
  description: 'PRIVATE DESCRIPTION',
  permalinkUrl: 'https://soundcloud.com/private?secret=PRIVATE_LINK',
  streamCandidates: playable
      ? ['https://stream.invalid/$id?token=STREAM_SECRET']
      : const [],
  blocked: blocked,
);

class TestSoundcloud implements SoundcloudApi {
  List<Track> tracks = [realTrack('1'), realTrack('2')];
  final searches = <String>[];
  int likesCalls = 0;
  int historyCalls = 0;
  bool failSearch = false;

  @override
  Future<SearchResults> search(String query) async {
    searches.add(query);
    if (failSearch) throw StateError('PRIVATE TRANSPORT ERROR');
    return (
      tracks: tracks,
      artists: const <Never>[],
      playlists: const <Never>[],
    );
  }

  @override
  Future<({List<Track> tracks, String? nextHref})> likesPage({
    String? nextHref,
    int limit = 50,
  }) async {
    likesCalls++;
    return (
      tracks: List.generate(30, (i) => realTrack('like$i')),
      nextHref: null,
    );
  }

  @override
  Future<List<Track>> historyPage({int limit = 50, int offset = 0}) async {
    historyCalls++;
    return List.generate(30, (i) => realTrack('history$i'));
  }

  @override
  Future<String?> resolveStreamUrl(String transcodingUrl) async =>
      'https://play.invalid/stream.mp3';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
