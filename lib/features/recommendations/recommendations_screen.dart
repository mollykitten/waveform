import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../../core/api/soundcloud_auth.dart';
import '../../core/recommendations/ai_config.dart';
import '../../core/recommendations/models.dart';
import '../../core/recommendations/providers.dart';
import '../../shared/widgets/cover_art.dart';
import '../../shared/widgets/pressable.dart';
import '../../shared/widgets/track_context_menu.dart';
import '../../shared/models/track.dart';
import '../../shared/format.dart';
import '../player/player_controller.dart';
import 'package:flutter/gestures.dart';
import '../../shared/widgets/form_controls.dart';
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
  final _mood = TextEditingController();
  bool _starting = false;
  bool _tuning = false;
  final _scroll = ScrollController();
  bool _heroVisible = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_visibilityChanged);
  }

  void _visibilityChanged() {
    final visible = _scroll.offset < AppTheme.topBarHeight + 424;
    if (visible != _heroVisible) setState(() => _heroVisible = visible);
  }

  int _epoch = 0;
  String? _notice;

  @override
  void dispose() {
    _epoch++;
    _scroll.dispose();
    _mood.dispose();
    super.dispose();
  }

  bool _available(AiSettingsState settings) =>
      settings.ready &&
      settings.config.isValid &&
      (settings.config.backend != AiBackend.chatGpt ||
          settings.chatGptConnected);

  Future<void> _startWave() async {
    if (_starting || ref.read(recommendationsProvider).busy) return;
    final settings = ref.read(aiSettingsProvider);
    if (!_available(settings)) return;
    final mood = _mood.text;
    try {
      validatedMood(mood);
    } on AiFailure {
      setState(
        () => _notice = 'keep your mood under 500 characters, without links',
      );
      return;
    }
    final epoch = ++_epoch;
    setState(() {
      _starting = true;
      _notice = null;
    });
    try {
      var revision = settings.revision;
      if (!settings.config.listeningConsent) {
        final approved = await showWaveListeningConsent(
          context,
          destination: settings.config.backend == AiBackend.chatGpt
              ? 'ChatGPT'
              : settings.config.destination,
        );
        if (!mounted ||
            epoch != _epoch ||
            !approved ||
            ref.read(aiSettingsProvider).revision != revision) {
          return;
        }
        await ref.read(aiSettingsProvider.notifier).setListeningConsent(true);
        revision++;
      }
      if (!mounted ||
          epoch != _epoch ||
          ref.read(aiSettingsProvider).revision != revision) {
        return;
      }
      await ref.read(waveControllerProvider.notifier).start(mood);
    } on AiFailure catch (failure) {
      if (mounted && epoch == _epoch) setState(() => _notice = failure.message);
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
    final settings = ref.watch(aiSettingsProvider);
    final result = ref.watch(recommendationsProvider);
    final authed = ref.watch(authControllerProvider).isAuthenticated;
    final wave = ref.watch(waveControllerProvider);
    final busy =
        _starting || wave.discovering || result.busy || settings.connecting;
    final playback = ref.watch(
      playerControllerProvider.select(
        (state) => (
          track: state.track,
          playing: state.isPlaying,
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
                  description: !settings.ready
                      ? 'getting your wave ready…'
                      : !_available(settings)
                      ? 'connect ChatGPT to start your wave.'
                      : busy
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
                  enabled: ownsPlayback || _available(settings) && !busy,
                  onPlay: ownsPlayback ? player.toggle : _startWave,
                ),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 584),
                    child: Container(
                      key: const ValueKey('wave-toolbar'),
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
                          WaveControlRow(
                            information: Text(
                              !settings.ready
                                  ? 'getting your wave ready…'
                                  : busy
                                  ? 'finding your next tracks…'
                                  : _available(settings)
                                  ? settings.config.backend == AiBackend.chatGpt
                                        ? 'connected to ChatGPT'
                                        : 'using your custom provider'
                                  : 'connect ChatGPT to start your wave.',
                              style: formTextStyle,
                            ),
                            actions: Wrap(
                              key: const ValueKey('wave-toolbar-actions'),
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                FormAction(
                                  label: 'tune your wave',
                                  icon: Icons.tune,
                                  selected: _tuning,
                                  onTap: () =>
                                      setState(() => _tuning = !_tuning),
                                ),
                                FormAction(
                                  label: 'model connection',
                                  kind: FormActionKind.quiet,
                                  onTap: () => context.push('/settings'),
                                ),
                                if (queue.isEmpty &&
                                    wave.active &&
                                    !wave.discovering)
                                  FormAction(
                                    label: 'stop my wave',
                                    kind: FormActionKind.quiet,
                                    onTap: _cancel,
                                  ),
                              ],
                            ),
                          ),
                          if (!settings.ready) ...[
                            const SizedBox(height: 12),
                            const LinearProgressIndicator(),
                          ],
                          if (settings.ready &&
                              settings.config.backend == AiBackend.chatGpt &&
                              !settings.chatGptConnected) ...[
                            const SizedBox(height: 12),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: FormAction(
                                label: 'continue with ChatGPT',
                                kind: FormActionKind.primary,
                                busy: settings.connecting,
                                busyLabel: 'connecting…',
                                onTap: () => ref
                                    .read(aiSettingsProvider.notifier)
                                    .connectChatGpt(),
                              ),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'an eligible ChatGPT subscription is required; availability depends on your account.',
                              style: formTextStyle,
                            ),
                          ],
                          if (_tuning) ...[
                            const SizedBox(height: 12),
                            WaveMoodField(
                              controller: _mood,
                              enabled: !busy,
                              expanded: true,
                            ),
                            if (wave.active) ...[
                              const SizedBox(height: 8),
                              Align(
                                alignment: Alignment.centerRight,
                                child: FormAction(
                                  label: 'apply mood',
                                  onTap: !busy && _available(settings)
                                      ? _startWave
                                      : null,
                                ),
                              ),
                            ],
                          ],
                          if (_notice != null) ...[
                            const SizedBox(height: 8),
                            Text(_notice!, style: formTextStyle),
                          ],
                          if (!authed) ...[
                            const SizedBox(height: 12),
                            const Text(
                              'sign in to SoundCloud to personalise your wave. you can still explore with a mood.',
                              style: formTextStyle,
                            ),
                          ],
                          if (settings.error != null &&
                              result.error == null) ...[
                            const SizedBox(height: 12),
                            Text(
                              settings.chatGptConnected &&
                                      settings.error == AiFailure.credentials
                                  ? 'ChatGPT access expired or was denied. reconnect to continue your wave.'
                                  : settings.error!.message,
                              style: formTextStyle,
                            ),
                            if (settings.chatGptConnected) ...[
                              const SizedBox(height: 8),
                              Align(
                                alignment: Alignment.centerRight,
                                child: FormAction(
                                  label: 'reconnect ChatGPT',
                                  onTap: busy
                                      ? null
                                      : () => ref
                                            .read(aiSettingsProvider.notifier)
                                            .connectChatGpt(),
                                ),
                              ),
                            ],
                          ],
                          if (result.busy || settings.connecting) ...[
                            const SizedBox(height: 12),
                            const LinearProgressIndicator(),
                            if (result.busy || _starting) ...[
                              const SizedBox(height: 8),
                              Align(
                                alignment: Alignment.centerRight,
                                child: FormAction(
                                  label: 'cancel discovery',
                                  kind: FormActionKind.quiet,
                                  onTap: _cancel,
                                ),
                              ),
                            ],
                          ],
                          if (result.error != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              settings.config.backend == AiBackend.chatGpt &&
                                      result.error == AiFailure.credentials
                                  ? 'ChatGPT access expired or was denied. reconnect to continue your wave.'
                                  : result.error!.message,
                              style: formTextStyle,
                            ),
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerRight,
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  if (settings.config.backend ==
                                          AiBackend.chatGpt &&
                                      result.error == AiFailure.credentials)
                                    FormAction(
                                      label: 'reconnect ChatGPT',
                                      onTap: busy
                                          ? null
                                          : () => ref
                                                .read(
                                                  aiSettingsProvider.notifier,
                                                )
                                                .connectChatGpt(),
                                    ),
                                  FormAction(
                                    label: 'try again',
                                    onTap: !busy && _available(settings)
                                        ? _startWave
                                        : null,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
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

/// A compact queue row with the same playback, navigation and context actions.
class WaveQueueRow extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(
      playerControllerProvider.select(
        (state) => (id: state.track?.id, playing: state.isPlaying),
      ),
    );
    final current = playback.id == track.id;
    final player = ref.read(playerControllerProvider.notifier);
    return Listener(
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
        key: ValueKey('wave-row-${track.id}'),
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: current ? AppColors.surface2 : Colors.transparent,
          borderRadius: AppTheme.borderRadius,
        ),
        child: Row(
          children: [
            Semantics(
              label: current && playback.playing
                  ? 'pause ${track.title}'
                  : 'play ${track.title}',
              child: Pressable(
                onTap: () => current
                    ? player.toggle()
                    : player.play(track, queue: queue),
                child: SizedBox(
                  width: 32,
                  height: 36,
                  child: Icon(
                    current && playback.playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    size: 20,
                    color: current ? AppColors.acid : AppColors.textMid,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Pressable(
              onTap: () => context.push('/track/${track.id}'),
              child: CoverArt(
                seed: track.id,
                imageUrl: track.coverUrl,
                size: 40,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Pressable(
                    onTap: () => context.push('/track/${track.id}'),
                    child: Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textHi,
                      ),
                    ),
                  ),
                  Pressable(
                    onTap: () => context.push(
                      '/artist/${Uri.encodeComponent(track.artistHandle)}',
                    ),
                    child: Text(
                      track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: formTextStyle,
                    ),
                  ),
                  if (reason != null)
                    Tooltip(
                      message: reason!,
                      child: Text(
                        reason!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: formTextStyle,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              Fmt.time(track.duration),
              style: AppTheme.mono(size: 11, color: AppColors.textMid),
            ),
          ],
        ),
      ),
    );
  }
}
