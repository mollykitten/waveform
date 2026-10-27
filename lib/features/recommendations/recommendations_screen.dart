import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../../core/api/soundcloud_auth.dart';
import '../../core/recommendations/models.dart';
import '../../core/recommendations/providers.dart';
import '../../shared/models/track.dart';
import '../../shared/widgets/form_controls.dart';
import '../../shared/widgets/track_row.dart';
import '../player/player_controller.dart';
import 'wave_controller.dart';
import 'wave_controls.dart';
import 'widgets/wave_hero.dart';

class RecommendationsScreen extends ConsumerStatefulWidget {
  const RecommendationsScreen({super.key});
  @override
  ConsumerState<RecommendationsScreen> createState() =>
      _RecommendationsScreenState();
}

class _RecommendationsScreenState extends ConsumerState<RecommendationsScreen> {
  bool _starting = false;
  final _scroll = ScrollController();
  bool _heroVisible = true;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_visibilityChanged);
  }

  void _visibilityChanged() {
    final visible = _scroll.offset < AppTheme.topBarHeight + 424;
    if (visible != _heroVisible) setState(() => _heroVisible = visible);
  }

  @override
  void dispose() {
    _epoch++;
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _startWave() async {
    if (_starting || ref.read(recommendationsProvider).busy) return;
    if (!ref.read(authControllerProvider).isAuthenticated) return;
    final epoch = ++_epoch;
    setState(() => _starting = true);
    try {
      await ref.read(waveControllerProvider.notifier).start();
    } finally {
      if (mounted && epoch == _epoch) setState(() => _starting = false);
    }
  }

  void _cancel() {
    _epoch++;
    ref.read(waveControllerProvider.notifier).cancel();
    setState(() => _starting = false);
  }

  @override
  Widget build(BuildContext context) {
    final result = ref.watch(recommendationsProvider);
    final authed = ref.watch(authControllerProvider).isAuthenticated;
    final wave = ref.watch(waveControllerProvider);
    final busy = _starting || wave.discovering || result.busy;
    final playback = ref.watch(
      playerControllerProvider.select(
        (state) => (
          track: state.track,
          playing: state.isPlaying,
          shuffle: state.shuffle,
          queueVersion: state.queueVersion,
        ),
      ),
    );
    final player = ref.read(playerControllerProvider.notifier);
    final ownsPlayback =
        wave.active &&
        playback.track != null &&
        result.items.any((item) => item.track.id == playback.track!.id);
    final queue = ownsPlayback
        ? [playback.track!, ...player.upcomingTracks]
        : result.items.map((item) => item.track).toList();
    final reasons = {
      for (final item in result.items) item.track.id: item.reason,
    };
    final sameReason =
        queue.isNotEmpty &&
            queue.every(
              (track) =>
                  reasons[track.id] != null &&
                  reasons[track.id] == reasons[queue.first.id],
            )
        ? reasons[queue.first.id]
        : null;
    final showStatus =
        !authed ||
        busy ||
        result.error != null ||
        (queue.isEmpty && wave.active);
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(
        AppTheme.pagePad,
        AppTheme.topBarHeight + 24,
        AppTheme.pagePad,
        AppTheme.playerHeight + 32,
      ),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 880),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                WaveHero(
                  active: _heroVisible,
                  description: busy
                      ? 'finding your next tracks…'
                      : wave.active
                      ? 'your wave keeps playing. follow where it goes.'
                      : 'a fresh queue from your likes and recent listening.',
                  actionLabel: ownsPlayback
                      ? playback.playing
                            ? 'pause my wave'
                            : 'resume my wave'
                      : 'play my wave',
                  playing: ownsPlayback && playback.playing,
                  energyEnabled: ownsPlayback,
                  busy: !ownsPlayback && busy,
                  enabled: ownsPlayback || authed && !busy,
                  onPlay: ownsPlayback ? player.toggle : _startWave,
                ),
                if (showStatus)
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 584),
                      child: _WaveStatus(
                        key: const ValueKey('wave-toolbar'),
                        authed: authed,
                        busy: busy,
                        failure: result.error,
                        cancellable: result.busy || _starting,
                        stoppable: queue.isEmpty && wave.active && !busy,
                        onCancel: _cancel,
                        onRetry: !busy && authed ? _startWave : null,
                      ),
                    ),
                  ),
                if (queue.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  WaveControlRow(
                    information: Text(
                      ownsPlayback
                          ? 'playing next in your wave'
                          : 'picked for your wave',
                      style: AppTheme.mono(size: 11, color: AppColors.textMid),
                    ),
                    actions: wave.active && !wave.discovering
                        ? FormAction(
                            label: 'stop my wave',
                            kind: FormActionKind.quiet,
                            onTap: _cancel,
                          )
                        : null,
                  ),
                  const SizedBox(height: 12),
                  if (sameReason != null) ...[
                    Text(sameReason, style: formTextStyle),
                    const SizedBox(height: 8),
                  ],
                  for (final track in queue)
                    WaveQueueRow(
                      track: track,
                      queue: queue,
                      reason: sameReason == null ? reasons[track.id] : null,
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A quiet card shown only when there is something to say: a sign-in hint,
/// progress, or a failure with a retry.
class _WaveStatus extends StatelessWidget {
  const _WaveStatus({
    super.key,
    required this.authed,
    required this.busy,
    required this.failure,
    required this.cancellable,
    required this.stoppable,
    required this.onCancel,
    required this.onRetry,
  });
  final bool authed;
  final bool busy;
  final WaveFailure? failure;
  final bool cancellable;
  final bool stoppable;
  final VoidCallback onCancel;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: AppTheme.borderRadius,
      border: AppTheme.border(),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!authed)
          const Text(
            'sign in to SoundCloud to personalise your wave.',
            style: formTextStyle,
          ),
        if (busy) ...[
          const LinearProgressIndicator(),
          if (cancellable) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FormAction(
                label: 'cancel discovery',
                kind: FormActionKind.quiet,
                onTap: onCancel,
              ),
            ),
          ],
        ],
        if (failure != null) ...[
          Text(failure!.message, style: formTextStyle),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FormAction(label: 'try again', onTap: onRetry),
          ),
        ],
        if (stoppable && failure == null)
          Align(
            alignment: Alignment.centerRight,
            child: FormAction(
              label: 'stop my wave',
              kind: FormActionKind.quiet,
              onTap: onCancel,
            ),
          ),
      ],
    ),
  );
}

/// Standard track controls with optional individual recommendation context.
class WaveQueueRow extends StatelessWidget {
  const WaveQueueRow({
    super.key,
    required this.track,
    required this.queue,
    this.reason,
  });
  final Track track;
  final List<Track> queue;
  final String? reason;

  @override
  Widget build(BuildContext context) => Column(
    key: ValueKey('wave-row-${track.id}'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TrackRow(track: track, queue: queue),
      if (reason != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Tooltip(
            message: reason!,
            child: Text(
              reason!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: formTextStyle,
            ),
          ),
        ),
    ],
  );
}
