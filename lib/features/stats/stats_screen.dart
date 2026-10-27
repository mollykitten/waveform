import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../../core/api/stats.dart';
import '../../shared/format.dart';
import '../../shared/widgets/async_view.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/pressable.dart';
import '../../shared/widgets/section_header.dart';
import 'wave_source_summary.dart';

class StatsScreen extends ConsumerWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(statsProvider);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: AsyncView<ListeningStats>(
          value: stats,
          onRetry: () => ref.invalidate(statsProvider),
          data: (s) => s.isEmpty
              ? const EmptyState(
                  icon: Icons.bar_chart,
                  title: 'no listening data yet',
                  subtitle:
                      'play some tracks — stats appear after a few sessions',
                )
              : _Body(stats: s),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.stats});
  final ListeningStats stats;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.pagePad,
        AppTheme.topBarHeight + 24,
        AppTheme.pagePad,
        AppTheme.playerHeight + 32,
      ),
      children: [
        const _Back(),
        const SizedBox(height: 12),
        const Text(
          'listening stats',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: AppColors.textHi,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'aggregated from your soundcloud play-history (up to last ~400 plays)',
          style: AppTheme.mono(size: 11, color: AppColors.textLow),
        ),
        const SizedBox(height: 26),
        Row(
          children: [
            Expanded(
              child: _Tile(big: '${stats.totalPlays}', small: 'plays'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _Tile(big: '${stats.uniqueArtists}', small: 'artists'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _Tile(
                big: _formatHours(stats.totalListened),
                small: 'hours',
              ),
            ),
          ],
        ),
        const SizedBox(height: 28),
        const SectionHeader(title: 'top artists'),
        const SizedBox(height: AppTheme.headerGap),
        for (var i = 0; i < stats.topArtists.length; i++)
          _ArtistRow(
            rank: i + 1,
            name: stats.topArtists[i].name,
            count: stats.topArtists[i].count,
            maxCount: stats.topArtists.first.count,
          ),
        const SizedBox(height: 28),
        if (stats.topGenres.isNotEmpty) ...[
          const SectionHeader(title: 'top genres'),
          const SizedBox(height: AppTheme.headerGap),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final g in stats.topGenres)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: AppTheme.borderRadius,
                    border: AppTheme.border(),
                  ),
                  child: Text(
                    '${g.genre} · ${g.count}',
                    style: AppTheme.mono(size: 11, color: AppColors.textHi),
                  ),
                ),
            ],
          ),
        ],
        const WaveSourceSummary(),
      ],
    );
  }

  String _formatHours(Duration d) {
    final h = d.inMinutes / 60.0;
    if (h >= 10) return h.round().toString();
    return h.toStringAsFixed(1);
  }
}

class _Back extends StatelessWidget {
  const _Back();
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Pressable(
        onTap: () => context.canPop() ? context.pop() : context.go('/'),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.chevron_left, size: 18, color: AppColors.textMid),
            Text(
              'back',
              style: AppTheme.mono(size: 12, color: AppColors.textMid),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.big, required this.small});
  final String big;
  final String small;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppTheme.borderRadius,
        border: AppTheme.border(),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            big,
            style: AppTheme.mono(
              size: 30,
              color: AppColors.textHi,
              weight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            small.toUpperCase(),
            style: AppTheme.mono(
              size: 10,
              color: AppColors.textLow,
              weight: FontWeight.w600,
              letterSpacing: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _ArtistRow extends StatelessWidget {
  const _ArtistRow({
    required this.rank,
    required this.name,
    required this.count,
    required this.maxCount,
  });
  final int rank;
  final String name;
  final int count;
  final int maxCount;
  @override
  Widget build(BuildContext context) {
    final fraction = (count / maxCount).clamp(0.0, 1.0);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppTheme.borderRadius,
        border: AppTheme.border(),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 28,
                child: Text(
                  '$rank.',
                  style: AppTheme.mono(
                    size: 11,
                    color: AppColors.textLow,
                    weight: FontWeight.w600,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textHi,
                  ),
                ),
              ),
              Text(
                '${Fmt.count(count)} plays',
                style: AppTheme.mono(size: 11, color: AppColors.textMid),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 3,
              backgroundColor: AppColors.border,
              valueColor: const AlwaysStoppedAnimation<Color>(AppColors.acid),
            ),
          ),
        ],
      ),
    );
  }
}
