import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../../core/api/soundcloud_auth.dart';
import '../../core/recommendations/providers.dart';
import '../../shared/widgets/track_row.dart';
import 'wave_controller.dart';
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
    final queue = result.items.map((item) => item.track).toList();
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
                  description: !authed
                      ? 'sign in to SoundCloud to start your wave.'
                      : busy
                      ? 'finding your next tracks…'
                      : wave.active
                      ? 'your wave keeps playing. follow where it goes.'
                      : 'a fresh queue from your likes and recent listening.',
                  actionLabel: 'play my wave',
                  busy: busy,
                  enabled: authed && !busy,
                  onPlay: _startWave,
                ),
                if (result.busy) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  const Text(
                    'finding your next tracks…',
                    style: TextStyle(color: AppColors.textMid),
                  ),
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
                    result.error!.message,
                    style: const TextStyle(color: AppColors.textMid),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: !busy && authed ? _startWave : null,
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
                        item.reason,
                        style: const TextStyle(
                          color: AppColors.textMid,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
