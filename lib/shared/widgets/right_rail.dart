import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../../core/api/feeds.dart';
import '../../core/api/soundcloud_api.dart';
import '../../core/api/soundcloud_auth.dart';
import '../../features/auth/login_dialog.dart';
import '../format.dart';
import '../models/artist.dart';
import '../models/track.dart';
import 'async_view.dart';
import 'cover_art.dart';
import 'pressable.dart';

/// Правый рейл: профиль, шорткаты в коллекции (likes/playlists/following с
/// реальными счётчиками), превью последних лайков и история прослушивания.
/// Только реальные данные из railProvider — никаких подставных секций.
class RightRail extends ConsumerWidget {
  const RightRail({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rail = ref.watch(railProvider);
    final authed = ref.watch(authControllerProvider).isAuthenticated;
    return Container(
      width: 300,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(left: AppTheme.borderSideStatic),
      ),
      child: AsyncView<RailData>(
        value: rail,
        onRetry: () => ref.invalidate(railProvider),
        data: (d) => ListView(
          padding: const EdgeInsets.fromLTRB(
            22,
            AppTheme.topBarHeight + 22,
            22,
            AppTheme.playerHeight + 22,
          ),
          children: [
            _Header(me: d.me, authed: authed),
            // Личные секции — только залогиненным.
            if (authed) ...[
              const SizedBox(height: 20),
              _StatTiles(me: d.me),
              const SizedBox(height: 10),
              Pressable(
                onTap: () => context.go('/stats'),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.bg,
                    borderRadius: AppTheme.borderRadius,
                    border: AppTheme.border(),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.bar_chart,
                        size: 14,
                        color: AppColors.textMid,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'view listening stats',
                          style: AppTheme.mono(
                            size: 11,
                            color: AppColors.textHi,
                            weight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const Text('→', style: TextStyle(color: AppColors.acid)),
                    ],
                  ),
                ),
              ),
              if (d.likes.isNotEmpty) ...[
                const SizedBox(height: 26),
                _SectionHead(
                  label: 'recent likes',
                  onSeeAll: () => context.go('/library?tab=likes'),
                ),
                const SizedBox(height: 12),
                for (final t in d.likes) _TrackRow(track: t, liked: true),
              ],
              if (d.history.isNotEmpty) ...[
                const SizedBox(height: 26),
                const _SectionHead(label: 'listening history'),
                const SizedBox(height: 12),
                for (final t in d.history) _TrackRow(track: t),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// Заголовок секции: моно-лейбл слева + опциональный «see all →» справа.
class _SectionHead extends StatelessWidget {
  const _SectionHead({required this.label, this.onSeeAll});
  final String label;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label.toUpperCase(),
            style: AppTheme.mono(
              size: 10,
              color: AppColors.textLow,
              weight: FontWeight.w600,
              letterSpacing: 1.4,
            ),
          ),
        ),
        if (onSeeAll != null)
          Pressable(
            onTap: onSeeAll!,
            child: Text(
              'see all →',
              style: AppTheme.mono(
                size: 10,
                color: AppColors.acid,
                weight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.me, required this.authed});

  final Artist? me;
  final bool authed;

  @override
  Widget build(BuildContext context) {
    // Аноним → приглашение войти (без личной статистики).
    if (!authed) {
      return Pressable(
        onTap: () => showLoginDialog(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'browsing anonymously',
              style: AppTheme.mono(size: 12, color: AppColors.textMid),
            ),
            const SizedBox(height: 6),
            Text(
              'log in for your stream →',
              style: AppTheme.mono(
                size: 12,
                color: AppColors.acid,
                weight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }
    // Залогинен → профиль-карточка (тап → свой /artist). ◆ — лёгкий lime-акцент.
    final handle = me?.handle;
    return Pressable(
      onTap: handle == null
          ? null
          : () => context.go('/artist/${Uri.encodeComponent(handle)}'),
      child: Row(
        children: [
          CoverArt(
            seed: 'artist-${me?.handle ?? 'me'}',
            imageUrl: me?.avatarUrl,
            size: 46,
            circular: true,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        me?.name ?? 'you',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textHi,
                        ),
                      ),
                    ),
                    if (me?.verified ?? false) ...[
                      const SizedBox(width: 5),
                      const Icon(
                        Icons.verified,
                        size: 13,
                        color: AppColors.acid,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '@${me?.handle ?? 'me'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.mono(size: 11, color: AppColors.textMid),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            '◆',
            style: TextStyle(color: AppColors.lime, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

/// Три тайла-шортката с реальными счётчиками → вкладки library.
class _StatTiles extends StatelessWidget {
  const _StatTiles({required this.me});
  final Artist? me;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _StatTile(
          value: me?.likesCount ?? 0,
          label: 'likes',
          onTap: () => context.go('/library?tab=likes'),
        ),
        const SizedBox(width: 8),
        _StatTile(
          value: me?.playlistCount ?? 0,
          label: 'playlists',
          onTap: () => context.go('/library?tab=playlists'),
        ),
        const SizedBox(width: 8),
        _StatTile(
          value: me?.followingsCount ?? 0,
          label: 'following',
          onTap: () => context.go('/library?tab=following'),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.value,
    required this.label,
    required this.onTap,
  });
  final int value;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Pressable(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
          decoration: BoxDecoration(
            color: AppColors.bg,
            borderRadius: AppTheme.borderRadius,
            border: AppTheme.border(),
          ),
          child: Column(
            children: [
              Text(
                Fmt.count(value),
                style: AppTheme.mono(
                  size: 18,
                  color: AppColors.textHi,
                  weight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label.toUpperCase(),
                style: AppTheme.mono(
                  size: 9,
                  color: AppColors.textLow,
                  letterSpacing: 1.0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Компактная строка трека для рейла (likes/history). [liked] — акид-сердечко.
class _TrackRow extends StatelessWidget {
  const _TrackRow({required this.track, this.liked = false});
  final Track track;
  final bool liked;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: () => context.push('/track/${track.id}'),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            CoverArt(seed: track.id, imageUrl: track.coverUrl, size: 34),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textHi,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.mono(size: 10, color: AppColors.textLow),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              liked ? Icons.favorite : Icons.play_arrow,
              size: liked ? 12 : 13,
              color: liked ? AppColors.acid : AppColors.textLow,
            ),
          ],
        ),
      ),
    );
  }
}
