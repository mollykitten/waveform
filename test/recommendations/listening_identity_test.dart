import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/api/mock_soundcloud_api.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/api/soundcloud_api.dart';
import 'package:waveform_app/core/api/soundcloud_auth.dart';
import 'package:waveform_app/core/recommendations/listening_event.dart';
import 'package:waveform_app/core/recommendations/listening_providers.dart';
import 'package:waveform_app/core/recommendations/listening_tracker.dart';
import 'package:waveform_app/core/recommendations/providers.dart';
import 'package:waveform_app/shared/models/artist.dart';
import 'package:waveform_app/shared/models/track.dart';

class TestAuth extends AuthController {
  @override
  SoundcloudAuth build() => const SoundcloudAuth();
  void setToken(String? token) => state = SoundcloudAuth(userToken: token);
}

class RecoverableIdentityApi extends MockSoundcloudApi {
  bool available = false;
  int calls = 0;
  String identity = '123';
  Completer<RailData>? pending;

  @override
  Future<RailData> rail() async {
    calls++;
    if (pending != null) return pending!.future;
    return (
      me: available
          ? Artist(id: identity, handle: 'listener', followers: 0)
          : null,
      likes: <Track>[],
      history: <Track>[],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'startup restore does not attribute a stored account to anonymous',
    () async {
      final stored = Completer<bool>();
      final events = <ListeningEvent>[];
      final tracker = ListeningTracker(onEvent: events.add);
      final container = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWith(TestAuth.new),
          listeningStoredAccountPresentProvider.overrideWith(
            (ref) => stored.future,
          ),
          listeningTrackerProvider.overrideWithValue(tracker),
          aiListeningIdentityProvider.overrideWith((ref) async => '123'),
        ],
      );
      addTearDown(container.dispose);
      container.listen(
        listeningFeedbackProvider,
        (_, _) {},
        fireImmediately: true,
      );
      tracker.start(trackId: '1', durationMs: 100000);
      tracker.finish(ListeningTransitionCause.manualNext);
      expect(events, isEmpty);
      stored.complete(true);
      await pumpEventQueue();
      expect(await container.read(listeningPartitionProvider.future), isNull);
      (container.read(authControllerProvider.notifier) as TestAuth).setToken(
        'a',
      );
      await pumpEventQueue();
      tracker.start(trackId: '2', durationMs: 100000);
      tracker.finish(ListeningTransitionCause.manualNext);
      expect(events.single.identity, '123');
    },
  );

  test(
    'account switch discards unresolved hearing and rejects stale lookup',
    () async {
      final first = Completer<String>();
      final second = Completer<String>();
      final events = <ListeningEvent>[];
      final tracker = ListeningTracker(onEvent: events.add);
      final container = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWith(TestAuth.new),
          listeningStoredAccountPresentProvider.overrideWith(
            (ref) async => true,
          ),
          listeningTrackerProvider.overrideWithValue(tracker),
          aiListeningIdentityProvider.overrideWith((ref) {
            final auth = ref.watch(authControllerProvider);
            return auth.userToken == 'a' ? first.future : second.future;
          }),
        ],
      );
      addTearDown(container.dispose);
      container.listen(
        listeningFeedbackProvider,
        (_, _) {},
        fireImmediately: true,
      );
      final auth = container.read(authControllerProvider.notifier) as TestAuth;
      auth.setToken('a');
      await pumpEventQueue();
      tracker.start(trackId: '1', durationMs: 100000);
      auth.setToken('b');
      first.complete('123');
      await pumpEventQueue();
      tracker.finish(ListeningTransitionCause.manualNext);
      expect(events, isEmpty);
      second.complete('456');
      await pumpEventQueue();
      tracker.start(trackId: '2', durationMs: 100000);
      tracker.finish(ListeningTransitionCause.manualNext);
      expect(events.single.identity, '456');
      auth.setToken(null);
      await pumpEventQueue();
      tracker.start(trackId: '3', durationMs: 100000);
      tracker.finish(ListeningTransitionCause.manualNext);
      expect(events.last.identity, 'anonymous');
    },
  );

  test('identity failure keeps attribution unknown', () async {
    final container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWith(TestAuth.new),
        listeningStoredAccountPresentProvider.overrideWith((ref) async => true),
        aiListeningIdentityProvider.overrideWith(
          (ref) async => throw StateError('lookup'),
        ),
      ],
    );
    addTearDown(container.dispose);
    (container.read(authControllerProvider.notifier) as TestAuth).setToken('a');
    await expectLater(
      container.read(listeningPartitionProvider.future),
      throwsA(isA<StateError>()),
    );
  });

  test('transient identity failure recovers without backfilling hearing', () {
    fakeAsync((clock) {
      final api = RecoverableIdentityApi();
      final events = <ListeningEvent>[];
      final tracker = ListeningTracker(
        onEvent: events.add,
        monotonicMs: () => clock.elapsed.inMilliseconds,
      );
      final container = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWith(TestAuth.new),
          soundcloudApiProvider.overrideWithValue(api),
          listeningTrackerProvider.overrideWithValue(tracker),
          listeningStoredAccountPresentProvider.overrideWith(
            (ref) async => true,
          ),
        ],
      );
      container.listen(
        listeningFeedbackProvider,
        (_, _) {},
        fireImmediately: true,
      );
      (container.read(authControllerProvider.notifier) as TestAuth).setToken(
        'a',
      );
      clock.elapse(Duration.zero);
      expect(container.read(listeningPartitionProvider).hasError, isTrue);
      expect(api.calls, 1);
      tracker.start(trackId: '1', durationMs: 100000);
      tracker.setPlaying(true);
      // An unknown session remains unrecorded across another failed lookup.
      clock.elapse(const Duration(seconds: 1));
      tracker.sample(positionMs: 1000, playing: true);
      expect(events, isEmpty);
      api.available = true;
      clock.elapse(const Duration(seconds: 2));
      expect(container.read(listeningPartitionProvider).asData?.value, '123');
      expect(events, isEmpty);
      tracker.sample(positionMs: 3000, playing: true);
      // Only hearing observed after the recovered identity may be attributed.
      for (var second = 4; second <= 9; second++) {
        clock.elapse(const Duration(seconds: 1));
        tracker.sample(positionMs: second * 1000, playing: true);
      }
      tracker.finish(ListeningTransitionCause.stopped);
      expect(events.single.identity, '123');
      expect(events.single.heardMs, 6000);
      final callsAfterRecovery = api.calls;
      clock.elapse(const Duration(minutes: 1));
      expect(api.calls, callsAfterRecovery);
      container.dispose();
      clock.flushMicrotasks();
    });
  });

  for (final action in ['logout', 'account switch', 'disposal']) {
    test('pending identity retry is cancelled on $action', () {
      fakeAsync((clock) {
        final api = RecoverableIdentityApi();
        final events = <ListeningEvent>[];
        final tracker = ListeningTracker(onEvent: events.add);
        final container = ProviderContainer(
          overrides: [
            authControllerProvider.overrideWith(TestAuth.new),
            soundcloudApiProvider.overrideWithValue(api),
            listeningTrackerProvider.overrideWithValue(tracker),
            listeningStoredAccountPresentProvider.overrideWith(
              (ref) async => true,
            ),
          ],
        );
        container.listen(
          listeningFeedbackProvider,
          (_, _) {},
          fireImmediately: true,
        );
        final auth =
            container.read(authControllerProvider.notifier) as TestAuth;
        auth.setToken('a');
        clock.elapse(Duration.zero);
        expect(container.read(listeningPartitionProvider).hasError, isTrue);
        tracker.start(trackId: '1', durationMs: 100000);
        api.available = true;
        api.identity = '456';
        if (action == 'disposal') {
          container.dispose();
        } else {
          auth.setToken(action == 'logout' ? null : 'b');
          clock.elapse(Duration.zero);
          expect(
            container.read(listeningPartitionProvider).asData?.value,
            action == 'logout' ? 'anonymous' : '456',
          );
          tracker.finish(ListeningTransitionCause.stopped);
        }
        final callsAfterChange = api.calls;
        clock.elapse(const Duration(minutes: 2));
        expect(api.calls, callsAfterChange);
        expect(events.where((event) => event.identity == '123'), isEmpty);
        if (action != 'disposal') container.dispose();
        clock.flushMicrotasks();
      });
    });
  }

  test('in-flight identity recovery cannot reattribute a new account', () {
    fakeAsync((clock) {
      final api = RecoverableIdentityApi();
      final events = <ListeningEvent>[];
      final tracker = ListeningTracker(onEvent: events.add);
      final container = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWith(TestAuth.new),
          soundcloudApiProvider.overrideWithValue(api),
          listeningTrackerProvider.overrideWithValue(tracker),
          listeningStoredAccountPresentProvider.overrideWith(
            (ref) async => true,
          ),
        ],
      );
      container.listen(
        listeningFeedbackProvider,
        (_, _) {},
        fireImmediately: true,
      );
      final auth = container.read(authControllerProvider.notifier) as TestAuth;
      auth.setToken('a');
      clock.elapse(Duration.zero);
      final pending = api.pending = Completer<RailData>();
      clock.elapse(const Duration(seconds: 1));
      expect(container.read(listeningPartitionProvider).isLoading, isTrue);
      final callsInFlight = api.calls;
      clock.elapse(const Duration(minutes: 1));
      expect(api.calls, callsInFlight, reason: 'No parallel recovery requests');
      tracker.start(trackId: '1', durationMs: 100000);
      api.pending = null;
      api.available = true;
      api.identity = '456';
      auth.setToken('b');
      clock.elapse(Duration.zero);
      expect(container.read(listeningPartitionProvider).asData?.value, '456');
      pending.complete((
        me: const Artist(id: '123', handle: 'old', followers: 0),
        likes: <Track>[],
        history: <Track>[],
      ));
      clock.elapse(Duration.zero);
      tracker.finish(ListeningTransitionCause.stopped);
      expect(events.single.identity, '456');
      container.dispose();
      clock.flushMicrotasks();
    });
  });

  test(
    'late identity after logout or disposal cannot restore attribution',
    () async {
      for (final disposeBeforeLookup in [false, true]) {
        final lookup = Completer<String>();
        final events = <ListeningEvent>[];
        final tracker = ListeningTracker(onEvent: events.add);
        var lookups = 0;
        final container = ProviderContainer(
          overrides: [
            authControllerProvider.overrideWith(TestAuth.new),
            listeningStoredAccountPresentProvider.overrideWith(
              (ref) async => true,
            ),
            listeningTrackerProvider.overrideWithValue(tracker),
            aiListeningIdentityProvider.overrideWith((ref) {
              ref.watch(authControllerProvider);
              lookups++;
              return lookup.future;
            }),
          ],
        );
        container.listen(
          listeningFeedbackProvider,
          (_, _) {},
          fireImmediately: true,
        );
        final auth =
            container.read(authControllerProvider.notifier) as TestAuth;
        auth.setToken('a');
        await pumpEventQueue();
        expect(lookups, 1);
        tracker.start(trackId: '1', durationMs: 100000);
        auth.setToken(null);
        await pumpEventQueue();
        final afterLogout = lookups;
        if (disposeBeforeLookup) container.dispose();
        lookup.complete('123');
        await pumpEventQueue();
        expect(lookups, afterLogout);
        if (!disposeBeforeLookup) {
          tracker.start(trackId: '2', durationMs: 100000);
          tracker.finish(ListeningTransitionCause.manualNext);
          expect(events, isNotEmpty);
          expect(
            events.every((event) => event.identity == 'anonymous'),
            isTrue,
          );
          container.dispose();
        }
        expect(events.where((event) => event.identity == '123'), isEmpty);
      }
    },
  );
}
