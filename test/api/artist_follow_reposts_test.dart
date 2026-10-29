import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:waveform_app/core/api/client_id_resolver.dart';
import 'package:waveform_app/core/api/followed_users.dart';
import 'package:waveform_app/core/api/http_soundcloud_api.dart';
import 'package:waveform_app/core/api/liked_tracks.dart';
import 'package:waveform_app/core/api/mock_soundcloud_api.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/api/soundcloud_api.dart';
import 'package:waveform_app/core/api/soundcloud_auth.dart';
import 'package:waveform_app/core/audio/audio_engine.dart';
import 'package:waveform_app/features/artist/artist_screen.dart';
import 'package:waveform_app/shared/models/track.dart';

import '../recommendations/support.dart' show realTrack;
import '../support/fake_audio_engine.dart';
import '../support/stub_liked_tracks.dart';

Map<String, dynamic> _track(int id) => {
  'id': id,
  'title': 't$id',
  'duration': 1000,
  'user': {'id': 1, 'username': 'u', 'permalink': 'u'},
};

class _Adapter implements HttpClientAdapter {
  final paths = <String>[];
  final auths = <String?>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? stream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.uri.toString());
    auths.add(options.headers['Authorization'] as String?);
    final path = options.uri.path;
    Map<String, dynamic> body = {'collection': []};
    if (path == '/stream/users/5/reposts') {
      body = {
        'collection': [
          {'type': 'track-repost', 'track': _track(1)},
          {
            'type': 'playlist-repost',
            'playlist': {'id': 9, 'title': 'p'},
          },
          {'type': 'track-repost', 'track': _track(2)},
        ],
        'next_href':
            'https://api-v2.soundcloud.com/stream/users/5/reposts?offset=x',
      };
    } else if (path == '/me') {
      body = {'id': 7};
    } else if (path == '/users/7/followings') {
      final second = options.uri.queryParameters['offset'] == '2';
      body = second
          ? {
              'collection': [
                {'id': 30, 'username': 'c', 'permalink': 'c'},
              ],
            }
          : {
              'collection': [
                {'id': 10, 'username': 'a', 'permalink': 'a'},
                {'id': 20, 'username': 'b', 'permalink': 'b'},
              ],
              'next_href':
                  'https://api-v2.soundcloud.com/users/7/followings?offset=2',
            };
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _Ids extends ClientIdResolver {
  _Ids() : super(Dio());
  @override
  Future<String> get() async => 'cid';
}

HttpSoundcloudApi _api(_Adapter a, {bool authed = true}) => HttpSoundcloudApi(
  Dio()..httpClientAdapter = a,
  _Ids(),
  auth: SoundcloudAuth(clientId: 'cid', userToken: authed ? 'tok' : null),
  talker: TalkerFlutter.init(),
);

class _FakeAuth extends AuthController {
  @override
  SoundcloudAuth build() =>
      const SoundcloudAuth(clientId: 'cid', userToken: 'tok');

  void swap(String? token) =>
      state = SoundcloudAuth(clientId: 'cid', userToken: token);
}

/// Followings served page by page; each call is gated by a completer so tests
/// can interleave a toggle with the paging.
class _PagedApi extends MockSoundcloudApi {
  final pages = <List<String>>[
    ['1', '2'],
    ['3'],
  ];
  final gates = <int, Completer<void>>{};
  final failPages = <int>{};
  LikeOutcome writeOutcome = LikeOutcome.ok;
  final writes = <String>[];
  var calls = 0;

  @override
  Future<({List<String> ids, String? nextHref})> followingsPage({
    String? nextHref,
    int limit = 200,
  }) async {
    calls++;
    final i = nextHref == null ? 0 : int.parse(nextHref);
    await gates[i]?.future;
    if (failPages.contains(i)) throw StateError('boom');
    return (ids: pages[i], nextHref: i + 1 < pages.length ? '${i + 1}' : null);
  }

  @override
  Future<LikeOutcome> setFollowing(String userId, bool following) async {
    writes.add('${following ? '+' : '-'}$userId');
    return writeOutcome;
  }
}

class _RepostApi extends MockSoundcloudApi {
  final pages = <({List<Track> tracks, String? nextHref})>[];
  var fail = true;
  var calls = 0;

  @override
  Future<({List<Track> tracks, String? nextHref})> userRepostsPage(
    String userId, {
    String? nextHref,
    int limit = 20,
  }) async {
    calls++;
    if (fail) {
      fail = false;
      throw StateError('boom');
    }
    return pages[nextHref == null ? 0 : int.parse(nextHref)];
  }
}

class _Api extends MockSoundcloudApi {
  _Api(this.inner);
  final HttpSoundcloudApi inner;
  @override
  Future<({List<String> ids, String? nextHref})> followingsPage({
    String? nextHref,
    int limit = 200,
  }) => inner.followingsPage(nextHref: nextHref, limit: limit);
}

void main() {
  group('userRepostsPage', () {
    test('uses stream reposts, keeps tracks only, passes cursor', () async {
      final a = _Adapter();
      final page = await _api(a, authed: false).userRepostsPage('5');
      expect(a.paths.single, contains('/stream/users/5/reposts'));
      expect(a.auths.single, isNull); // public, no user token
      expect(page.tracks.map((t) => t.id), ['1', '2']);
      expect(page.nextHref, contains('offset=x'));
    });

    test('follows next_href and refuses foreign hosts', () async {
      final a = _Adapter();
      final api = _api(a, authed: false);
      await api.userRepostsPage(
        '5',
        nextHref:
            'https://api-v2.soundcloud.com/stream/users/5/reposts?offset=x',
      );
      expect(a.paths.single, contains('offset=x'));
      expect(
        () => api.userRepostsPage('5', nextHref: 'https://evil.example/x'),
        throwsStateError,
      );
    });
  });

  group('followings', () {
    test('followingsPage walks cursor and returns ids', () async {
      final a = _Adapter();
      final api = _api(a);
      final p1 = await api.followingsPage();
      expect(p1.ids, ['10', '20']);
      final p2 = await api.followingsPage(nextHref: p1.nextHref);
      expect(p2.ids, ['30']);
      expect(p2.nextHref, isNull);
    });

    test('anonymous → empty', () async {
      final p = await _api(_Adapter(), authed: false).followingsPage();
      expect(p.ids, isEmpty);
    });

    test('controller marks artists from page 2 as followed', () async {
      final api = _api(_Adapter());
      final c = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWith(_FakeAuth.new),
          soundcloudApiProvider.overrideWithValue(_Api(api)),
        ],
      );
      addTearDown(c.dispose);
      c.listen(followedUsersProvider, (_, _) {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.read(followedUsersProvider), {'10', '20', '30'});
    });
  });

  group('FollowedUsersController', () {
    late _PagedApi api;
    late ProviderContainer c;

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 20));

    ProviderContainer make() {
      final c = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWith(_FakeAuth.new),
          soundcloudApiProvider.overrideWithValue(api),
        ],
      );
      addTearDown(c.dispose);
      c.listen(followedUsersProvider, (_, _) {});
      return c;
    }

    setUp(() => api = _PagedApi());

    test('failed write rolls the toggle back', () async {
      c = make();
      await settle();
      api.writeOutcome = LikeOutcome.blocked;
      final n = c.read(followedUsersProvider.notifier);
      expect(await n.toggle('9'), LikeOutcome.blocked);
      expect(c.read(followedUsersProvider), {'1', '2', '3'});
      expect(await n.toggle('1'), LikeOutcome.blocked);
      expect(c.read(followedUsersProvider), contains('1'));
    });

    test('successful toggle sticks', () async {
      c = make();
      await settle();
      final n = c.read(followedUsersProvider.notifier);
      await n.toggle('9');
      await n.toggle('1');
      expect(c.read(followedUsersProvider), {'2', '3', '9'});
      expect(api.writes, ['+9', '-1']);
    });

    test('toggle during paging survives later pages', () async {
      api.gates[1] = Completer<void>();
      c = make();
      await settle();
      expect(c.read(followedUsersProvider), {'1', '2'});
      final n = c.read(followedUsersProvider.notifier);
      await n.toggle('1'); // unfollow an id already in the snapshot
      await n.toggle('3'); // follow an id that page 2 will also deliver
      await n.toggle('3'); // and unfollow it again
      api.gates[1]!.complete();
      await settle();
      expect(c.read(followedUsersProvider), {'2'});
    });

    test('page failure is retried, then reported as partial', () async {
      api.failPages.add(1);
      c = make();
      await settle();
      expect(c.read(followedUsersProvider), {'1', '2'});
      expect(c.read(followedUsersProvider.notifier).isComplete, isFalse);
      expect(api.calls, 3); // page 1, page 2, one retry of page 2
      api.failPages.clear();
      await c.read(followedUsersProvider.notifier).load();
      expect(c.read(followedUsersProvider), {'1', '2', '3'});
      expect(c.read(followedUsersProvider.notifier).isComplete, isTrue);
    });

    test('logout / account change resets the set', () async {
      c = make();
      await settle();
      expect(c.read(followedUsersProvider), isNotEmpty);
      api.pages
        ..clear()
        ..add(['42']);
      (c.read(authControllerProvider.notifier) as _FakeAuth).swap('other');
      await settle();
      expect(c.read(followedUsersProvider), {'42'});
    });
  });

  group('RepostsTab', () {
    Future<_RepostApi> pump(WidgetTester tester, _RepostApi api) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            audioEngineProvider.overrideWithValue(FakeAudioEngine()),
            soundcloudApiProvider.overrideWithValue(api),
            likedTracksProvider.overrideWith(StubLikedTracks.new),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: RepostsTab(userId: '5')),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      return api;
    }

    testWidgets('retry after failure, then load more', (tester) async {
      final api = _RepostApi()
        ..pages.addAll([
          (tracks: [realTrack('1')], nextHref: '1'),
          (tracks: [realTrack('2')], nextHref: null),
        ]);
      await pump(tester, api);
      expect(find.text('failed to load — tap to retry'), findsOneWidget);
      await tester.tap(find.text('failed to load — tap to retry'));
      await tester.pump();
      await tester.pump();
      expect(find.text('load more'), findsOneWidget);
      await tester.tap(find.text('load more'));
      await tester.pump();
      await tester.pump();
      expect(find.text('load more'), findsNothing);
      expect(api.calls, 3);
    });

    testWidgets('empty list says so', (tester) async {
      final api = _RepostApi()
        ..fail = false
        ..pages.add((tracks: <Track>[], nextHref: null));
      await pump(tester, api);
      expect(find.text('no reposts yet'), findsOneWidget);
      expect(find.text('load more'), findsNothing);
    });
  });
}
