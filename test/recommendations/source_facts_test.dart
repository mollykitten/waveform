import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/api/liked_tracks.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/audio/audio_engine.dart';
import 'package:waveform_app/core/recommendations/listening_event.dart';
import 'package:waveform_app/core/recommendations/listening_providers.dart';
import 'package:waveform_app/core/recommendations/listening_store.dart';
import 'package:waveform_app/core/recommendations/listening_tracker.dart';
import 'package:waveform_app/core/recommendations/models.dart';
import 'package:waveform_app/core/recommendations/providers.dart';
import 'package:waveform_app/features/stats/wave_source_summary.dart';
import 'package:waveform_app/core/recommendations/wave_sources.dart';
import 'package:waveform_app/features/player/player_controller.dart';

import '../support/fake_audio_engine.dart';
import '../support/stub_liked_tracks.dart';
import 'support.dart';

ListeningEvent event({WaveSource? source}) => ListeningEvent(
  sessionId: 'abc',
  identity: '42',
  trackId: 't1',
  durationMs: 100000,
  heardMs: 90000,
  finalPositionMs: 90000,
  seekCount: 0,
  startedAt: DateTime.utc(2026, 10, 27),
  endedAt: DateTime.utc(2026, 10, 27, 0, 2),
  cause: ListeningTransitionCause.naturalCompletion,
  source: source,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ListeningEvent source', () {
    test('every source survives a json round trip', () {
      for (final source in WaveSource.values) {
        final back = ListeningEvent.fromJson(
          jsonDecode(jsonEncode(event(source: source).toJson()))
              as Map<String, dynamic>,
        );
        expect(back.source, source);
      }
    });

    test('no source writes no key, and old facts read as null', () {
      final json = event().toJson();
      expect(json.containsKey('source'), isFalse);
      expect(ListeningEvent.fromJson(json).source, isNull);
    });

    test('an unknown source name from a newer build reads as null', () {
      final json = {...event().toJson(), 'source': 'teleport'};
      final read = ListeningEvent.fromJson(json);
      expect(read.source, isNull);
      expect(read.evidence, ListeningEvidence.positive);
    });

    test('the store keeps old and new rows side by side', () async {
      final directory = await Directory.systemTemp.createTemp('waveform-src-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final old = {...event().toJson(), 'session_id': 'old'};
      File('${directory.path}/${ListeningStore.fileName}').writeAsStringSync(
        jsonEncode({
          'version': 1,
          'events': [old],
        }),
      );
      final store = ListeningStore(directory: () async => directory);
      await store.append(event(source: WaveSource.coLikers));
      final rows = await store.read('42');
      expect(rows.map((e) => e.source), [null, WaveSource.coLikers]);
    });
  });

  test('the tracker stamps the source on the finished fact', () {
    final events = <ListeningEvent>[];
    var now = 0;
    final tracker = ListeningTracker(
      onEvent: events.add,
      monotonicMs: () => now,
    )..setIdentity('42');
    tracker.start(trackId: 't1', durationMs: 100000, source: WaveSource.stream);
    tracker.finish(ListeningTransitionCause.manualNext);
    tracker.start(trackId: 't2', durationMs: 100000);
    tracker.finish(ListeningTransitionCause.manualNext);
    expect(events.map((e) => e.source), [WaveSource.stream, null]);
  });

  test('an identity change keeps the running session source', () {
    final events = <ListeningEvent>[];
    final tracker = ListeningTracker(onEvent: events.add)..setIdentity('42');
    tracker.start(
      trackId: 't1',
      durationMs: 100000,
      source: WaveSource.coLikers,
    );
    tracker.setIdentity('43');
    tracker.finish(ListeningTransitionCause.manualNext);
    expect(events.map((e) => (e.identity, e.source)), [
      ('42', WaveSource.coLikers),
      ('43', WaveSource.coLikers),
    ]);
  });

  test(
    'the player stamps wave tracks with their source, others with none',
    () async {
      final events = <ListeningEvent>[];
      final tracker = ListeningTracker(onEvent: events.add)..setIdentity('42');
      final container = ProviderContainer(
        overrides: [
          audioEngineProvider.overrideWithValue(FakeAudioEngine()),
          likedTracksProvider.overrideWith(StubLikedTracks.new),
          soundcloudApiProvider.overrideWithValue(TestSoundcloud()),
          listeningTrackerProvider.overrideWithValue(tracker),
        ],
      );
      addTearDown(container.dispose);
      final first = realTrack('1');
      final second = realTrack('2');
      final third = realTrack('3');
      container.read(waveSourcesProvider.notifier).add({
        '1': WaveSource.related,
        '2': WaveSource.coLikers,
      }, startsQueue: true);
      final player = container.read(playerControllerProvider.notifier);
      player.play(first, queue: [first, second, third]);
      player.next();
      player.next();
      tracker.finish(ListeningTransitionCause.stopped);
      expect(events.map((e) => (e.trackId, e.source)), [
        ('1', WaveSource.related),
        ('2', WaveSource.coLikers),
        ('3', null),
      ]);
    },
  );

  test('a track picked elsewhere does not inherit its old source', () async {
    final events = <ListeningEvent>[];
    final tracker = ListeningTracker(onEvent: events.add)..setIdentity('42');
    final container = ProviderContainer(
      overrides: [
        audioEngineProvider.overrideWithValue(FakeAudioEngine()),
        likedTracksProvider.overrideWith(StubLikedTracks.new),
        soundcloudApiProvider.overrideWithValue(TestSoundcloud()),
        listeningTrackerProvider.overrideWithValue(tracker),
      ],
    );
    addTearDown(container.dispose);
    final first = realTrack('1');
    final second = realTrack('2');
    container.read(waveSourcesProvider.notifier).add({
      '1': WaveSource.stream,
      '2': WaveSource.coLikers,
    }, startsQueue: true);
    final player = container.read(playerControllerProvider.notifier);
    player.play(first, queue: [first, second]);
    // the user now plays the same track from a search result
    player.play(second);
    tracker.finish(ListeningTransitionCause.stopped);
    expect(events.map((e) => (e.trackId, e.source)), [
      ('1', WaveSource.stream),
      ('2', null),
    ]);
    expect(container.read(waveSourcesProvider), isEmpty);
  });

  test('clearing the wave sources detaches later plays', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final sources = container.read(waveSourcesProvider.notifier)
      ..add({'1': WaveSource.stream});
    expect(container.read(waveSourcesProvider), {'1': WaveSource.stream});
    sources.clear();
    expect(container.read(waveSourcesProvider), isEmpty);
  });

  test('the stats summary counts listens and skips per source', () async {
    final directory = await Directory.systemTemp.createTemp('waveform-sum-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final store = ListeningStore(directory: () async => directory);
    ListeningEvent fact(
      String session,
      WaveSource? source, {
      int heard = 90000,
      ListeningTransitionCause cause =
          ListeningTransitionCause.naturalCompletion,
    }) => ListeningEvent(
      sessionId: session,
      identity: '42',
      trackId: 't$session',
      durationMs: 100000,
      heardMs: heard,
      finalPositionMs: heard,
      seekCount: 0,
      startedAt: DateTime.utc(2026, 10, 27),
      endedAt: DateTime.utc(2026, 10, 27, 0, 2),
      cause: cause,
      source: source,
    );
    await store.append(fact('a', WaveSource.related));
    await store.append(fact('b', WaveSource.related));
    await store.append(
      fact(
        'c',
        WaveSource.coLikers,
        heard: 10000,
        cause: ListeningTransitionCause.manualNext,
      ),
    );
    await store.append(fact('d', null));
    final container = ProviderContainer(
      overrides: [
        listeningIdentityProvider.overrideWith((ref) async => '42'),
        listeningStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);
    final empty = await container.read(waveSourceSummaryProvider.future);
    expect(empty, isNotEmpty);
    await store.append(fact('e', WaveSource.stream));
    // closing and reopening the stats screen rereads the facts
    await Future<void>.delayed(Duration.zero);
    final tally = await container.read(waveSourceSummaryProvider.future);
    expect(tally[WaveSource.stream], (listened: 1, skipped: 0));
    expect(tally, {
      WaveSource.related: (listened: 2, skipped: 0),
      WaveSource.coLikers: (listened: 0, skipped: 1),
      WaveSource.stream: (listened: 1, skipped: 0),
    });
  });
}
