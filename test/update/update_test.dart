import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/update/app_version.dart';
import 'package:waveform_app/core/update/update_backend.dart';
import 'package:waveform_app/core/update/update_controller.dart';

class _Fixed implements HttpClientAdapter {
  _Fixed(this.body, {this.status = 200});
  final String body;
  final int status;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    body,
    status,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );
}

Dio _dio(String body, {int status = 200}) =>
    Dio()..httpClientAdapter = _Fixed(body, status: status);

void main() {
  test('kAppVersion matches pubspec.yaml', () {
    final line = File(
      'pubspec.yaml',
    ).readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
    expect(line.split(RegExp(r'[\s+]'))[1], kAppVersion);
  });

  test('version comparison', () {
    expect(isNewerVersion('v0.4.1', '0.4.0'), isTrue);
    expect(isNewerVersion('v0.10.0', '0.9.9'), isTrue);
    expect(isNewerVersion('v0.4.0', '0.4.0'), isFalse);
    expect(isNewerVersion('v0.3.9', '0.4.0'), isFalse);
    expect(isNewerVersion('garbage', '0.4.0'), isFalse);
  });

  test('github backend reports a newer release', () async {
    final b = GithubUpdateBackend(dio: _dio('{"tag_name":"v0.5.0"}'));
    expect(await b.checkNow(), UpdateOutcome.available);
    expect(b.availableVersion, '0.5.0');
  });

  test('github backend: same version is up to date', () async {
    final b = GithubUpdateBackend(dio: _dio('{"tag_name":"v0.4.0"}'));
    expect(await b.checkNow(), UpdateOutcome.upToDate);
    expect(b.availableVersion, isNull);
  });

  test('github backend: network failure is unknown, not a crash', () async {
    final b = GithubUpdateBackend(dio: _dio('{}', status: 500));
    expect(await b.checkNow(), UpdateOutcome.unknown);
  });

  test('without an appimage the release page opens', () async {
    String? opened;
    final b = GithubUpdateBackend(
      dio: _dio('{"tag_name":"v0.5.0"}'),
      environment: const {},
      open: (u) async => opened = u,
    );
    expect(await b.installAvailable(), isFalse);
    expect(opened, kReleasesPageUrl);
  });

  test('controller is a no-op under flutter test', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(updateBackendProvider), isA<NoopUpdateBackend>());
    await c.read(updateControllerProvider.notifier).autoCheck();
    expect(c.read(updateControllerProvider).lastCheck, isNull);
  });
}
