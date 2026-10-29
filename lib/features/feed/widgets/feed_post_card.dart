import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../app/theme/colors.dart';
import '../../../core/api/liked_tracks.dart';
import '../../../core/api/soundcloud_api.dart';
import '../../../shared/action_feedback.dart';
import '../../../shared/format.dart';
import '../../../shared/models/feed_post.dart';
import '../../../shared/models/track.dart';
import '../../../shared/widgets/cover_art.dart';
import '../../../shared/widgets/pressable.dart';
import '../../../shared/widgets/live_waveform.dart';
import '../../player/player_controller.dart';

/// Карточка поста ленты: шапка автора + waveform-плеер + бар действий.
class FeedPostCard extends ConsumerWidget {
  const FeedPostCard({super.key, required this.post, this.queue});

  final FeedPost post;

  /// Список треков ленты — очередь для next/previous.
  final List<Track>? queue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = post.track;
    final player = ref.watch(playerControllerProvider);
    final controller = ref.read(playerControllerProvider.notifier);
    final isCurrent = player.track?.id == track.id;
    final isPlaying = isCurrent && player.isPlaying;
    final progress = isCurrent ? player.progress : 0.0;

    void onPlay() =>
        isCurrent ? controller.toggle() : controller.play(track, queue: queue);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppTheme.borderRadius,
        border: AppTheme.border(),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ActorHeader(post: post),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CoverArt(seed: track.id, imageUrl: track.coverUrl, size: 128),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        _PlayButton(isPlaying: isPlaying, onTap: onPlay),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Pressable(
                                onTap: () => context.push(
                                  '/artist/${Uri.encodeComponent(track.artistHandle)}',
                                ),
                                child: Text(
                                  track.artist,
                                  style: AppTheme.mono(
                                    size: 11,
                                    color: AppColors.textMid,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Pressable(
                                onTap: () => context.push('/track/${track.id}'),
                                child: Text(
                                  track.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textHi,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        _TagChip(tag: post.tag),
                      ],
                    ),
                    const SizedBox(height: 12),
                    LiveWaveform(
                      waveformUrl: track.waveformUrl,
                      fallbackBars: track.waveform,
                      progress: progress,
                      height: 56,
                      onSeek: isCurrent ? controller.seekFraction : null,
                    ),
                    const SizedBox(height: 12),
                    _ActionBar(post: post),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActorHeader extends StatelessWidget {
  const _ActorHeader({required this.post});
  final FeedPost post;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Pressable(
          onTap: () =>
              context.push('/artist/${Uri.encodeComponent(post.actor)}'),
          child: CoverArt(seed: post.actorSeed, size: 28, circular: true),
        ),
        const SizedBox(width: 10),
        Pressable(
          onTap: () =>
              context.push('/artist/${Uri.encodeComponent(post.actor)}'),
          child: Text(
            post.actor,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.textHi,
            ),
          ),
        ),
        const SizedBox(width: 8),
        if (post.action == FeedAction.reposted)
          const Padding(
            padding: EdgeInsets.only(right: 5),
            child: Icon(Icons.repeat, size: 13, color: AppColors.textLow),
          ),
        Text(
          '${post.actionLabel} · ${post.timeAgo}',
          style: AppTheme.mono(size: 11, color: AppColors.textLow),
        ),
      ],
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.isPlaying, required this.onTap});
  final bool isPlaying;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          decoration: const BoxDecoration(
            color: AppColors.acid,
            shape: BoxShape.circle,
          ),
          child: Icon(
            isPlaying ? Icons.pause : Icons.play_arrow,
            color: AppColors.bg,
            size: 24,
          ),
        ),
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({required this.tag});
  final String tag;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: AppTheme.borderRadius,
        border: AppTheme.border(),
      ),
      child: Text(
        '#$tag',
        style: AppTheme.mono(size: 11, color: AppColors.textMid),
      ),
    );
  }
}

class _ActionBar extends ConsumerStatefulWidget {
  const _ActionBar({required this.post});
  final FeedPost post;

  @override
  ConsumerState<_ActionBar> createState() => _ActionBarState();
}

class _ActionBarState extends ConsumerState<_ActionBar> {
  // Оптимистичный ±1 на счётчике; откатывается, если API ответила !ok.
  int _likesDelta = 0;

  Future<void> _toggleLike() async {
    final track = widget.post.track;
    final wasLiked = ref.read(likedTracksProvider).contains(track.id);
    setState(() => _likesDelta += wasLiked ? -1 : 1);
    final outcome = await ref
        .read(likedTracksProvider.notifier)
        .toggle(track.id, track: track);
    if (outcome != LikeOutcome.ok && mounted) {
      setState(() => _likesDelta += wasLiked ? 1 : -1);
    }
    if (mounted) showWriteOutcome(context, outcome, verb: 'like');
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.post.track;
    // Источник правды — множество лайков пользователя, а не данные поста.
    final liked = ref.watch(likedTracksProvider).contains(t.id);
    return Row(
      children: [
        _Action(
          icon: liked ? Icons.favorite : Icons.favorite_border,
          iconColor: liked ? AppColors.acid : null,
          value: Fmt.count(t.likes + _likesDelta),
          onTap: _toggleLike,
        ),
        _Action(icon: Icons.repeat, value: Fmt.count(t.reposts)),
        const _Action(icon: Icons.share_outlined),
        const _Action(icon: Icons.more_horiz),
        const Spacer(),
        Icon(Icons.play_arrow, size: 13, color: AppColors.textLow),
        const SizedBox(width: 3),
        Text(Fmt.count(t.plays), style: AppTheme.mono(size: 11)),
        const SizedBox(width: 14),
        Icon(Icons.mode_comment_outlined, size: 12, color: AppColors.textLow),
        const SizedBox(width: 4),
        Text(Fmt.count(widget.post.comments), style: AppTheme.mono(size: 11)),
      ],
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, this.value, this.iconColor, this.onTap});
  final IconData icon;
  final String? value;
  final Color? iconColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(right: 18),
          child: Row(
            children: [
              Icon(icon, size: 15, color: iconColor ?? AppColors.textMid),
              if (value != null) ...[
                const SizedBox(width: 5),
                Text(value!, style: AppTheme.mono(size: 11)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
