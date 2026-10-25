import 'dart:async';

import 'package:dio/dio.dart';
import 'package:waveform_app/core/api/soundcloud_api.dart';
import 'package:waveform_app/core/recommendations/ai_client.dart';
import 'package:waveform_app/core/recommendations/ai_config.dart';
import 'package:waveform_app/shared/models/track.dart';

Track realTrack(String id, {bool blocked = false}) => Track(
  id: id,
  title: 'track $id',
  artist: 'artist',
  durationMs: 120000,
  likes: 1,
  reposts: 0,
  plays: 10,
  waveform: const [0.3, 0.5],
  genre: 'ambient',
  description: 'PRIVATE DESCRIPTION',
  permalinkUrl: 'https://soundcloud.com/private?secret=PRIVATE_LINK',
  streamCandidates: ['https://stream.invalid/$id?token=STREAM_SECRET'],
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

class ScriptedAi implements AiClient {
  final payloads = <String>[];
  final systems = <String>[];
  final replies = <String>[
    '{"queries":["ambient","dream pop"]}',
    '{"recommendations":[{"id":"2","reason":"a possible fit"}]}',
  ];
  Completer<String>? pending;
  AiFailureForTest? failure;

  @override
  Future<String> complete({
    required AiConfig config,
    required AiConsent consent,
    required String apiKey,
    required String system,
    required String data,
    required CancelToken cancelToken,
  }) async {
    payloads.add(data);
    systems.add(system);
    if (failure != null) throw StateError('PRIVATE KEY $apiKey');
    if (pending != null) return pending!.future;
    return replies.removeAt(0);
  }
}

enum AiFailureForTest { transport }

const testConfig = AiConfig(
  endpoint: 'http://localhost:12345/v1',
  model: 'test-model',
);

const testConsent = AiConsent(
  destination: 'http://localhost:12345/v1/chat/completions',
  listening: false,
);
