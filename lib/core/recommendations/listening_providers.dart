import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/soundcloud_auth.dart';
import '../storage/token_store.dart';
import 'listening_event.dart';
import 'listening_store_provider.dart';
import 'listening_tracker.dart';
import 'providers.dart';

export 'listening_store_provider.dart' show listeningStoreProvider;

/// Readiness gate only: the token itself never enters listening state or storage.
final listeningStoredAccountPresentProvider = FutureProvider<bool>((ref) async {
  return (await const TokenStore().read())?.isNotEmpty ?? false;
}, retry: (_, _) => null);

class _ObservedAuthenticated extends Notifier<bool> {
  @override
  bool build() {
    ref.listen(authControllerProvider, (_, next) {
      if (next.isAuthenticated) state = true;
    });
    return ref.read(authControllerProvider).isAuthenticated;
  }
}

final _observedAuthenticatedProvider =
    NotifierProvider<_ObservedAuthenticated, bool>(_ObservedAuthenticated.new);

/// Do not mistake auth's initial anonymous state for a restored account.
final listeningPartitionProvider = FutureProvider<String?>((ref) async {
  final auth = ref.watch(authControllerProvider);
  final restored = ref.watch(_observedAuthenticatedProvider);
  if (!auth.isAuthenticated) {
    if (restored) return 'anonymous';
    final stored = await ref.watch(
      listeningStoredAccountPresentProvider.future,
    );
    if (!ref.mounted || ref.read(authControllerProvider).isAuthenticated) {
      return null;
    }
    return stored ? null : 'anonymous';
  }
  final identity = await ref.watch(aiListeningIdentityProvider.future);
  if (!ref.mounted ||
      identity == 'anonymous' ||
      !validListeningIdentity(identity)) {
    return null;
  }
  return identity;
}, retry: (_, _) => null);

/// The player can record immediately without starting identity or network work.
final listeningTrackerProvider = Provider<ListeningTracker>((ref) {
  final store = ref.read(listeningStoreProvider);
  final tracker = ListeningTracker(
    onEvent: (event) {
      unawaited(store.append(event));
    },
  );
  ref.onDispose(() => tracker.finish(ListeningTransitionCause.disposal));
  return tracker;
});

/// AppShell-owned bootstrap. Attribution is cleared synchronously on auth change.
final listeningFeedbackProvider = Provider<void>((ref) {
  final tracker = ref.watch(listeningTrackerProvider);
  final store = ref.read(listeningStoreProvider);
  Timer? identityRetry;
  var retrySeconds = 1;
  ref.listen(authControllerProvider, (previous, next) {
    if (previous?.userToken != next.userToken) {
      identityRetry?.cancel();
      retrySeconds = 1;
      tracker.setIdentity(null);
    }
  });
  // Logging out drops that account's seen memory; switching accounts keeps
  // each one's file so A -> B -> A loses nothing. Lives here because
  // AppShell always reads this provider, unlike the recommendations screen.
  String? knownIdentity;
  ref.listen(listeningPartitionProvider, (_, next) {
    final identity = next.asData?.value;
    if (identity != null) {
      final was = knownIdentity;
      knownIdentity = identity == 'anonymous' ? null : identity;
      if (was != null && identity == 'anonymous') {
        unawaited(ref.read(seenStoreProvider).forget(was));
      }
    }
    tracker.setIdentity(
      next.isLoading || next.hasError ? null : next.asData?.value,
    );
    identityRetry?.cancel();
    if (next.isLoading) return;
    if (!next.hasError) {
      retrySeconds = 1;
      return;
    }
    final auth = ref.read(authControllerProvider);
    if (!auth.isAuthenticated) return;
    // Retry the upstream lookup: rebuilding the partition alone reuses its error.
    identityRetry = Timer(Duration(seconds: retrySeconds), () {
      if (!ref.mounted ||
          ref.read(authControllerProvider).userToken != auth.userToken) {
        return;
      }
      ref.invalidate(aiListeningIdentityProvider);
    });
    retrySeconds = (retrySeconds * 2).clamp(1, 30);
  }, fireImmediately: true);
  final lifecycle = AppLifecycleListener(
    onExitRequested: () async {
      tracker.finish(ListeningTransitionCause.stopped);
      await store.flush();
      return AppExitResponse.exit;
    },
    onDetach: () {
      tracker.finish(ListeningTransitionCause.disposal);
      unawaited(store.flush());
    },
  );
  ref.onDispose(() {
    identityRetry?.cancel();
    lifecycle.dispose();
    tracker.finish(ListeningTransitionCause.disposal);
    unawaited(store.flush());
  });
});
