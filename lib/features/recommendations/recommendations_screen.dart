import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../../core/api/soundcloud_auth.dart';
import '../auth/login_dialog.dart';
import '../../core/recommendations/ai_config.dart';
import '../../core/recommendations/models.dart';
import '../../core/recommendations/providers.dart';
import '../../shared/models/track.dart';
import '../player/player_controller.dart';
import '../../shared/widgets/form_controls.dart';
import '../../shared/widgets/track_row.dart';
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
    final railBusy = result.busy || settings.connecting;
    final reconnect =
        settings.config.backend == AiBackend.chatGpt &&
        result.error == AiFailure.credentials;
    final errorText = result.error == null
        ? ''
        : reconnect
        ? 'ChatGPT access expired or was denied. reconnect to continue your wave.'
        : result.error!.message;
    final tune = FormAction(
      label: 'tune your wave',
      icon: Icons.tune,
      kind: FormActionKind.quiet,
      selected: _tuning,
      onTap: () => setState(() => _tuning = !_tuning),
    );
    final stopWave = queue.isEmpty && wave.active && !wave.discovering
        ? FormAction(
            label: 'stop my wave',
            kind: FormActionKind.quiet,
            onTap: _cancel,
          )
        : null;
    final cancel = FormAction(
      label: 'cancel',
      kind: FormActionKind.quiet,
      onTap: _cancel,
    );
    final List<Widget> actions;
    if (railBusy) {
      actions = [if (result.busy || _starting) cancel];
    } else if (result.error != null && !busy) {
      actions = [
        if (reconnect)
          FormAction(
            label: 'reconnect ChatGPT',
            onTap: () => ref.read(aiSettingsProvider.notifier).connectChatGpt(),
          )
        else
          FormAction(
            label: 'try again',
            icon: Icons.refresh,
            onTap: _available(settings) ? _startWave : null,
          ),
        tune,
        ?stopWave,
      ];
    } else if (!authed && !busy) {
      actions = [
        FormAction(
          label: 'sign in to SoundCloud',
          onTap: () => showLoginDialog(context),
        ),
        tune,
        ?stopWave,
      ];
    } else {
      actions = [tune, ?stopWave, if (_starting) cancel];
    }
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
                      : busy
                      ? 'finding your next tracks…'
                      : result.error != null
                      ? errorText
                      : !_available(settings)
                      ? 'connect ChatGPT to start your wave.'
                      : !authed
                      ? 'sign in to SoundCloud to build your wave from your likes. a mood works without it.'
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
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 584),
                      child: Column(
                        key: const ValueKey('wave-toolbar'),
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          if (railBusy) ...[
                            const SizedBox(
                              width: 240,
                              child: WaveProgressRail(),
                            ),
                            const SizedBox(height: 8),
                          ],
                          if (actions.isNotEmpty)
                            Wrap(
                              key: const ValueKey('wave-toolbar-actions'),
                              alignment: WrapAlignment.center,
                              spacing: 8,
                              runSpacing: 8,
                              children: actions,
                            ),
                          if (settings.ready &&
                              settings.config.backend == AiBackend.chatGpt &&
                              !settings.chatGptConnected) ...[
                            const SizedBox(height: 8),
                            FormAction(
                              label: 'continue with ChatGPT',
                              busy: settings.connecting,
                              busyLabel: 'connecting…',
                              onTap: () => ref
                                  .read(aiSettingsProvider.notifier)
                                  .connectChatGpt(),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'an eligible ChatGPT subscription is required; availability depends on your account.',
                              style: formTextStyle,
                              textAlign: TextAlign.center,
                            ),
                          ],
                          if (_tuning && !railBusy) ...[
                            const SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              child: WaveMoodField(
                                controller: _mood,
                                enabled: !busy,
                                expanded: true,
                              ),
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
                            Text(
                              _notice!,
                              style: formTextStyle,
                              textAlign: TextAlign.center,
                            ),
                          ],
                          if (settings.error != null &&
                              result.error == null) ...[
                            const SizedBox(height: 8),
                            Text(
                              settings.chatGptConnected &&
                                      settings.error == AiFailure.credentials
                                  ? 'ChatGPT access expired or was denied. reconnect to continue your wave.'
                                  : settings.error!.message,
                              style: formTextStyle,
                              textAlign: TextAlign.center,
                            ),
                            if (settings.chatGptConnected) ...[
                              const SizedBox(height: 8),
                              FormAction(
                                label: 'reconnect ChatGPT',
                                onTap: busy
                                    ? null
                                    : () => ref
                                          .read(aiSettingsProvider.notifier)
                                          .connectChatGpt(),
                              ),
                            ],
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
  Widget build(BuildContext context) {
    final row = TrackRow(track: track, queue: queue);
    // The reason stays one hover away so the list reads as plain tracks.
    return KeyedSubtree(
      key: ValueKey('wave-row-${track.id}'),
      child: reason == null
          ? row
          : Tooltip(
              message: reason!,
              waitDuration: const Duration(milliseconds: 700),
              child: row,
            ),
    );
  }
}
