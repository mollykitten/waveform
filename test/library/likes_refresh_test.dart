import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/api/liked_tracks.dart';
import 'package:waveform_app/core/api/me_likes.dart';
import 'package:waveform_app/core/api/mock_soundcloud_api.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/api/soundcloud_api.dart';
import 'package:waveform_app/features/feed/widgets/feed_post_card.dart';
import 'package:waveform_app/shared/mock/mock_data.dart';
import 'package:waveform_app/shared/models/feed_post.dart';
import 'package:waveform_app/shared/models/track.dart';

import '../support/stub_liked_tracks.dart';

class _FakeApi extends MockSoundcloudApi {
  _FakeApi(this.liked);
  final List<Track> liked;
  bool fail = false;

  @override
  Future<LikeOutcome> setLiked(String trackId, bool like) async {
    if (like) {
      liked.insert(0, Mock.listeningHistory.firstWhere((t) => t.id == trackId));
    } else {
      liked.removeWhere((t) => t.id == trackId);
    }
    return LikeOutcome.ok;
  }

  @override
  Future<({List<Track> tracks, String? nextHref})> likesPage({
    String? nextHref,
    int limit = 50,
  }) async {
    if (fail) throw StateError('boom');
    return (tracks: List<Track>.of(liked), nextHref: null);
  }
}

void main() {
  test('toggle like refreshes the library likes list', () async {
    final tracks = Mock.listeningHistory;
    final api = _FakeApi([tracks[1]]);
    final container = ProviderContainer(
      overrides: [
        soundcloudApiProvider.overrideWithValue(api),
        likedTracksProvider.overrideWith(StubLikedTracks.new),
      ],
    );
    addTearDown(container.dispose);

    container.listen(meLikesPagedProvider, (_, _) {});
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(meLikesPagedProvider).tracks.map((t) => t.id), [
      tracks[1].id,
    ]);

    await container.read(likedTracksProvider.notifier).toggle(tracks[0].id);
    await Future<void>.delayed(Duration.zero);

    final ids = container.read(meLikesPagedProvider).tracks.map((t) => t.id);
    expect(ids, [tracks[0].id, tracks[1].id]);
  });

  test('refresh keeps the old list when the request fails', () async {
    final tracks = Mock.listeningHistory;
    final api = _FakeApi([tracks[1]]);
    final container = ProviderContainer(
      overrides: [soundcloudApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    container.listen(meLikesPagedProvider, (_, _) {});
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(meLikesPagedProvider).tracks, hasLength(1));

    api.fail = true;
    await container.read(meLikesPagedProvider.notifier).refresh();
    final state = container.read(meLikesPagedProvider);
    expect(state.tracks.map((t) => t.id), [tracks[1].id]);
    expect(state.error, isNull);
  });

  testWidgets('feed card heart is filled for a track in liked ids', (
    tester,
  ) async {
    final track = Mock.listeningHistory.first;
    final other = Mock.listeningHistory[1];
    Widget card(Track t) => FeedPostCard(
      post: FeedPost(
        id: 'p-${t.id}',
        actor: 'a',
        action: FeedAction.reposted,
        timeAgo: '1h',
        track: t,
        tag: 'x',
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          likedTracksProvider.overrideWith(() => StubLikedTracks({track.id})),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(children: [card(track), card(track), card(other)]),
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.favorite), findsNWidgets(2));
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
  });
}
