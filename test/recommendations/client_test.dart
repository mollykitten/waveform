import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/recommendations/ai_client.dart';
import 'package:waveform_app/core/recommendations/ai_config.dart';
import 'package:waveform_app/core/recommendations/models.dart';

import 'support.dart';

class RecordingAdapter implements HttpClientAdapter {
  RequestOptions? request;
  int status = 200;
  String body =
      '{"choices":[{"message":{"content":"{\\"queries\\":[\\"ambient\\"]}"}}]}';
  bool fail = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    if (fail) throw StateError('SECRET RESPONSE WITH SESSION_SECRET');
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class StreamingAdapter implements HttpClientAdapter {
  final listening = Completer<void>();
  late final stream = StreamController<Uint8List>(
    onListen: () => listening.complete(),
  );
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) async => ResponseBody(stream.stream, 200);
  @override
  void close({bool force = false}) {
    stream.close();
  }
}

void main() {
  late RecordingAdapter adapter;
  late HttpAiClient client;
  setUp(() {
    adapter = RecordingAdapter();
    client = HttpAiClient(dio: Dio()..httpClientAdapter = adapter);
  });
  tearDown(() => client.close());

  Future<String> call({AiConfig config = testConfig, CancelToken? token}) =>
      client.complete(
        config: config,
        consent: AiConsent(destination: config.destination, listening: false),
        apiKey: 'SESSION_SECRET',
        system: 'system',
        data: '{"mood":"night"}',
        cancelToken: token ?? CancelToken(),
      );

  test(
    'OpenAI request schema and response, auth never forwarded via redirect',
    () async {
      expect(await call(), '{"queries":["ambient"]}');
      final request = adapter.request!;
      expect(request.uri.path, '/v1/chat/completions');
      expect(request.followRedirects, isFalse);
      expect(request.maxRedirects, 0);
      expect(request.headers['Authorization'], 'Bearer SESSION_SECRET');
      final data = request.data as Map;
      expect(data['stream'], isFalse);
      expect(data['response_format'], {'type': 'json_object'});
      expect(data.toString(), isNot(contains('SESSION_SECRET')));
    },
  );

  test('native Ollama schema and response', () async {
    adapter.body = '{"message":{"content":"{\\"queries\\":[\\"ambient\\"]}"}}';
    expect(
      await call(
        config: const AiConfig(
          backend: AiBackend.ollama,
          endpoint: 'http://localhost:11434',
          model: 'local',
        ),
      ),
      contains('ambient'),
    );
    expect(adapter.request!.uri.path, '/api/chat');
    expect(adapter.request!.data['format'], 'json');
    expect(adapter.request!.data['options']['num_predict'], 1600);
    expect(adapter.request!.data.containsKey('response_format'), isFalse);
  });

  test(
    'llama.cpp no-thinking JSON content uses the exact dev alias without auth',
    () async {
      const config = AiConfig(
        endpoint: 'http://127.0.0.1:19381/v1',
        model: 'waveform-dev',
      );
      final content = await client.complete(
        config: config,
        consent: AiConsent(destination: config.destination, listening: false),
        apiKey: '',
        system: 'JSON only',
        data: '{"mood":"ambient"}',
        cancelToken: CancelToken(),
      );
      expect(parseSearchPlan(content), ['ambient']);
      expect(
        adapter.request!.uri.toString(),
        'http://127.0.0.1:19381/v1/chat/completions',
      );
      expect(adapter.request!.data['model'], 'waveform-dev');
      expect(adapter.request!.headers.containsKey('Authorization'), isFalse);
    },
  );

  test('401/403/429 and redirects expose only typed safe errors', () async {
    for (final (code, expected) in [
      (401, AiFailure.credentials),
      (403, AiFailure.credentials),
      (429, AiFailure.rateLimit),
      (302, AiFailure.network),
    ]) {
      adapter.status = code;
      adapter.body = 'SESSION_SECRET';
      await expectLater(call(), throwsA(expected));
      expect(expected.toString(), isNot(contains('SESSION_SECRET')));
    }
  });

  test('malformed, oversized and private error bodies never escape', () async {
    for (final body in [
      'SECRET',
      '{}',
      '{"choices":[]}',
      'x' * (HttpAiClient.maxResponseBytes + 1),
    ]) {
      adapter.body = body;
      await expectLater(call(), throwsA(AiFailure.malformed));
    }
    adapter.fail = true;
    await expectLater(call(), throwsA(AiFailure.network));
  });

  test('cancel before sending performs no transport request', () async {
    await expectLater(
      call(token: CancelToken()..cancel()),
      throwsA(AiFailure.cancelled),
    );
    expect(adapter.request, isNull);
  });

  test('cancel after response headers interrupts a stalled body', () async {
    client.close();
    final streaming = StreamingAdapter();
    client = HttpAiClient(dio: Dio()..httpClientAdapter = streaming);
    final token = CancelToken();
    final result = call(token: token);
    await streaming.listening.future;
    token.cancel();
    await expectLater(
      result.timeout(const Duration(seconds: 2)),
      throwsA(AiFailure.cancelled),
    );
  });

  test(
    'absolute deadline stops a body even while chunks keep arriving',
    () async {
      client.close();
      final streaming = StreamingAdapter();
      client = HttpAiClient(
        dio: Dio()..httpClientAdapter = streaming,
        requestTimeout: const Duration(milliseconds: 150),
      );
      final result = call();
      await streaming.listening.future;
      final chunks = Timer.periodic(const Duration(milliseconds: 20), (_) {
        streaming.stream.add(Uint8List.fromList([32]));
      });
      try {
        await expectLater(
          result.timeout(const Duration(seconds: 2)),
          throwsA(AiFailure.timeout),
        );
      } finally {
        chunks.cancel();
      }
    },
  );
}
