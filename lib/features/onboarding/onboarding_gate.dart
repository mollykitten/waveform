import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/storage/prefs_store.dart';

/// Whether the first-run onboarding has been seen. `true` means "do not
/// show": that is also the default until [restore] has read `prefs.json`, so
/// tests and early frames never get bounced to `/welcome` by accident.
///
/// The router listens to it (`refreshListenable`), so [reset] sends the app
/// straight back to the onboarding from any screen.
class OnboardingGate extends ValueNotifier<bool> {
  OnboardingGate({PrefsStore store = const PrefsStore(), bool seen = true})
    : _store = store,
      super(seen);

  static const prefsKey = 'onboardingDone';

  final PrefsStore _store;

  /// Reads the persisted flag; a missing key means a first launch.
  Future<void> restore() async {
    try {
      value = await _store.readBool(prefsKey) ?? false;
    } catch (_) {
      value = true;
    }
  }

  Future<void> complete() => _set(true);

  Future<void> reset() => _set(false);

  Future<void> _set(bool seen) async {
    value = seen;
    try {
      await _store.writeBool(prefsKey, seen);
    } catch (_) {
      // The flag is best effort: a failed write only shows the tour again.
    }
  }
}

/// App-wide instance used by the router; [main] restores it before `runApp`.
final onboardingGate = OnboardingGate();

final onboardingGateProvider = Provider<OnboardingGate>(
  (ref) => onboardingGate,
);

/// Sends every route to `/welcome` until the onboarding has been seen.
GoRouterRedirect onboardingRedirect(OnboardingGate gate) =>
    (context, state) =>
        !gate.value && state.uri.path != '/welcome' ? '/welcome' : null;
