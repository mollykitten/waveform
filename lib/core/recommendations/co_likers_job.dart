import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/soundcloud_auth.dart';
import '../log/talker.dart';
import 'providers.dart';

/// Starts the co-likers refresh in the background: once after sign-in and
/// whenever my wave opens. Never awaited by playback; a logout or account
/// switch cancels the run in flight.
class CoLikersJob {
  CoLikersJob(this._ref);
  final Ref _ref;
  int _epoch = 0;
  bool _running = false;

  void start() {
    if (_running || !_ref.mounted) return;
    if (!_ref.read(authControllerProvider).isAuthenticated) return;
    unawaited(_run());
  }

  void cancel() {
    _epoch++;
    _running = false;
  }

  Future<void> _run() async {
    _running = true;
    final epoch = _epoch;
    final account = _ref.read(authControllerProvider).userToken;
    bool cancelled() =>
        !_ref.mounted ||
        epoch != _epoch ||
        account != _ref.read(authControllerProvider).userToken;
    try {
      final identity = await _ref.read(listeningIdentityProvider.future);
      if (cancelled() || identity == 'anonymous') return;
      await _ref
          .read(coLikersSourceProvider)
          .refresh(identity, isCancelled: cancelled);
    } catch (error) {
      if (_ref.mounted) {
        _ref
            .read(talkerProvider)
            .warning('co-likers refresh failed: ${error.runtimeType}');
      }
    } finally {
      if (epoch == _epoch) _running = false;
    }
  }
}

final coLikersJobProvider = Provider<CoLikersJob>((ref) {
  final job = CoLikersJob(ref);
  ref.listen(authControllerProvider.select((s) => s.userToken), (_, token) {
    job.cancel();
    if (token != null) job.start();
  });
  ref.onDispose(job.cancel);
  return job;
});
