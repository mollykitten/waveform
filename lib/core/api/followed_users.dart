import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import 'soundcloud_api.dart';
import 'soundcloud_auth.dart';

/// IDs of the users the signed-in account follows: the single source for the
/// follow button. api-v2 has no per-user lookup, so the whole followings list
/// is paged in (cursor `next_href`) and published after every page. Reloads
/// on login/logout.
class FollowedUsersController extends Notifier<Set<String>> {
  /// Token of the current load: a stale load (login changed mid-paging) drops
  /// its results.
  int _loadToken = 0;

  @override
  Set<String> build() {
    ref.watch(authControllerProvider);
    _load();
    return const {};
  }

  Future<void> _load() async {
    final token = ++_loadToken;
    final api = ref.read(soundcloudApiProvider);
    final acc = <String>{};
    String? cursor;
    const maxPages = 50; // 50 × 200 = 10000 followings
    for (var page = 0; page < maxPages; page++) {
      final res = await api.followingsPage(nextHref: cursor);
      if (token != _loadToken) return;
      if (res.ids.isEmpty) break;
      acc.addAll(res.ids);
      state = {...acc};
      cursor = res.nextHref;
      if (cursor == null) break;
    }
  }

  bool isFollowing(String id) => state.contains(id);

  /// Optimistic toggle with rollback when the write fails.
  Future<LikeOutcome> toggle(String userId) async {
    final follow = !state.contains(userId);
    state = follow ? {...state, userId} : ({...state}..remove(userId));
    final outcome = await ref
        .read(soundcloudApiProvider)
        .setFollowing(userId, follow);
    if (outcome != LikeOutcome.ok) {
      state = follow ? ({...state}..remove(userId)) : {...state, userId};
    }
    return outcome;
  }
}

final followedUsersProvider =
    NotifierProvider<FollowedUsersController, Set<String>>(
      FollowedUsersController.new,
    );
