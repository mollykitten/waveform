// Manual live flow only. No *_test.dart suffix: never part of default CI.
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:waveform_app/core/api/client_id_resolver.dart';
import 'package:waveform_app/core/api/http_soundcloud_api.dart';
import 'package:waveform_app/core/api/soundcloud_api.dart';
import 'package:waveform_app/core/recommendations/ai_client.dart';
import 'package:waveform_app/core/recommendations/ai_config.dart';
import 'package:waveform_app/core/recommendations/models.dart';
import 'package:waveform_app/core/recommendations/recommendation_service.dart';
import 'package:waveform_app/shared/models/track.dart';

/// Observes real responses; every request still uses the production HTTP API.
class ObservedSoundcloudApi extends HttpSoundcloudApi {
  ObservedSoundcloudApi(super.dio, super.ids) : super(talker: Talker());

  final returned = <String, Track>{};
  int searchCalls = 0;

  @override
  Future<SearchResults> search(String query) async {
    searchCalls++;
    final result = await super.search(query);
    for (final track in result.tracks) {
      returned.putIfAbsent(track.id, () => track);
    }
    return result;
  }
}

/// Records only stage counts/JSON for assertions; transport remains real.
class ObservedAiClient implements AiClient {
  ObservedAiClient(this.delegate);
  final HttpAiClient delegate;
  final stages = <Map<String, dynamic>>[];

  @override
  Future<String> complete({
    required AiConfig config,
    required AiConsent consent,
    required String apiKey,
    required String system,
    required String data,
    required CancelToken cancelToken,
  }) {
    expect(apiKey, isEmpty);
    expect(consent.listening, isFalse);
    stages.add(jsonDecode(data) as Map<String, dynamic>);
    return delegate.complete(
      config: config,
      consent: consent,
      apiKey: apiKey,
      system: system,
      data: data,
      cancelToken: cancelToken,
    );
  }
}

void main() {
  for (final mood in [
    'instrumental ambient music for quiet reading',
    'energetic drum and bass music for running',
  ]) {
    test(
      'live RecommendationService: $mood',
      () async {
        const config = AiConfig(
          endpoint: 'http://127.0.0.1:19381/v1',
          model: 'waveform-dev',
        );
        final dio = Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 15),
          ),
        );
        addTearDown(() => dio.close(force: true));
        final api = ObservedSoundcloudApi(dio, ClientIdResolver(dio));
        final transport = HttpAiClient();
        addTearDown(transport.close);
        final client = ObservedAiClient(transport);
        final service = RecommendationService(api: api, client: client);
        late final List<Recommendation> result;
        try {
          result = await service.generate(
            config: config,
            consent: AiConsent(
              destination: config.destination,
              listening: false,
            ),
            apiKey: '',
            mood: mood,
            useListening: false,
            cancelToken: CancelToken(),
          );
        } on AiFailure catch (failure) {
          fail('live recommendation flow: ${failure.message}');
        }
        expect(client.stages, hasLength(2));
        expect(api.searchCalls, inInclusiveRange(1, 2));
        expect(
          client.stages.every((stage) => (stage['seeds'] as List).isEmpty),
          isTrue,
        );
        final candidates = client.stages.last['candidates'] as List;
        expect(candidates.length, inInclusiveRange(1, 40));
        for (final candidate in candidates) {
          expect(
            (candidate as Map).keys,
            unorderedEquals(['id', 'title', 'artist', 'genre']),
          );
        }
        final allowed = {for (final candidate in candidates) candidate['id']};
        expect(result.length, inInclusiveRange(1, 10));
        expect(
          result.map((item) => item.track.id).toSet().length,
          result.length,
        );
        for (final item in result) {
          expect(allowed, contains(item.track.id));
          expect(item.track, same(api.returned[item.track.id]));
          expect(item.track.blocked, isFalse);
          expect(item.track.streamCandidates, isNotEmpty);
          final permalink = Uri.parse(item.track.permalinkUrl ?? '');
          expect(permalink.scheme, 'https');
          expect(permalink.host, 'soundcloud.com');
          expect(permalink.hasQuery, isFalse);
          expect(item.reason, isNotEmpty);
        }
        // Only real public track IDs, titles and public permalinks are emitted.
        stdout.writeln(
          jsonEncode([
            for (final item in result)
              {
                'id': item.track.id,
                'title': item.track.title,
                'permalink': item.track.permalinkUrl,
              },
          ]),
        );
      },
      timeout: const Timeout(Duration(seconds: 210)),
    );
  }
}
