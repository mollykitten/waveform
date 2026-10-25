import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'ai_config.dart';
import 'models.dart';

/// A destination-bound authorization snapshot covers both stages of a batch.
class AiConsent {
  const AiConsent({required this.destination, required this.listening});
  final String destination;
  final bool listening;
}

abstract interface class AiClient {
  Future<String> complete({
    required AiConfig config,
    required AiConsent consent,
    required String apiKey,
    required String system,
    required String data,
    required CancelToken cancelToken,
  });
}

/// Isolated transport: no SoundCloud interceptors, redirects or raw exceptions.
class HttpAiClient implements AiClient {
  HttpAiClient({
    Dio? dio,
    Duration requestTimeout = const Duration(seconds: 75),
  }) : _dio = dio ?? Dio(),
       _requestTimeout = requestTimeout {
    _dio.options.connectTimeout = const Duration(seconds: 10);
  }
  final Dio _dio;
  final Duration _requestTimeout;
  static const maxResponseBytes = 256 * 1024;

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
    if (config.backend == AiBackend.chatGpt ||
        !config.isValid ||
        consent.destination != config.destination ||
        apiKey.length > 4096 ||
        RegExp(r'[\r\n]').hasMatch(apiKey)) {
      throw AiFailure.configuration;
    }
    if (cancelToken.isCancelled) throw AiFailure.cancelled;
    final body = <String, dynamic>{
      'model': config.model.trim(),
      'stream': false,
      'messages': [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': data},
      ],
      if (config.backend == AiBackend.openAi) ...{
        'temperature': 0.3,
        'max_tokens': 1600,
        'response_format': {'type': 'json_object'},
      } else ...{
        'format': 'json',
        'options': {'temperature': 0.3, 'num_predict': 1600},
      },
    };
    if (utf8.encode(jsonEncode(body)).length > 32768) {
      throw AiFailure.configuration;
    }
    var expired = false;
    final deadline = Timer(_requestTimeout, () {
      expired = true;
      cancelToken.cancel();
    });
    try {
      final response = await _dio
          .post<ResponseBody>(
            config.destination,
            data: body,
            cancelToken: cancelToken,
            options: Options(
              responseType: ResponseType.stream,
              followRedirects: false,
              maxRedirects: 0,
              sendTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 60),
              headers: {
                'Content-Type': 'application/json',
                if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
              },
              validateStatus: (_) => true,
            ),
          )
          .timeout(
            _requestTimeout,
            onTimeout: () {
              cancelToken.cancel();
              throw AiFailure.timeout;
            },
          );
      final stream = response.data;
      if (stream == null) throw AiFailure.malformed;
      final status = response.statusCode ?? 0;
      if (status != 200) {
        await stream.stream.listen((_) {}).cancel();
        if (status == 401 || status == 403) throw AiFailure.credentials;
        if (status == 429) throw AiFailure.rateLimit;
        throw AiFailure.network;
      }
      final bytes = <int>[];
      final iterator = StreamIterator(
        stream.stream.timeout(const Duration(seconds: 60)),
      );
      final cancellation = cancelToken.whenCancel.then<bool>((_) {
        throw expired ? AiFailure.timeout : AiFailure.cancelled;
      });
      try {
        while (await Future.any([iterator.moveNext(), cancellation])) {
          final chunk = iterator.current;
          if (cancelToken.isCancelled) {
            throw expired ? AiFailure.timeout : AiFailure.cancelled;
          }
          if (bytes.length + chunk.length > maxResponseBytes) {
            throw AiFailure.malformed;
          }
          bytes.addAll(chunk);
        }
      } finally {
        await iterator.cancel();
      }
      if (cancelToken.isCancelled) {
        throw expired ? AiFailure.timeout : AiFailure.cancelled;
      }
      final envelope = jsonDecode(utf8.decode(bytes));
      final dynamic content = config.backend == AiBackend.ollama
          ? envelope['message']['content']
          : envelope['choices'][0]['message']['content'];
      if (content is! String || utf8.encode(content).length > 16384) {
        throw AiFailure.malformed;
      }
      return content;
    } on AiFailure {
      rethrow;
    } on DioException catch (error) {
      if (expired) throw AiFailure.timeout;
      if (CancelToken.isCancel(error)) throw AiFailure.cancelled;
      if (const [
        DioExceptionType.connectionTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.sendTimeout,
      ].contains(error.type)) {
        throw AiFailure.timeout;
      }
      throw AiFailure.network;
    } on TimeoutException {
      throw AiFailure.timeout;
    } on FormatException {
      throw AiFailure.malformed;
    } catch (_) {
      throw AiFailure.malformed;
    } finally {
      deadline.cancel();
    }
  }
}
