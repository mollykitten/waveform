import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:waveform_app/core/api/mock_soundcloud_api.dart';
import 'package:waveform_app/core/api/stats.dart';
import 'package:waveform_app/shared/models/track.dart';

Track _t(int i, {String artist = 'a', String genre = 'g'}) => Track(
  id: '$i',
  title: 't$i',
  artist: artist,
  durationMs: 60000,
  likes: 0,
  reposts: 0,
  plays: 0,
  waveform: const [],
  genre: genre,
);

class _Api extends MockSoundcloudApi {
  _Api(this.pages, {this.failAtPage});
  final List<List<Track>> pages;
  final int? failAtPage;
  final offsets = <int>[];

  @override
  Future<List<Track>> historyPage({int limit = 50, int offset = 0}) async {
    final i = offset ~/ limit;
    offsets.add(offset);
    if (i == failAtPage) throw StateError('boom');
    return i < pages.length ? pages[i] : [];
  }
}

List<Track> _full(int start) => [for (var i = 0; i < 50; i++) _t(start + i)];

void main() {
  final log = Talker();

  test('empty history is empty, not an error', () async {
    final s = await loadListeningStats(_Api([]), log);
    expect(s.isEmpty, isTrue);
    expect(s.partial, isFalse);
    expect(s.capped, isFalse);
  });

  test('aggregates counts and summed track length', () async {
    final s = await loadListeningStats(
      _Api([
        [_t(1, artist: 'x'), _t(1, artist: 'x'), _t(2, artist: 'y')],
      ]),
      log,
    );
    expect(s.totalPlays, 3);
    expect(s.uniqueTracks, 2);
    expect(s.uniqueArtists, 2);
    expect(s.totalTrackLength, const Duration(minutes: 3));
    expect(s.topArtists.first, (name: 'x', count: 2));
    expect(s.partial, isFalse);
    expect(s.capped, isFalse);
  });

  test('first page failure is rethrown', () async {
    expect(
      loadListeningStats(_Api([], failAtPage: 0), log),
      throwsA(isA<StateError>()),
    );
  });

  test('later page failure keeps data and marks partial', () async {
    final s = await loadListeningStats(
      _Api([_full(0), _full(50)], failAtPage: 2),
      log,
    );
    expect(s.totalPlays, 100);
    expect(s.partial, isTrue);
    expect(s.capped, isFalse);
  });

  test('hitting the page limit marks sample as capped', () async {
    final api = _Api([for (var i = 0; i < 9; i++) _full(i * 50)]);
    final s = await loadListeningStats(api, log);
    expect(s.totalPlays, ListeningStats.sampleLimit);
    expect(s.capped, isTrue);
    expect(api.offsets.length, statsMaxPages);
  });

  test('exactly full last page then short data is not capped', () async {
    final s = await loadListeningStats(_Api([_full(0), _full(50)]), log);
    expect(s.totalPlays, 100);
    expect(s.capped, isFalse);
  });
}
