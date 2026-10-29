import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../log/talker.dart';
import 'providers.dart';
import 'soundcloud_api.dart';
import 'soundcloud_auth.dart';

/// IDs of the users the signed-in account follows: the single source for the
/// follow button. api-v2 has no per-user lookup, so the whole followings list
/// is paged in (cursor `next_href`) and published after every page. Reloads
/// on login/logout.
///
/// User toggles live in [_overrides] and are laid over the server snapshot on
/// every publish, so a page arriving mid-toggle cannot undo it.
class FollowedUsersController extends Notifier<Set<String>> {
  /// Token of the current load: a stale load (login changed mid-paging) drops
  /// its results.
  int _loadToken = 0;

  /// Bumped when auth changes (build): late writes of the old account are ignored.
  int _epoch = 0;
  bool _loading = false;
  bool _complete = true;
  Set<String> _snapshot = {};
  final _overrides = <String, bool>{};
  final _confirmed = <String>{};

  /// False when paging stopped on an error: the set may miss older followings.
  bool get isComplete => _complete;

  @override
  Set<String> build() {
    ref.watch(authControllerProvider);
    _epoch++;
    _snapshot = {};
    _overrides.clear();
    _confirmed.clear();
    _complete = true;
    load();
    return const {};
  }

  void _publish() {
    final out = {..._snapshot};
    _overrides.forEach((id, on) => on ? out.add(id) : out.remove(id));
    state = out;
  }

  /// Pages the followings in. A failing page is retried once; if it still
  /// fails the partial set is kept, logged, and [isComplete] turns false.
  Future<void> load() async {
    final token = ++_loadToken;
    _loading = true;
    _complete = true;
    final api = ref.read(soundcloudApiProvider);
    final acc = <String>{};
    String? cursor;
    const maxPages = 50; // 50 × 200 = 10000 followings
    for (var page = 0; page < maxPages; page++) {
      ({List<String> ids, String? nextHref}) res;
      try {
        try {
          res = await api.followingsPage(nextHref: cursor);
        } catch (_) {
          res = await api.followingsPage(nextHref: cursor);
        }
      } catch (e, st) {
        if (token != _loadToken) return;
        ref
            .read(talkerProvider)
            .warning('followings: page $page failed, set is partial', e, st);
        _complete = false;
        break;
      }
      if (token != _loadToken) return;
      if (res.ids.isEmpty) break;
      acc.addAll(res.ids);
      _snapshot = {...acc};
      _publish();
      cursor = res.nextHref;
      if (cursor == null) break;
    }
    _loading = false;
    // Writes confirmed during the load may postdate the pages we read: fold
    // them into the snapshot instead of letting stale pages win.
    for (final id in _confirmed) {
      final on = _overrides.remove(id);
      if (on == null) continue;
      on ? _snapshot.add(id) : _snapshot.remove(id);
    }
    _confirmed.clear();
    _publish();
  }

  bool isFollowing(String id) => state.contains(id);

  /// Optimistic toggle with rollback when the write fails.
  Future<LikeOutcome> toggle(String userId) async {
    final follow = !state.contains(userId);
    final epoch = _epoch;
    _overrides[userId] = follow;
    _publish();
    final outcome = await ref
        .read(soundcloudApiProvider)
        .setFollowing(userId, follow);
    if (epoch != _epoch) return outcome; // auth changed: state was reset
    if (outcome == LikeOutcome.ok) {
      if (_loading) {
        _confirmed.add(userId);
      } else {
        _overrides.remove(userId);
        follow ? _snapshot.add(userId) : _snapshot.remove(userId);
      }
    } else {
      _overrides.remove(userId);
    }
    _publish();
    return outcome;
  }
}

final followedUsersProvider =
    NotifierProvider<FollowedUsersController, Set<String>>(
      FollowedUsersController.new,
    );
