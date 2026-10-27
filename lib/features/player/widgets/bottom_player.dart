import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../app/theme/colors.dart';
import '../../../shared/action_feedback.dart';
import '../../../shared/format.dart';
import '../../../shared/models/track.dart';
import '../../../shared/url_share.dart';
import '../../../shared/widgets/cover_art.dart';
import '../../../shared/widgets/pressable.dart';
import '../../../shared/widgets/toast.dart';
import '../../recommendations/wave_controller.dart';
import '../../../shared/widgets/live_waveform.dart';
import '../player_controller.dart';
import '../player_ui_state.dart';
import 'audio_output_picker.dart';

class BottomPlayer extends ConsumerWidget {
  const BottomPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerControllerProvider);
    final c = ref.read(playerControllerProvider.notifier);
    final track = player.track;
    final enabled = track != null;
    final collapsed = ref.watch(playerCollapsedProvider);

    if (collapsed) {
      return _CollapsedBar(
        track: track,
        enabled: enabled,
        isPlaying: player.isPlaying,
        position: player.position,
        onPlayPause: c.toggle,
        onNext: c.next,
        showDislike: ref.watch(currentTrackInWaveProvider),
        onDislike: () => _dislikeCurrent(context, ref),
        onExpand: () => ref.read(playerCollapsedProvider.notifier).expand(),
      );
    }

    return Container(
      height: AppTheme.playerHeight,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.72),
        border: const Border(top: AppTheme.borderSideStatic),
      ),
      child: Row(
        children: [
          // ── Контролы воспроизведения ───────────────────────────────────
          _IconBtn(
            icon: Icons.shuffle,
            active: player.shuffle,
            enabled: enabled,
            onTap: c.toggleShuffle,
          ),
          _IconBtn(
            icon: Icons.skip_previous,
            enabled: enabled,
            onTap: c.previous,
          ),
          _PlayButton(
            isPlaying: player.isPlaying,
            enabled: enabled,
            onTap: c.toggle,
          ),
          _IconBtn(icon: Icons.skip_next, enabled: enabled, onTap: c.next),
          _IconBtn(
            icon: Icons.repeat,
            active: player.repeat,
            enabled: enabled,
            onTap: c.toggleRepeat,
          ),
          const SizedBox(width: 18),

          if (track != null) ...[
            Pressable(
              onTap: () => context.push('/track/${track.id}'),
              child: CoverArt(
                seed: track.id,
                imageUrl: track.coverUrl,
                size: 44,
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 128,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
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
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textHi,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Pressable(
                    onTap: () => context.go(
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
            const SizedBox(width: 20),
            Text(Fmt.time(player.position), style: AppTheme.mono(size: 11)),
            const SizedBox(width: 12),
            Expanded(
              child: LiveWaveform(
                waveformUrl: track.waveformUrl,
                fallbackBars: track.waveform,
                progress: player.progress,
                buffered: player.bufferedFraction,
                onSeek: c.seekFraction,
                height: 36,
              ),
            ),
            const SizedBox(width: 12),
            Text(Fmt.time(track.duration), style: AppTheme.mono(size: 11)),
            const SizedBox(width: 18),
            if (ref.watch(currentTrackInWaveProvider))
              _IconBtn(
                icon: Icons.thumb_down_outlined,
                enabled: true,
                label: 'dislike, do not suggest again',
                onTap: () => _dislikeCurrent(context, ref),
              ),
            _IconBtn(
              icon: player.liked ? Icons.favorite : Icons.favorite_border,
              active: player.liked,
              enabled: true,
              onTap: () async {
                final outcome = await c.toggleLike();
                if (context.mounted) showLikeOutcome(context, outcome);
              },
            ),
            const _CopyLinkButton(),
            const AudioOutputPicker(),
            const SizedBox(width: 4),
            _Volume(
              volume: player.volume,
              muted: player.muted,
              onChanged: c.setVolume,
              onToggleMute: c.toggleMute,
            ),
            const SizedBox(width: 4),
            // Collapse → 44px-bar с минимальными контролами.
            _IconBtn(
              icon: Icons.expand_more,
              enabled: true,
              label: 'collapse player',
              onTap: () =>
                  ref.read(playerCollapsedProvider.notifier).collapse(),
            ),
          ] else ...[
            Expanded(
              child: Text(
                'select a track',
                style: AppTheme.mono(size: 12, color: AppColors.textLow),
              ),
            ),
            const AudioOutputPicker(),
          ],
        ],
      ),
    );
  }
}

/// Copies the playing track, independently of the current page's context link.
/// Dislike the wave track, skip it, and offer a short window to take it back.
Future<void> _dislikeCurrent(BuildContext context, WidgetRef ref) async {
  final wave = ref.read(waveControllerProvider.notifier);
  final track = await wave.dislikeCurrent();
  if (track == null || !context.mounted) return;
  showToast(
    context,
    "won't suggest this again",
    action: (label: 'undo', onTap: () => wave.undoDislike(track)),
  );
}

class _CopyLinkButton extends ConsumerWidget {
  const _CopyLinkButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = ref.watch(
      playerControllerProvider.select((state) => state.track?.permalinkUrl),
    );
    final enabled = url != null && url.trim().isNotEmpty;
    final shortcut = Theme.of(context).platform == TargetPlatform.macOS
        ? '⌘⇧C'
        : 'Ctrl+Shift+C';
    // Keep button activation local: the shell maps Space to play/pause.
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      child: IconButton(
        tooltip: 'copy link · $shortcut',
        icon: const Icon(Icons.link, size: 18, semanticLabel: 'Copy link'),
        style: IconButton.styleFrom(
          fixedSize: const Size(32, 32),
          minimumSize: const Size(32, 32),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: AppColors.textMid,
          disabledForegroundColor: AppColors.textLow,
        ),
        onPressed: !enabled
            ? null
            : () => copyToClipboard(
                context,
                url,
                message: 'link copied',
                ref: ref,
              ),
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({
    required this.icon,
    required this.enabled,
    required this.onTap,
    this.active = false,
    this.label,
  });

  final IconData icon;
  final bool enabled;
  final bool active;
  final VoidCallback onTap;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final color = !enabled
        ? AppColors.textLow
        : active
        ? AppColors.acid
        : AppColors.textMid;
    final iconButton = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7),
      child: Icon(icon, size: 18, color: color, semanticLabel: label),
    );
    if (label case final label?) {
      return Tooltip(
        message: label,
        child: Semantics(
          button: true,
          enabled: enabled,
          label: label,
          onTap: enabled ? onTap : null,
          child: ExcludeSemantics(
            child: Pressable(onTap: enabled ? onTap : null, child: iconButton),
          ),
        ),
      );
    }
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(onTap: enabled ? onTap : null, child: iconButton),
    );
  }
}

class _Volume extends StatelessWidget {
  const _Volume({
    required this.volume,
    required this.muted,
    required this.onChanged,
    required this.onToggleMute,
  });

  final double volume;
  final bool muted;
  final ValueChanged<double> onChanged;
  final VoidCallback onToggleMute;

  @override
  Widget build(BuildContext context) {
    final isMuted = muted || volume == 0;
    final icon = isMuted
        ? Icons.volume_off
        : volume < 0.5
        ? Icons.volume_down
        : Icons.volume_up;
    return Listener(
      onPointerSignal: (e) {
        // Scroll-wheel / trackpad-жест по громкости — нативно для macOS.
        if (e is PointerScrollEvent) {
          final delta = -e.scrollDelta.dy * 0.005; // вниз = тише
          onChanged((volume + delta).clamp(0.0, 1.0));
        }
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: isMuted ? 'muted' : '${(volume * 100).round()}%',
            child: _IconBtn(icon: icon, enabled: true, onTap: onToggleMute),
          ),
          SizedBox(
            width: 84,
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 2,
                activeTrackColor: AppColors.textMid,
                inactiveTrackColor: AppColors.border,
                thumbColor: AppColors.textHi,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 11),
              ),
              child: Slider(value: volume, onChanged: onChanged),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({
    required this.isPlaying,
    required this.enabled,
    required this.onTap,
  });

  final bool isPlaying;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      enabled: enabled,
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: enabled ? AppColors.acid : AppColors.surface2,
          shape: BoxShape.circle,
        ),
        child: Icon(
          isPlaying ? Icons.pause : Icons.play_arrow,
          color: enabled ? AppColors.bg : AppColors.textLow,
          size: 24,
        ),
      ),
    );
  }
}

/// Свёрнутый плеер: 44px-полоса с мини-обложкой, бегущим названием, play/next +
/// время + chevron-up. Полные контролы (shuffle/prev/repeat/wave/like/volume)
/// возвращаются по expand'у.
class _CollapsedBar extends ConsumerWidget {
  const _CollapsedBar({
    required this.track,
    required this.enabled,
    required this.isPlaying,
    required this.position,
    required this.onPlayPause,
    required this.onNext,
    required this.showDislike,
    required this.onDislike,
    required this.onExpand,
  });

  final Track? track;
  final bool enabled;
  final bool isPlaying;
  final Duration position;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;
  final bool showDislike;
  final VoidCallback onDislike;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.72),
        border: const Border(top: AppTheme.borderSideStatic),
      ),
      child: Row(
        children: [
          if (track != null) ...[
            Pressable(
              onTap: () => context.push('/track/${track!.id}'),
              child: CoverArt(
                seed: track!.id,
                imageUrl: track!.coverUrl,
                size: 28,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Pressable(
                onTap: () => context.push('/track/${track!.id}'),
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        '${track!.artist} — ${track!.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.mono(
                          size: 11,
                          color: AppColors.textHi,
                          weight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Text(Fmt.time(position), style: AppTheme.mono(size: 11)),
          ] else
            Expanded(
              child: Text(
                'select a track',
                style: AppTheme.mono(size: 11, color: AppColors.textLow),
              ),
            ),
          const SizedBox(width: 8),
          _IconBtn(
            icon: isPlaying ? Icons.pause : Icons.play_arrow,
            enabled: enabled,
            onTap: onPlayPause,
          ),
          if (showDislike)
            _IconBtn(
              icon: Icons.thumb_down_outlined,
              enabled: true,
              label: 'dislike, do not suggest again',
              onTap: onDislike,
            ),
          _IconBtn(icon: Icons.skip_next, enabled: enabled, onTap: onNext),
          const _CopyLinkButton(),
          const AudioOutputPicker(compact: true),
          _IconBtn(
            icon: Icons.expand_less,
            enabled: true,
            label: 'expand player',
            onTap: onExpand,
          ),
        ],
      ),
    );
  }
}
