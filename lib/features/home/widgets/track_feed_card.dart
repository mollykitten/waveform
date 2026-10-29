import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../app/theme/colors.dart';
import '../../../shared/format.dart';
import '../../../shared/models/track.dart';
import '../../../shared/widgets/cover_art.dart';
import '../../../shared/widgets/pressable.dart';
import '../../../shared/widgets/live_waveform.dart';
import '../../player/player_controller.dart';

class TrackFeedCard extends ConsumerWidget {
  const TrackFeedCard({super.key, required this.track, this.queue});

  final Track track;

  /// Список, в контексте которого играем (для next/previous).
  final List<Track>? queue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerControllerProvider);
    final isCurrent = player.track?.id == track.id;
    final isPlaying = isCurrent && player.isPlaying;
    final progress = isCurrent ? player.progress : 0.0;

    final controller = ref.read(playerControllerProvider.notifier);
    void onPlay() =>
        isCurrent ? controller.toggle() : controller.play(track, queue: queue);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppTheme.borderRadius,
        border: AppTheme.border(),
      ),
      child: SizedBox(
        height: 160,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Cover(
              seed: track.id,
              imageUrl: track.coverUrl,
              isPlaying: isPlaying,
              onPlay: onPlay,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Header(track: track),
                  const Spacer(),
                  LiveWaveform(
                    waveformUrl: track.waveformUrl,
                    fallbackBars: track.waveform,
                    progress: progress,
                    onSeek: isCurrent ? controller.seekFraction : null,
                  ),
                  const SizedBox(height: 10),
                  _MetaRow(track: track),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({
    required this.seed,
    required this.imageUrl,
    required this.isPlaying,
    required this.onPlay,
  });

  final String seed;
  final String? imageUrl;
  final bool isPlaying;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onPlay,
        child: Stack(
          alignment: Alignment.bottomLeft,
          children: [
            CoverArt(seed: seed, imageUrl: imageUrl),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Container(
                width: 36,
                height: 36,
                decoration: const BoxDecoration(
                  color: AppColors.acid,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isPlaying ? Icons.pause : Icons.play_arrow,
                  color: AppColors.bg,
                  size: 22,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
                  style: AppTheme.mono(size: 11, color: AppColors.textMid),
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
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textHi,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _Stat(icon: Icons.play_arrow, value: Fmt.count(track.plays)),
        _Stat(icon: Icons.favorite_border, value: Fmt.count(track.likes)),
        _Stat(icon: Icons.repeat, value: Fmt.count(track.reposts)),
        const Spacer(),
        Text(Fmt.time(track.duration), style: AppTheme.mono(size: 11)),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.value});

  final IconData icon;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: Row(
        children: [
          Icon(icon, size: 13, color: AppColors.textLow),
          const SizedBox(width: 4),
          Text(value, style: AppTheme.mono(size: 11)),
        ],
      ),
    );
  }
}
