import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../../core/api/liked_tracks.dart';
import '../../features/player/player_controller.dart';
import '../action_feedback.dart';
import '../format.dart';
import '../models/track.dart';
import 'cover_art.dart';
import 'go_plus_badge.dart';
import 'pressable.dart';
import 'track_context_menu.dart';
import 'live_waveform.dart';

/// Компактная играбельная строка трека: play + обложка + название/артист
/// + мини-waveform + моно-метрики. Используется в related, popular, и т.д.
class TrackRow extends ConsumerWidget {
  const TrackRow({super.key, required this.track, this.queue});

  final Track track;

  /// Список, в контексте которого играем (для next/previous).
  final List<Track>? queue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerControllerProvider);
    final c = ref.read(playerControllerProvider.notifier);
    final c2 = ref.read(likedTracksProvider.notifier);
    final isCurrent = player.track?.id == track.id;
    final isPlaying = isCurrent && player.isPlaying;
    final progress = isCurrent ? player.progress : 0.0;
    final liked = ref.watch(likedTracksProvider).contains(track.id);

    return Listener(
      // Right-click / two-finger tap → контекстное меню. Listener'ом, а не
      // GestureDetector(onSecondaryTapDown:), чтобы не конкурировать в gesture
      // arena с вложенными Pressable (которые иначе перехватывают всё).
      onPointerDown: (event) {
        if (event.buttons == kSecondaryButton) {
          showTrackContextMenu(
            context: context,
            ref: ref,
            track: track,
            queue: queue,
            globalPosition: event.position,
          );
        }
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isCurrent ? AppColors.surface2 : AppColors.surface,
          borderRadius: AppTheme.borderRadius,
          border: AppTheme.border(
            isCurrent ? AppColors.border : AppColors.borderDim,
          ),
        ),
        child: Row(
          children: [
            Pressable(
              onTap: () => isCurrent ? c.toggle() : c.play(track, queue: queue),
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.acid,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isPlaying ? Icons.pause : Icons.play_arrow,
                  semanticLabel: isPlaying
                      ? 'pause ${track.title}'
                      : 'play ${track.title}',
                  color: AppColors.bg,
                  size: 20,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Pressable(
              onTap: () => context.push('/track/${track.id}'),
              child: Hero(
                tag: 'cover-track-${track.id}',
                child: CoverArt(
                  seed: track.id,
                  imageUrl: track.coverUrl,
                  size: 46,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              flex: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Pressable(
                          onTap: () => context.push('/track/${track.id}'),
                          child: Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textHi,
                            ),
                          ),
                        ),
                      ),
                      if (track.goPlus) ...[
                        const SizedBox(width: 8),
                        const GoPlusBadge(),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Pressable(
                    onTap: () => context.push(
                      '/artist/${Uri.encodeComponent(track.artistHandle)}',
                    ),
                    child: Text(
                      track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.mono(size: 11, color: AppColors.textMid),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 6,
              child: LiveWaveform(
                waveformUrl: track.waveformUrl,
                fallbackBars: track.waveform,
                progress: progress,
                buffered: isCurrent ? player.bufferedFraction : 0,
                height: 30,
                onSeek: isCurrent ? c.seekFraction : null,
              ),
            ),
            const SizedBox(width: 16),
            const Icon(Icons.play_arrow, size: 12, color: AppColors.textLow),
            const SizedBox(width: 4),
            Text(Fmt.count(track.plays), style: AppTheme.mono(size: 11)),
            const SizedBox(width: 16),
            Pressable(
              onTap: () async {
                final outcome = await c2.toggle(track);
                if (context.mounted) showLikeOutcome(context, outcome);
              },
              child: Icon(
                liked ? Icons.favorite : Icons.favorite_border,
                semanticLabel: liked
                    ? 'unlike ${track.title}'
                    : 'like ${track.title}',
                size: 15,
                color: liked ? AppColors.acid : AppColors.textLow,
              ),
            ),
            const SizedBox(width: 16),
            Text(Fmt.time(track.duration), style: AppTheme.mono(size: 11)),
          ],
        ),
      ),
    );
  }
}
