import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/api/soundcloud_auth.dart';
import 'package:waveform_app/core/log/talker.dart';
import 'package:waveform_app/core/recommendations/co_likers_job.dart';
import 'package:waveform_app/core/recommendations/co_likers_source.dart';
import 'package:waveform_app/core/recommendations/co_likers_store.dart';
import 'package:waveform_app/core/recommendations/providers.dart';
import 'package:talker_flutter/talker_flutter.dart';

import 'co_likers_test.dart' show CfApi, like;
import 'support.dart';

/// Records every refresh and holds it open until released.
class _HeldSource extends CoLikersSource {
  _HeldSource(TestSoundcloud api, CoLikersStore store)
    : super(api: api, store: store);
  final calls = <String>[];
  final cancelledAtEnd = <bool>[];
  Completer<void>? hold;

  @override
  Future<bool> refresh(
    String identity, {
    required bool Function() isCancelled,
  }) async {
    calls.add(identity);
    await hold?.future;
    cancelledAtEnd.add(isCancelled());
    return false;
  }
}

void main() {
  late Directory directory;
  late CoLikersStore store;
  var token = 'token-a';
  String? signedIn() => token.isEmpty ? null : token;

  ProviderContainer containerFor(CoLikersSource source) {
    final container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWithBuild(
          (ref, notifier) =>
              SoundcloudAuth(clientId: 'test', userToken: signedIn()),
        ),
        listeningIdentityProvider.overrideWith((ref) async {
          final auth = ref.watch(authControllerProvider);
          return auth.userToken == 'token-a'
              ? '42'
              : auth.userToken == null
              ? 'anonymous'
              : '43';
        }),
        coLikersSourceProvider.overrideWithValue(source),
        coLikersStoreProvider.overrideWithValue(store),
        talkerProvider.overrideWithValue(Talker()),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  void changeAccount(ProviderContainer container, String next) {
    token = next;
    container.invalidate(authControllerProvider);
    container.read(authControllerProvider);
  }

  setUp(() async {
    token = 'token-a';
    directory = await Directory.systemTemp.createTemp('waveform-job-');
    store = CoLikersStore(directory: () async => directory);
  });
  tearDown(() async => directory.delete(recursive: true));

  test('entering and opening the wave at once start a single run', () async {
    final source = _HeldSource(TestSoundcloud(), store)
      ..hold = Completer<void>();
    final job = containerFor(source).read(coLikersJobProvider);
    job
      ..start()
      ..start();
    await pumpEventQueue();
    expect(source.calls, ['42']);
    source.hold!.complete();
    await pumpEventQueue();
    job.start();
    await pumpEventQueue();
    expect(source.calls, ['42', '42']);
  });

  test('start works again after a cancel', () async {
    final source = _HeldSource(TestSoundcloud(), store)
      ..hold = Completer<void>();
    final job = containerFor(source).read(coLikersJobProvider);
    job.start();
    await pumpEventQueue();
    job.cancel();
    job.start();
    await pumpEventQueue();
    expect(source.calls, ['42', '42']);
    source.hold!.complete();
    await pumpEventQueue();
    // the first run saw the cancel, the second is still current
    expect(source.cancelledAtEnd, [true, false]);
  });

  test('an account change cancels the run and starts the next one', () async {
    final source = _HeldSource(TestSoundcloud(), store)
      ..hold = Completer<void>();
    final container = containerFor(source);
    container.read(coLikersJobProvider).start();
    await pumpEventQueue();
    changeAccount(container, 'token-b');
    await pumpEventQueue();
    expect(source.calls, ['42', '43']);
    source.hold!.complete();
    await pumpEventQueue();
    expect(source.cancelledAtEnd, [true, false]);
  });

  test('signing out cancels the run and starts nothing', () async {
    final source = _HeldSource(TestSoundcloud(), store)
      ..hold = Completer<void>();
    final container = containerFor(source);
    final job = container.read(coLikersJobProvider);
    job.start();
    await pumpEventQueue();
    changeAccount(container, '');
    await pumpEventQueue();
    job.start();
    await pumpEventQueue();
    source.hold!.complete();
    await pumpEventQueue();
    expect(source.calls, ['42']);
    expect(source.cancelledAtEnd, [true]);
  });

  test('a signed-out visitor never starts a run', () async {
    token = '';
    final source = _HeldSource(TestSoundcloud(), store);
    containerFor(source).read(coLikersJobProvider).start();
    await pumpEventQueue();
    expect(source.calls, isEmpty);
  });

  test('a real run cut off by an account change leaves no file', () async {
    final api = CfApi()
      ..likers['s0'] = ['900001', '900002']
      ..likers['s1'] = ['900001', '900002']
      ..likes['900001'] = [like('x', 1)]
      ..likes['900002'] = [like('x', 2)];
    final gate = api.gateLikes = Completer<void>();
    final source = CoLikersSource(
      api: api,
      store: store,
      pause: Duration.zero,
      backoff: Duration.zero,
    );
    final container = containerFor(source);
    container.read(coLikersJobProvider).start();
    await pumpEventQueue();
    changeAccount(container, 'token-b');
    gate.complete();
    await pumpEventQueue(times: 400);
    expect(File('${directory.path}/co-likers-v1-42.json').existsSync(), false);
  });
}
