import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/api/liked_tracks.dart';
import 'package:waveform_app/core/api/me_likes.dart';
import 'package:waveform_app/core/api/mock_soundcloud_api.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/api/soundcloud_api.dart';
import 'package:waveform_app/features/feed/widgets/feed_post_card.dart';
import 'package:waveform_app/shared/models/feed_post.dart';
import 'package:waveform_app/shared/models/track.dart';

import '../support/stub_liked_tracks.dart';

Track _t(int i) => Track(
  id: 't$i',
  title: 'track $i',
  artist: 'artist',
  durationMs: 1000,
  likes: 10,
  reposts: 0,
  plays: 0,
  waveform: const [0.5],
);

/// Лайки как сервер: новые сверху, страницы по [limit] с курсором-индексом.
class _FakeApi extends MockSoundcloudApi {
  _FakeApi(this.server);
  final List<Track> server;
  int likesCalls = 0;
  bool fail = false;
  LikeOutcome outcome = LikeOutcome.ok;

  @override
  Future<LikeOutcome> setLiked(String trackId, bool like) async => outcome;

  @override
  Future<({List<Track> tracks, String? nextHref})> likesPage({
    String? nextHref,
    int limit = 50,
  }) async {
    likesCalls++;
    if (fail) throw StateError('boom');
    final start = nextHref == null ? 0 : int.parse(nextHref);
    final end = (start + limit).clamp(0, server.length);
    return (
      tracks: server.sublist(start, end),
      nextHref: end < server.length ? '$end' : null,
    );
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

ProviderContainer _container(_FakeApi api, {Set<String> liked = const {}}) {
  final c = ProviderContainer(
    overrides: [
      soundcloudApiProvider.overrideWithValue(api),
      likedTracksProvider.overrideWith(() => StubLikedTracks(liked)),
    ],
  );
  addTearDown(c.dispose);
  c.listen(meLikesPagedProvider, (_, _) {});
  return c;
}

List<String> _ids(ProviderContainer c) =>
    c.read(meLikesPagedProvider).tracks.map((t) => t.id).toList();

void main() {
  test(
    'like/unlike edits the likes list locally without a network call',
    () async {
      final api = _FakeApi([for (var i = 1; i <= 3; i++) _t(i)]);
      final c = _container(api);
      await _settle();
      final calls = api.likesCalls;

      await c.read(likedTracksProvider.notifier).toggle('t9', track: _t(9));
      expect(_ids(c), ['t9', 't1', 't2', 't3']);

      await c.read(likedTracksProvider.notifier).toggle('t9');
      expect(_ids(c), ['t1', 't2', 't3']);
      expect(api.likesCalls, calls);
    },
  );

  test('failed like leaves the likes list untouched', () async {
    final api = _FakeApi([_t(1)])..outcome = LikeOutcome.failed;
    final c = _container(api);
    await _settle();

    await c.read(likedTracksProvider.notifier).toggle('t9', track: _t(9));
    expect(_ids(c), ['t1']);
  });

  test(
    'refresh merges the fresh head without truncating loaded pages',
    () async {
      final api = _FakeApi([for (var i = 1; i <= 120; i++) _t(i)]);
      final c = _container(api);
      await _settle();
      await c.read(meLikesPagedProvider.notifier).loadAll();
      expect(_ids(c), hasLength(120));

      // На сервере: t1 снят, добавлен новый t0.
      api.server
        ..removeAt(0)
        ..insert(0, _t(0));
      await c.read(meLikesPagedProvider.notifier).refresh();

      final ids = _ids(c);
      expect(ids.first, 't0');
      expect(ids, isNot(contains('t1')));
      expect(ids, hasLength(120));
      expect(ids.toSet(), hasLength(120));
      expect(c.read(meLikesPagedProvider).hasMore, isFalse);
    },
  );

  test(
    'refresh keeps the list and the cursor when the request fails',
    () async {
      final api = _FakeApi([for (var i = 1; i <= 60; i++) _t(i)]);
      final c = _container(api);
      await _settle();
      final before = c.read(meLikesPagedProvider);

      api.fail = true;
      await c.read(meLikesPagedProvider.notifier).refresh();
      final after = c.read(meLikesPagedProvider);
      expect(after.tracks, before.tracks);
      expect(after.nextHref, before.nextHref);
      expect(after.error, isNull);
    },
  );

  test('refresh does not reset an in-flight loadNext', () async {
    final api = _FakeApi([for (var i = 1; i <= 120; i++) _t(i)]);
    final c = _container(api);
    await _settle();

    final n = c.read(meLikesPagedProvider.notifier);
    final next = n.loadNext();
    final refresh = n.refresh();
    await Future.wait([next, refresh]);

    final ids = _ids(c);
    expect(ids.toSet(), hasLength(ids.length));
    expect(ids, hasLength(100));
    expect(c.read(meLikesPagedProvider).isLoadingMore, isFalse);
  });

  test('syncRecent adds ids liked elsewhere to likedTracksProvider', () async {
    final api = _FakeApi([_t(1), _t(2)]);
    // Реальный контроллер без auth: подменяем только build().
    final liked = _SyncLiked();
    final c2 = ProviderContainer(
      overrides: [
        soundcloudApiProvider.overrideWithValue(api),
        likedTracksProvider.overrideWith(() => liked),
      ],
    );
    addTearDown(c2.dispose);
    expect(c2.read(likedTracksProvider), {'old'});

    await c2.read(likedTracksProvider.notifier).syncRecent();
    expect(c2.read(likedTracksProvider), {'old', 't1', 't2'});
  });

  test('like made during a silent reload survives its final write', () async {
    final api = _SlowApi([_t(1)]);
    final c = ProviderContainer(
      overrides: [
        soundcloudApiProvider.overrideWithValue(api),
        likedTracksProvider.overrideWith(() => _SyncLiked()),
      ],
    );
    addTearDown(c.dispose);
    final n = c.read(likedTracksProvider.notifier);

    final reload = n.reload();
    await n.toggle('t9');
    expect(c.read(likedTracksProvider), contains('t9'));
    api.gate.complete();
    await reload;

    expect(c.read(likedTracksProvider), {'t1', 't9'});
  });

  group('feed card', () {
    Widget card(Track t) => FeedPostCard(
      post: FeedPost(
        id: 'p-${t.id}-${t.hashCode}',
        actor: 'a',
        action: FeedAction.reposted,
        timeAgo: '1h',
        track: t,
        tag: 'x',
      ),
    );

    testWidgets('heart is filled from liked ids on repost and original', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            likedTracksProvider.overrideWith(() => StubLikedTracks({'t1'})),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: ListView(children: [card(_t(1)), card(_t(1)), card(_t(2))]),
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.favorite), findsNWidgets(2));
      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    });

    testWidgets('tap on the heart likes optimistically', (tester) async {
      final api = _FakeApi([]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            soundcloudApiProvider.overrideWithValue(api),
            likedTracksProvider.overrideWith(StubLikedTracks.new),
          ],
          child: MaterialApp(
            home: Scaffold(body: ListView(children: [card(_t(1))])),
          ),
        ),
      );
      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
      expect(find.text('10'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.favorite_border));
      await tester.pump();
      expect(find.byIcon(Icons.favorite), findsOneWidget);
      expect(find.text('11'), findsOneWidget);
      await tester.pumpAndSettle();
    });
  });
}

class _SyncLiked extends LikedTracksController {
  @override
  Set<String> build() => {'old'};
}

class _SlowApi extends _FakeApi {
  _SlowApi(super.server);
  final gate = Completer<void>();

  @override
  Future<({List<Track> tracks, String? nextHref})> likesPage({
    String? nextHref,
    int limit = 50,
  }) async {
    await gate.future;
    return super.likesPage(nextHref: nextHref, limit: limit);
  }
}
