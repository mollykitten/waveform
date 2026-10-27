import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:waveform_app/core/api/client_id_resolver.dart';
import 'package:waveform_app/core/api/http_soundcloud_api.dart';
import 'package:waveform_app/core/api/soundcloud_auth.dart';

class _Adapter implements HttpClientAdapter {
  int meCalls = 0;
  final likesPaths = <String>[];
  final authHeaders = <String, String?>{};
  bool meFails = true;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? stream,
    Future<void>? cancelFuture,
  ) async {
    authHeaders[options.uri.toString()] =
        options.headers['Authorization'] as String?;
    final path = options.uri.path;
    if (path == '/me') {
      meCalls++;
      if (meFails) {
        return ResponseBody.fromString('boom', 500);
      }
      return ResponseBody.fromString('{"id":7}', 200, headers: _json);
    }
    if (path.endsWith('/track_likes')) {
      likesPaths.add(path);
      return ResponseBody.fromString('{"collection":[]}', 200, headers: _json);
    }
    return ResponseBody.fromString('{}', 200, headers: _json);
  }

  static const _json = {
    'content-type': ['application/json'],
  };

  @override
  void close({bool force = false}) {}
}

class _Ids extends ClientIdResolver {
  _Ids() : super(Dio());
  @override
  Future<String> get() async => 'cid';
}

void main() {
  late _Adapter adapter;
  late HttpSoundcloudApi api;
  setUp(() {
    adapter = _Adapter();
    api = HttpSoundcloudApi(
      Dio()..httpClientAdapter = adapter,
      _Ids(),
      auth: const SoundcloudAuth(clientId: 'cid', userToken: 'tok'),
      talker: TalkerFlutter.init(),
    );
  });

  test('a failed /me lookup is not cached for the life of the api', () async {
    await api.likesPage();
    expect(adapter.likesPaths, isEmpty);
    adapter.meFails = false;

    await api.likesPage();

    expect(adapter.meCalls, 2);
    expect(adapter.likesPaths, ['/users/7/track_likes']);
  });

  test('next_href on a foreign host never receives the bearer', () async {
    adapter.meFails = false;
    await api.likesPage(nextHref: 'https://evil.example/steal?x=1');

    expect(
      adapter.authHeaders.keys.where((u) => u.contains('evil.example')),
      isEmpty,
    );
  });
}
