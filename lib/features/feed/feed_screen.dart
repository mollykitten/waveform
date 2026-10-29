import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../../core/api/feeds.dart';
import '../../core/api/soundcloud_auth.dart';
import '../../shared/models/feed_post.dart';
import '../../shared/widgets/async_view.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/logged_out_view.dart';
import '../../shared/widgets/rail_layout.dart';
import 'widgets/feed_post_card.dart';

/// Показывать ли репосты в ленте (тогл в шапке Feed). Сессионный.
class FeedShowReposts extends Notifier<bool> {
  @override
  bool build() => true;
  void toggle() => state = !state;
}

final feedShowRepostsProvider =
    NotifierProvider<FeedShowReposts, bool>(FeedShowReposts.new);

class FeedScreen extends ConsumerWidget {
  const FeedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authed = ref.watch(authControllerProvider).isAuthenticated;
    if (!authed) {
      return const RailLayout(
        child: LoggedOutView(
          title: 'your feed',
          subtitle: 'log in and follow artists to see their latest posts here',
        ),
      );
    }
    final feed = ref.watch(feedProvider);
    return RailLayout(
      child: AsyncView<List<FeedPost>>(
        value: feed,
        onRetry: () => ref.invalidate(feedProvider),
        data: (posts) {
          if (posts.isEmpty) {
            return const EmptyState(
              icon: Icons.notifications_outlined,
              title: 'your feed is quiet',
              subtitle:
                  'follow more artists to see their posts and reposts here',
            );
          }
          final showReposts = ref.watch(feedShowRepostsProvider);
          final visible = showReposts
              ? posts
              : [
                  for (final p in posts)
                    if (p.action != FeedAction.reposted) p,
                ];
          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.pagePad,
              AppTheme.topBarHeight + 26,
              AppTheme.pagePad,
              AppTheme.playerHeight + 32,
            ),
            children: [
              const _FeedIntro(),
              const SizedBox(height: 20),
              if (visible.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: Text(
                    'only reposts here — turn reposts back on to see them',
                    style: AppTheme.mono(size: 12, color: AppColors.textMid),
                  ),
                ),
              for (final post in visible)
                FeedPostCard(
                  post: post,
                  queue: [for (final p in visible) p.track],
                ),
            ],
          );
        },
      ),
    );
  }
}

class _FeedIntro extends ConsumerWidget {
  const _FeedIntro();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showReposts = ref.watch(feedShowRepostsProvider);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'this is your feed',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textHi,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'latest posts from the people you follow',
                style: AppTheme.mono(size: 12, color: AppColors.textMid),
              ),
            ],
          ),
        ),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => ref.read(feedShowRepostsProvider.notifier).toggle(),
            child: Tooltip(
              message: showReposts ? 'hide reposts' : 'show reposts',
              child: Row(
                children: [
                  Text(
                    'reposts',
                    style: AppTheme.mono(
                      size: 11,
                      color: showReposts ? AppColors.textHi : AppColors.textLow,
                    ),
                  ),
                  const SizedBox(width: 8),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    curve: Curves.easeOut,
                    width: 34,
                    height: 18,
                    alignment: showReposts
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: showReposts ? AppColors.acid : AppColors.surface2,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: const BoxDecoration(
                        color: AppColors.bg,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
