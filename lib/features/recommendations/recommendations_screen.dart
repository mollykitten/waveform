import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../../core/api/soundcloud_auth.dart';
import '../../core/recommendations/ai_config.dart';
import '../../core/recommendations/models.dart';
import '../../core/recommendations/providers.dart';
import '../../shared/widgets/track_row.dart';
import 'wave_controller.dart';
import 'wave_controls.dart';

class RecommendationsScreen extends ConsumerStatefulWidget {
  const RecommendationsScreen({super.key});
  @override
  ConsumerState<RecommendationsScreen> createState() =>
      _RecommendationsScreenState();
}

class _RecommendationsScreenState extends ConsumerState<RecommendationsScreen> {
  final _mood = TextEditingController();
  bool _starting = false;
  int _epoch = 0;
  String? _notice;

  @override
  void dispose() {
    _epoch++;
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
    final queue = result.items.map((item) => item.track).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.pagePad,
        AppTheme.topBarHeight + 24,
        AppTheme.pagePad,
        AppTheme.playerHeight + 32,
      ),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'my wave',
                style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700),
              ),
            ),
            TextButton(
              onPressed: () => context.push('/settings'),
              child: const Text('settings'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'a fresh queue from your likes and recent listening.',
          style: TextStyle(color: AppColors.textMid, height: 1.5),
        ),
        const SizedBox(height: 24),
        if (!settings.ready) const LinearProgressIndicator(),
        if (settings.ready &&
            settings.config.backend == AiBackend.chatGpt &&
            !settings.chatGptConnected) ...[
          WaveConnectionCard(
            connected: false,
            busy: settings.connecting,
            onConnect: () =>
                ref.read(aiSettingsProvider.notifier).connectChatGpt(),
            onDisconnect: null,
            message: settings.error?.message,
          ),
          const SizedBox(height: 20),
        ],
        if (settings.chatGptConnected && settings.error != null) ...[
          const SizedBox(height: 12),
          Text(
            settings.error == AiFailure.credentials
                ? 'ChatGPT access expired or was denied. reconnect to continue your wave.'
                : settings.error!.message,
            style: const TextStyle(color: AppColors.textMid),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: busy
                  ? null
                  : () =>
                        ref.read(aiSettingsProvider.notifier).connectChatGpt(),
              child: const Text('reconnect ChatGPT'),
            ),
          ),
        ],
        if (_available(settings)) ...[
          Text(
            settings.config.backend == AiBackend.chatGpt
                ? 'connected to ChatGPT'
                : 'using your custom provider',
            style: AppTheme.mono(size: 11, color: AppColors.textMid),
          ),
          const SizedBox(height: 16),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            key: const ValueKey('play-my-wave'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
              shape: const RoundedRectangleBorder(
                borderRadius: AppTheme.borderRadius,
              ),
            ),
            onPressed: _available(settings) && !busy ? _startWave : null,
            icon: const Icon(Icons.play_arrow, size: 20),
            label: const Text('play my wave'),
          ),
        ),
        const SizedBox(height: 8),
        WaveMoodField(controller: _mood, enabled: !busy),
        if (!authed)
          const Text(
            'sign in to SoundCloud to personalise your wave. '
            'you can still explore with a mood.',
            style: TextStyle(color: AppColors.textMid, fontSize: 12),
          ),
        if (_notice != null)
          Text(_notice!, style: const TextStyle(color: AppColors.textMid)),
        if (result.busy || settings.connecting) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          const Text(
            'finding your next tracks…',
            style: TextStyle(color: AppColors.textMid),
          ),
          if (result.busy || _starting)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _cancel,
                child: const Text('cancel discovery'),
              ),
            ),
        ],
        if (wave.active && !wave.discovering)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _cancel,
              child: const Text('stop my wave'),
            ),
          ),
        if (result.error != null) ...[
          const SizedBox(height: 16),
          Text(
            settings.config.backend == AiBackend.chatGpt &&
                    result.error == AiFailure.credentials
                ? 'ChatGPT access expired or was denied. reconnect to continue your wave.'
                : result.error!.message,
            style: const TextStyle(color: AppColors.textMid),
          ),
          if (settings.config.backend == AiBackend.chatGpt &&
              result.error == AiFailure.credentials)
            TextButton(
              onPressed: busy
                  ? null
                  : () =>
                        ref.read(aiSettingsProvider.notifier).connectChatGpt(),
              child: const Text('reconnect ChatGPT'),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: !busy && _available(settings) ? _startWave : null,
              child: const Text('try again'),
            ),
          ),
        ],
        if (queue.isNotEmpty) ...[
          const SizedBox(height: 28),
          Text(
            'picked for your wave',
            style: AppTheme.mono(size: 11, color: AppColors.textMid),
          ),
          const SizedBox(height: 12),
          for (final item in result.items) ...[
            TrackRow(track: item.track, queue: queue),
            Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 18),
              child: Text(
                'suggestion: ${item.reason}',
                style: const TextStyle(color: AppColors.textMid, fontSize: 12),
              ),
            ),
          ],
        ],
      ],
    );
  }
}
