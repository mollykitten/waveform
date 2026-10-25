import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/recommendations/ai_config.dart';

void main() {
  test('endpoint policy allows HTTPS and exact loopback HTTP only', () {
    for (final endpoint in [
      'https://model.example/v1',
      'http://localhost:11434',
      'http://127.0.0.1:8080/v1',
      'http://[::1]:8080',
    ]) {
      expect(AiConfig(endpoint: endpoint, model: 'm').isValid, isTrue);
    }
    for (final endpoint in [
      'http://model.example',
      'http://localhost.evil.invalid',
      'https://key@model.example/v1',
      'https://model.example?key=secret',
      'https://model.example/#secret',
      'file:///tmp/model',
      '',
    ]) {
      expect(AiConfig(endpoint: endpoint, model: 'm').isValid, isFalse);
    }
    expect(
      const AiConfig(
        endpoint: 'https://example.com/v1',
        model: 'm',
      ).destination,
      'https://example.com/v1/chat/completions',
    );
    expect(
      const AiConfig(
        backend: AiBackend.ollama,
        endpoint: 'http://localhost:11434',
        model: 'm',
      ).destination,
      'http://localhost:11434/api/chat',
    );
  });

  test(
    'serialized atomic config writes persist only approved public fields',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'waveform-ai-test',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = AiConfigStore(directory: () async => directory);
      await Future.wait(
        List.generate(
          20,
          (i) => store.save(
            AiConfig(
              endpoint: 'https://model.example/v1',
              model: 'model$i',
              listeningConsent: true,
            ),
          ),
        ),
      );
      expect((await store.load()).model, 'model19');
      final json = jsonDecode(
        await File('${directory.path}/ai_config.json').readAsString(),
      );
      expect(
        json.keys,
        unorderedEquals([
          'backend',
          'endpoint',
          'model',
          'listeningConsent',
          'consentBinding',
        ]),
      );
      expect(
        await File('${directory.path}/ai_config.json.tmp').exists(),
        isFalse,
      );
    },
  );
}
