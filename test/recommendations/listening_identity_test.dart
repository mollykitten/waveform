import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/api/soundcloud_auth.dart';
import 'package:waveform_app/core/recommendations/listening_event.dart';
import 'package:waveform_app/core/recommendations/listening_providers.dart';
import 'package:waveform_app/core/recommendations/listening_tracker.dart';
import 'package:waveform_app/core/recommendations/providers.dart';

class TestAuth extends AuthController {
  @override
  SoundcloudAuth build() => const SoundcloudAuth();
  void setToken(String? token) => state = SoundcloudAuth(userToken: token);
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
