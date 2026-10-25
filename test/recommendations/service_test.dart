import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/recommendations/ai_client.dart';
import 'package:waveform_app/core/recommendations/models.dart';
import 'package:waveform_app/core/recommendations/recommendation_service.dart';

import 'support.dart';

void main() {
  late TestSoundcloud api;
  late ScriptedAi client;
  late RecommendationService service;
  setUp(() {
    api = TestSoundcloud();
    client = ScriptedAi();
    service = RecommendationService(api: api, client: client);
  });

  Future<List<Recommendation>> generate({
    CancelToken? token,
    bool listening = false,
  }) => service.generate(
    config: testConfig.withConsent(listening),
    consent: AiConsent(
      destination: testConfig.destination,
      listening: listening,
    ),
    apiKey: 'SESSION_SECRET',
    mood: 'quiet night',
    useListening: listening,
    cancelToken: token ?? CancelToken(),
    currentTrack: realTrack('current'),
  );

  test(
    'two genuine model stages rank only real deduplicated search results',
    () async {
      final result = await generate();
      expect(api.searches, ['ambient', 'dream pop']);
      expect(result.single.track, same(api.tracks[1]));
      expect(result.single.reason, 'a possible fit');
      expect(client.payloads.length, 2);
      expect(api.likesCalls, 0);
      expect(api.historyCalls, 0);
      for (final data in client.payloads) {
        for (final forbidden in [
          'SESSION_SECRET',
          'PRIVATE',
          'STREAM_SECRET',
          'description',
          'permalink',
          'streamCandidates',
        ]) {
          expect(data, isNot(contains(forbidden)));
        }
      }
    },
  );

  test('listening is optional, bounded to 20 seed metadata entries', () async {
    await generate(listening: true);
    expect(api.likesCalls, 1);
    expect(api.historyCalls, 1);
    final seeds = (jsonDecode(client.payloads.first) as Map)['seeds'] as List;
    expect(seeds.length, 20);
    expect(seeds.first['id'], 'current');
    expect(seeds.every((e) => (e as Map).length == 4), isTrue);
  });

  test(
    'candidate cap is 40 and blocked tracks never enter rank prompt',
    () async {
      api.tracks = [
        realTrack('blocked', blocked: true),
        ...List.generate(70, (i) => realTrack('$i')),
      ];
      await generate();
      final candidates = jsonDecode(client.payloads.last)['candidates'] as List;
      expect(candidates.length, lessThanOrEqualTo(40));
      expect(candidates.any((e) => e['id'] == 'blocked'), isFalse);
    },
  );

  test(
    'unapproved destination and listening never send a model request',
    () async {
      await expectLater(
        service.generate(
          config: testConfig,
          consent: const AiConsent(
            destination: 'https://other.invalid',
            listening: false,
          ),
          apiKey: '',
          mood: 'night',
          useListening: false,
          cancelToken: CancelToken(),
        ),
        throwsA(AiFailure.configuration),
      );
      await expectLater(
        service.generate(
          config: testConfig,
          consent: testConsent,
          apiKey: '',
          mood: 'night',
          useListening: true,
          cancelToken: CancelToken(),
        ),
        throwsA(AiFailure.configuration),
      );
      expect(client.payloads, isEmpty);
      expect(api.likesCalls, 0);
    },
  );

  test('cancelled model generation cannot start SoundCloud search', () async {
    final pending = client.pending = Completer<String>();
    final token = CancelToken();
    final future = generate(token: token);
    await Future<void>.delayed(Duration.zero);
    token.cancel();
    pending.complete('{"queries":["ambient"]}');
    await expectLater(future, throwsA(AiFailure.cancelled));
    expect(api.searches, isEmpty);
  });

  test(
    'no candidates does not request ranking or manufacture results',
    () async {
      api.tracks = [];
      await expectLater(generate(), throwsA(AiFailure.noTracks));
      expect(client.payloads.length, 1);
    },
  );

  test('search errors are safe and never become a fake AI fallback', () async {
    api.failSearch = true;
    await expectLater(generate(), throwsA(AiFailure.source));
    expect(client.payloads.length, 1);
  });
}
