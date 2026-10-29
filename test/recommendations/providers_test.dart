import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/api/soundcloud_auth.dart';
import 'package:waveform_app/core/recommendations/listening_store.dart';
import 'package:waveform_app/core/recommendations/listening_store_provider.dart';
import 'package:waveform_app/core/recommendations/models.dart';
import 'package:waveform_app/core/recommendations/providers.dart';
import 'package:waveform_app/core/recommendations/seen_store.dart';
import 'package:waveform_app/core/recommendations/vector_store.dart';
import 'package:waveform_app/shared/models/track.dart';

import 'support.dart';

class GraphApi extends TestSoundcloud {
  Completer<List<Track>>? pending;
  bool failHistory = false;

  @override
  Future<List<Track>> relatedTracks(String id) async =>
      pending?.future ?? [realTrack('rel-$id')];

  @override
  Future<List<Track>> historyPage({int limit = 50, int offset = 0}) {
    if (failHistory) throw StateError('PRIVATE TRANSPORT ERROR');
    return super.historyPage(limit: limit, offset: offset);
  }
}

void main() {
  late Directory directory;
  late ProviderContainer container;
  late GraphApi api;
  var token = 'synthetic-account';
  var identity = '1';
  setUp(() async {
    token = 'synthetic-account';
    identity = '1';
    directory = await Directory.systemTemp.createTemp('waveform-providers');
    api = GraphApi();
    container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWithBuild(
          (ref, notifier) => SoundcloudAuth(clientId: 'test', userToken: token),
        ),
        listeningIdentityProvider.overrideWith((ref) async => identity),
        soundcloudApiProvider.overrideWithValue(api),
        listeningStoreProvider.overrideWithValue(
          ListeningStore(directory: () async => directory),
        ),
        vectorStoreProvider.overrideWithValue(
          VectorStore(directory: () async => directory),
        ),
        seenStoreProvider.overrideWithValue(
          SeenStore(directory: () async => directory),
        ),
      ],
    );
    container.listen(recommendationsProvider, (_, _) {});
  });
  tearDown(() async {
    container.dispose();
    await directory.delete(recursive: true);
  });

  RecommendationsController controller() =>
      container.read(recommendationsProvider.notifier);
  RecommendationState state() => container.read(recommendationsProvider);

  test('generate ranks real graph tracks from the current track', () async {
    await controller().generate(currentTrack: realTrack('seed'));
    expect(state().error, isNull);
    expect(state().items, isNotEmpty);
  });

  test('an anonymous account never generates', () async {
    identity = 'anonymous';
    await controller().generate(currentTrack: realTrack('seed'));
    expect(state().error, WaveFailure.signIn);
    expect(state().items, isEmpty);
  });

  test('account change discards a pending generation', () async {
    final pending = api.pending = Completer<List<Track>>();
    final generation = controller().generate(currentTrack: realTrack('seed'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    token = 'another-account';
    container.invalidate(authControllerProvider);
    container.read(authControllerProvider);
    await Future<void>.delayed(Duration.zero);
    pending.complete([realTrack('late')]);
    await generation;
    expect(state().busy, isFalse);
    expect(state().items, isEmpty);
  });

  test(
    'refresh keeps success and cancellation discards late results',
    () async {
      await controller().generate(currentTrack: realTrack('seed'));
      final original = state().items.map((item) => item.track.id).toList();
      expect(original, isNotEmpty);
      final pending = api.pending = Completer<List<Track>>();
      final refresh = controller().generate(currentTrack: realTrack('other'));
      expect(state().busy, isTrue);
      expect(state().items.map((item) => item.track.id), original);
      controller().cancel();
      pending.complete([realTrack('late')]);
      await refresh;
      expect(state().busy, isFalse);
      expect(state().items.map((item) => item.track.id), original);
    },
  );

  test('raw client errors are sanitized in observable state', () async {
    api.failHistory = true;
    await controller().generate(currentTrack: realTrack('seed'));
    expect(state().error, WaveFailure.source);
    expect(state().error.toString(), isNot(contains('PRIVATE')));
  });

  test('retry failure retains the last successful result', () async {
    await controller().generate(currentTrack: realTrack('seed'));
    final original = state().items;
    api.failHistory = true;
    await controller().generate(currentTrack: realTrack('seed'));
    expect(state().items, same(original));
    expect(state().error, WaveFailure.source);
    expect(state().busy, isFalse);
  });
}
