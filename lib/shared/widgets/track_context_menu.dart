import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../../core/api/liked_tracks.dart';
import '../../core/api/reposted_tracks.dart';
import '../../features/player/player_controller.dart';
import '../action_feedback.dart';
import '../models/track.dart';
import '../url_share.dart';

/// Контекстное меню (right-click) на трек-строке. Использует `showMenu` с
/// якорем по `globalPosition` события. Действия зависят от текущего состояния
/// (играем ли мы трек, лайкнут ли, есть ли permalinkUrl).
Future<void> showTrackContextMenu({
  required BuildContext context,
  required WidgetRef ref,
  required Track track,
  required List<Track>? queue,
  required Offset globalPosition,
}) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (overlay == null) return;

  final player = ref.read(playerControllerProvider);
  final pc = ref.read(playerControllerProvider.notifier);
  final liked = ref.read(likedTracksProvider).contains(track.id);
  final reposted = ref.read(repostedTracksProvider).contains(track.id);
  final isCurrent = player.track?.id == track.id;
  final hasLink = track.permalinkUrl != null && track.permalinkUrl!.isNotEmpty;

  Future<T?> show<T>(List<PopupMenuEntry<T>> items) => showMenu<T>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
      Offset.zero & overlay.size,
    ),
    color: AppColors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: AppTheme.borderRadius,
      side: const BorderSide(
        color: AppColors.border,
        width: AppTheme.borderWidth,
      ),
    ),
    items: items,
  );

  PopupMenuItem<String> item(
    String value,
    IconData icon,
    String label, {
    bool danger = false,
  }) => PopupMenuItem<String>(
    value: value,
    height: 36,
    child: Row(
      children: [
        Icon(
          icon,
          size: 14,
          color: danger ? AppColors.acid : AppColors.textMid,
        ),
        const SizedBox(width: 10),
        Text(
          label,
          style: AppTheme.mono(
            size: 12,
            color: danger ? AppColors.acid : AppColors.textHi,
          ),
        ),
      ],
    ),
  );

  final selected = await show<String>([
    item(
      isCurrent ? 'toggle' : 'play',
      isCurrent && player.isPlaying ? Icons.pause : Icons.play_arrow,
      isCurrent ? (player.isPlaying ? 'pause' : 'resume') : 'play',
    ),
    item('playnext', Icons.playlist_play, 'play next'),
    const PopupMenuDivider(),
    item(
      'like',
      liked ? Icons.favorite : Icons.favorite_border,
      liked ? 'unlike' : 'like',
    ),
    item('repost', Icons.repeat, reposted ? 'unrepost' : 'repost'),
    if (hasLink) ...[
      const PopupMenuDivider(),
      item('copy', Icons.link, 'copy link'),
      item('open_sc', Icons.open_in_new, 'open on soundcloud ↗'),
    ],
    const PopupMenuDivider(),
    item('artist', Icons.person_outline, 'open artist'),
    item('track', Icons.music_note, 'open track page'),
  ]);

  if (selected == null) return;
  switch (selected) {
    case 'play':
      pc.play(track, queue: queue);
    case 'toggle':
      pc.toggle();
    case 'playnext':
      pc.playNext(track);
    case 'like':
      final outcome = await ref
          .read(likedTracksProvider.notifier)
          .toggle(track);
      if (context.mounted) showWriteOutcome(context, outcome, verb: 'like');
    case 'repost':
      final outcome = await ref
          .read(repostedTracksProvider.notifier)
          .toggle(track.id);
      if (context.mounted) {
        showWriteOutcome(context, outcome, verb: 'repost');
      }
    case 'copy':
      if (context.mounted) await copyToClipboard(context, track.permalinkUrl!, ref: ref);
    case 'open_sc':
      await openExternalUrl(track.permalinkUrl!);
    case 'artist':
      if (context.mounted) {
        context.push('/artist/${Uri.encodeComponent(track.artistHandle)}');
      }
    case 'track':
      if (context.mounted) context.push('/track/${track.id}');
  }
}
