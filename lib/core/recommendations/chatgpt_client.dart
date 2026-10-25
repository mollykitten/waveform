import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'ai_client.dart';
import 'ai_config.dart';
import 'chatgpt_auth.dart';
import 'models.dart';

/// Subscription inference uses the public Responses API, never chat completions
/// or private ChatGPT endpoints. Model order comes from the active account.
class ChatGptAiClient implements AiClient {
  ChatGptAiClient({required this.auth, Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options = BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 60),
      followRedirects: false,
      maxRedirects: 0,
      validateStatus: (_) => true,
    );
  }
  final ChatGptAuth auth;
  final Dio _dio;
  void close() => _dio.close(force: true);
  @override
  Future<String> complete({
    required AiConfig config,
    required AiConsent consent,
    required String apiKey,
    required String system,
    required String data,
    required CancelToken cancelToken,
  }) async {
    if (config.backend != AiBackend.chatGpt ||
        consent.destination != config.destination) {
      throw AiFailure.configuration;
    }
    if (cancelToken.isCancelled) throw AiFailure.cancelled;
    final accountBinding = auth.account?.binding;
    var expired = false;
    final deadline = Timer(const Duration(seconds: 75), () {
      expired = true;
      cancelToken.cancel();
    });
    try {
      final token = await auth.accessToken();
      if (cancelToken.isCancelled || auth.account?.binding != accountBinding) {
        throw AiFailure.cancelled;
      }
      final models = await _dio.get<String>(
        'https://api.openai.com/v1/models',
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.plain,
          headers: {'Authorization': 'Bearer $token'},
        ),
      );
      _status(models.statusCode);
      if ((models.data?.length ?? 0) > 256 * 1024) throw AiFailure.malformed;
      final catalog = jsonDecode(models.data!)['models'];
      if (catalog is! List) throw AiFailure.malformed;
      final available = catalog.whereType<Map>().where(
        (model) =>
            model['visibility'] == 'list' &&
            model['slug'] is String &&
            (model['slug'] as String).isNotEmpty,
      );
      if (available.isEmpty) throw AiFailure.permission;
      final body = {
        'model': available.first['slug'],
        'instructions': system,
        'input': [
          {'role': 'user', 'content': data},
        ],
        'store': false,
        'stream': true,
      };
      if (utf8.encode(jsonEncode(body)).length > 32768) {
        throw AiFailure.configuration;
      }
      final response = await _dio.post<ResponseBody>(
        'https://api.openai.com/v1/responses',
        data: body,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
            'Accept': 'text/event-stream',
          },
        ),
      );
      if (response.statusCode != 200) {
        await response.data?.stream.listen((_) {}).cancel();
        _status(response.statusCode);
      }
      final stream = response.data;
      if (stream == null) throw AiFailure.malformed;
      return await parseChatGptEvents(stream.stream, cancelToken).then((value) {
        if (auth.account?.binding != accountBinding) throw AiFailure.cancelled;
        return value;
      });
    } on AiFailure {
      if (expired) throw AiFailure.timeout;
      rethrow;
    } on DioException catch (error) {
      if (expired) throw AiFailure.timeout;
      if (CancelToken.isCancel(error)) throw AiFailure.cancelled;
      throw AiFailure.network;
    } catch (_) {
      throw AiFailure.malformed;
    } finally {
      deadline.cancel();
    }
  }

  void _status(int? status) {
    if (status == 200) return;
    if (status == 401 || status == 403) throw AiFailure.credentials;
    if (status == 429) throw AiFailure.rateLimit;
    throw AiFailure.network;
  }
}

/// Wait for the terminal event even after complete-looking text. A subscription
/// usage failure may arrive after deltas, and must never yield recommendations.
Future<String> parseChatGptEvents(
  Stream<List<int>> stream,
  CancelToken cancelToken,
) async {
  final iterator = StreamIterator(
    stream
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter()),
  );
  final output = StringBuffer();
  final eventData = <String>[];
  var total = 0, textBytes = 0;
  var completed = false;
  void event() {
    if (eventData.isEmpty) return;
    final raw = eventData.join('\n');
    eventData.clear();
    if (raw == '[DONE]') return;
    final value = jsonDecode(raw);
    if (value is! Map) throw AiFailure.malformed;
    final type = value['type'];
    if (type == 'response.output_text.delta') {
      if (completed || value['delta'] is! String) throw AiFailure.malformed;
      final delta = value['delta'] as String;
      textBytes += utf8.encode(delta).length;
      if (textBytes > 16384) throw AiFailure.malformed;
      output.write(delta);
    } else if (type == 'response.completed') {
      if (completed) throw AiFailure.malformed;
      completed = true;
    } else if (type == 'response.failed' ||
        type == 'response.incomplete' ||
        type == 'error') {
      final response = value['response'];
      final error = response is Map ? response['error'] : value['error'];
      final code = error is Map ? error['code'] : value['code'];
      if (code == 'subscription_sharing_usage_limit_exceeded' ||
          code == 'rate_limit_exceeded') {
        throw AiFailure.rateLimit;
      }
      if (code == 'subscription_sharing_usage_unavailable') {
        throw AiFailure.permission;
      }
      throw AiFailure.malformed;
    }
  }

  final cancellation = cancelToken.whenCancel.then<bool>(
    (_) => throw AiFailure.cancelled,
  );
  try {
    while (await Future.any([iterator.moveNext(), cancellation])) {
      if (cancelToken.isCancelled) throw AiFailure.cancelled;
      final line = iterator.current;
      total += utf8.encode(line).length;
      if (total > 256 * 1024) throw AiFailure.malformed;
      if (line.isEmpty) {
        event();
      } else if (line.startsWith('data:')) {
        eventData.add(line.substring(5).trimLeft());
      }
    }
    event();
    if (!completed || output.isEmpty || cancelToken.isCancelled) {
      throw AiFailure.malformed;
    }
    return output.toString();
  } finally {
    await iterator.cancel();
  }
}

class RoutedAiClient implements AiClient {
  const RoutedAiClient(this.custom, this.chatGpt);
  final AiClient custom, chatGpt;
  @override
  Future<String> complete({
    required AiConfig config,
    required AiConsent consent,
    required String apiKey,
    required String system,
    required String data,
    required CancelToken cancelToken,
  }) => (config.backend == AiBackend.chatGpt ? chatGpt : custom).complete(
    config: config,
    consent: consent,
    apiKey: apiKey,
    system: system,
    data: data,
    cancelToken: cancelToken,
  );
}
