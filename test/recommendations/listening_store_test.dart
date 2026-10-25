import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/recommendations/listening_event.dart';
import 'package:waveform_app/core/recommendations/listening_store.dart';

ListeningEvent event(int id, {String identity = '123'}) => ListeningEvent(
  sessionId: 'session-$id',
  identity: identity,
  trackId: '$id',
  durationMs: 100000,
  heardMs: 6000,
  finalPositionMs: 6000,
  seekCount: 0,
  startedAt: DateTime.utc(2026),
  endedAt: DateTime.utc(2026),
  cause: ListeningTransitionCause.manualNext,
);

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('listening');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  test('failed temporary write preserves previous complete file', () async {
    final failures = <String>[];
    final store = ListeningStore(
      directory: () async => directory,
      onFailure: failures.add,
    );
    await store.append(event(1));
    final file = File('${directory.path}/${ListeningStore.fileName}');
    final original = await file.readAsString();
    await Directory('${file.path}.tmp').create();
    await store.append(event(2));
    expect(await file.readAsString(), original);
    expect(failures, ['listening storage unavailable']);
    expect((await store.read('123')).single.trackId, '1');
  });
  test(
    'serialized atomic writes preserve events and compact oldest records',
    () async {
      final store = ListeningStore(
        directory: () async => directory,
        maxRecords: 3,
      );
      await Future.wait([for (var i = 1; i <= 10; i++) store.append(event(i))]);
      expect((await store.read('123')).map((e) => e.trackId), ['8', '9', '10']);
      final json = jsonDecode(
        await File(
          '${directory.path}/${ListeningStore.fileName}',
        ).readAsString(),
      );
      expect(json['version'], 1);
      expect(json['events'], hasLength(3));
      expect(
        await File('${directory.path}/${ListeningStore.fileName}.tmp').exists(),
        false,
      );
    },
  );
  test(
    'read partitions cannot see another account or anonymous records',
    () async {
      final store = ListeningStore(directory: () async => directory);
      await store.append(event(1));
      await store.append(event(2, identity: '456'));
      await store.append(event(3, identity: 'anonymous'));
      expect((await store.read('123')).single.trackId, '1');
      expect((await store.read('456')).single.trackId, '2');
      expect((await store.read('anonymous')).single.trackId, '3');
      expect(await store.read('token-secret'), isEmpty);
    },
  );
  test(
    'corrupt, oversized and unsupported files fail safely and recover',
    () async {
      final failures = <String>[];
      final store = ListeningStore(
        directory: () async => directory,
        maxBytes: 1024,
        onFailure: failures.add,
      );
      final file = File('${directory.path}/${ListeningStore.fileName}');
      await file.writeAsString('{broken');
      expect(await store.read('123'), isEmpty);
      await file.writeAsString('x' * 1025);
      expect(await store.read('123'), isEmpty);
      await file.writeAsString('{"version":999,"events":[]}');
      expect(await store.read('123'), isEmpty);
      await store.append(event(1));
      expect((await store.read('123')).single.trackId, '1');
      expect(failures, everyElement('listening storage unavailable'));
    },
  );
  test(
    'invalid secret-like identifiers and payloads are never written',
    () async {
      final store = ListeningStore(directory: () async => directory);
      await store.append(event(1, identity: 'oauth-secret'));
      expect(
        await File('${directory.path}/${ListeningStore.fileName}').exists(),
        false,
      );
    },
  );
}
