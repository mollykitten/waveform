import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:waveform_app/core/api/client_id_resolver.dart';
import 'package:waveform_app/core/api/followed_users.dart';
import 'package:waveform_app/core/api/http_soundcloud_api.dart';
import 'package:waveform_app/core/api/mock_soundcloud_api.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/api/soundcloud_auth.dart';

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
}
