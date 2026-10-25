import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'models.dart';

enum AiBackend { openAi, ollama }

/// Public configuration only. API keys deliberately have no representation here.
class AiConfig {
  const AiConfig({
    this.backend = AiBackend.openAi,
    this.endpoint = '',
    this.model = '',
    this.listeningConsent = false,
  });

  final AiBackend backend;
  final String endpoint;
  final String model;
  final bool listeningConsent;

  Uri get requestUri {
    final uri = Uri.tryParse(endpoint.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        endpoint.length > 500 ||
        !const ['https', 'http'].contains(uri.scheme)) {
      throw AiFailure.configuration;
    }
    final loopback =
        uri.host == 'localhost' ||
        uri.host == '127.0.0.1' ||
        uri.host == '::1' ||
        uri.host == '[::1]';
    if (uri.scheme != 'https' && !loopback) throw AiFailure.configuration;
    var path = uri.path.replaceAll(RegExp(r'/+$'), '');
    if (backend == AiBackend.openAi) {
      if (path.isEmpty) path = '/v1';
      if (!path.endsWith('/chat/completions')) path += '/chat/completions';
    } else {
      if (path.isEmpty) path = '/api';
      if (!path.endsWith('/chat')) path += '/chat';
    }
    return uri.replace(path: path);
  }

  bool get isValid {
    try {
      requestUri;
      return model.trim().isNotEmpty &&
          model.length <= 120 &&
          !RegExp(r'[\x00-\x1f\x7f]').hasMatch(model);
    } catch (_) {
      return false;
    }
  }

  String get destination => requestUri.toString();

  AiConfig withConsent(bool consent) => AiConfig(
    backend: backend,
    endpoint: endpoint,
    model: model,
    listeningConsent: consent,
  );

  Map<String, Object> toJson() => {
    'backend': backend.name,
    'endpoint': endpoint,
    'model': model,
    'listeningConsent': listeningConsent,
  };

  static AiConfig fromJson(Map<String, dynamic> json) => AiConfig(
    backend: json['backend'] == 'ollama' ? AiBackend.ollama : AiBackend.openAi,
    endpoint: json['endpoint'] is String ? json['endpoint'] as String : '',
    model: json['model'] is String ? json['model'] as String : '',
    listeningConsent: json['listeningConsent'] == true,
  );
}

/// Independent JSON file, serialized writes, and no persisted API key.
class AiConfigStore {
  AiConfigStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;
  Future<void> _tail = Future.value();

  Future<File> _file() async =>
      File('${(await _directory()).path}/ai_config.json');

  Future<AiConfig> load() async {
    await _tail;
    final file = await _file();
    if (!await file.exists()) return const AiConfig();
    if (await file.length() > 4096) throw AiFailure.configuration;
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is Map<String, dynamic>) return AiConfig.fromJson(json);
    } catch (_) {
      throw AiFailure.configuration;
    }
    throw AiFailure.configuration;
  }

  Future<void> save(AiConfig config) {
    final operation = _tail.then((_) async {
      final file = await _file();
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(config.toJson()), flush: true);
      await temporary.rename(file.path);
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }
}
