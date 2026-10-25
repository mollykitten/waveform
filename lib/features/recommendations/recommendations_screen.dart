import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../../core/api/soundcloud_auth.dart';
import '../../core/recommendations/ai_client.dart';
import '../../core/recommendations/models.dart';
import '../../core/recommendations/providers.dart';
import '../../shared/widgets/pressable.dart';
import '../../shared/widgets/track_row.dart';
import '../player/player_controller.dart';
import 'widgets/wave_hero.dart';

class RecommendationsScreen extends ConsumerStatefulWidget {
  const RecommendationsScreen({super.key});
  @override
  ConsumerState<RecommendationsScreen> createState() =>
      _RecommendationsScreenState();
}

class _RecommendationsScreenState extends ConsumerState<RecommendationsScreen> {
  final _mood = TextEditingController(text: 'discover something new');
  bool _listening = false;
  bool _current = false;
  bool _confirming = false;
  bool _tuning = false;
  String? _inputError;
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

  @override
  void dispose() {
    _scroll.dispose();
    _mood.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    if (_confirming || ref.read(recommendationsProvider).busy) return;
    final settings = ref.read(aiSettingsProvider);
    if (!settings.ready || !settings.config.isValid) return;
    final track = _current ? ref.read(playerControllerProvider).track : null;
    final listening =
        _listening && ref.read(authControllerProvider).isAuthenticated;
    final mood = _mood.text;
    try {
      validatedMood(mood);
      if (mood.trim().isEmpty && track == null && !listening) {
        throw AiFailure.configuration;
      }
    } on AiFailure {
      setState(() {
        _tuning = true;
        _inputError =
            'describe a mood (up to 500 characters, '
            'without links), or select a track or listening metadata';
      });
      return;
    }
    setState(() {
      _confirming = true;
      _inputError = null;
    });
    final destination = settings.config.destination;
    final approved = await showDialog<bool>(
      context: context,
      barrierColor: AppColors.bg.withValues(alpha: .8),
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: AppTheme.borderRadius,
          side: const BorderSide(color: AppColors.border, width: .5),
        ),
        constraints: const BoxConstraints(maxWidth: 520),
        insetPadding: const EdgeInsets.all(24),
        titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        contentPadding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
        actionsPadding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        buttonPadding: EdgeInsets.zero,
        actionsAlignment: MainAxisAlignment.end,
        titleTextStyle: Theme.of(context).textTheme.titleMedium?.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: AppColors.textHi,
        ),
        contentTextStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
          fontSize: 12,
          height: 1.6,
          color: AppColors.textMid,
        ),
        title: const Text('approve this AI generation'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('destination for both model requests:'),
              SelectableText(destination, style: AppTheme.mono(size: 12)),
              Text('model: ${settings.config.model}'),
              const SizedBox(height: 12),
              const Text('data sent:'),
              const Text('• your mood / request text'),
              if (track != null)
                const Text('• current track: title, artist, genre and ID'),
              if (listening)
                const Text(
                  '• recent likes and listening history: title, '
                  'artist, genre and ID; at most 20 seed tracks in total',
                ),
              const Text(
                '• up to 40 public SoundCloud search candidates: '
                'title, artist, genre and ID',
              ),
              const SizedBox(height: 12),
              const Text(
                'two requests: plan up to 2 searches, then rank real '
                'results. search words also go to SoundCloud. no audio, '
                'descriptions, comments, links or SoundCloud credentials '
                'are sent to the model. your endpoint may retain metadata '
                'and charge for requests.',
              ),
            ],
          ),
        ),
        actions: [
          _ConsentAction(
            onTap: () => Navigator.pop(context, false),
            label: 'cancel',
          ),
          _ConsentAction(
            onTap: () => Navigator.pop(context, true),
            label: 'approve and generate',
            active: true,
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => _confirming = false);
    if (approved != true ||
        ref.read(aiSettingsProvider).revision != settings.revision) {
      return;
    }
    var approvedRevision = settings.revision;
    if (listening && !settings.config.listeningConsent) {
      approvedRevision++;
      await ref.read(aiSettingsProvider.notifier).setListeningConsent(true);
    }
    if (!mounted) return;
    final latest = ref.read(aiSettingsProvider);
    if (!latest.config.isValid ||
        latest.revision != approvedRevision ||
        latest.config.destination != destination ||
        (listening && !latest.config.listeningConsent)) {
      return;
    }
    await ref
        .read(recommendationsProvider.notifier)
        .generate(
          consent: AiConsent(destination: destination, listening: listening),
          mood: mood,
          useListening: listening,
          currentTrack: track,
        );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(aiSettingsProvider);
    final result = ref.watch(recommendationsProvider);
    final authed = ref.watch(authControllerProvider).isAuthenticated;
    final current = ref.watch(playerControllerProvider.select((p) => p.track));
    final configured = settings.ready && settings.config.isValid;
    final queue = result.items.map((item) => item.track).toList();
    final description = !settings.ready
        ? 'getting your wave ready…'
        : !configured
        ? 'a little connection, a whole new direction.'
        : result.busy
        ? 'selecting music… your current music keeps playing.'
        : queue.isNotEmpty
        ? 'your selection is ready. press play and drift.'
        : 'follow your mood. find your next favourite.';
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
                  description: description,
                  actionLabel: !configured
                      ? 'configure your wave'
                      : queue.isEmpty
                      ? 'start your wave'
                      : 'play your wave',
                  busy: result.busy,
                  enabled: settings.ready && !_confirming,
                  onPlay: () {
                    if (!configured) {
                      context.push('/settings');
                    } else if (queue.isNotEmpty) {
                      ref
                          .read(playerControllerProvider.notifier)
                          .play(queue.first, queue: queue);
                    } else {
                      _generate();
                    }
                  },
                  onTune: () => setState(() => _tuning = !_tuning),
                ),
                if (!configured && settings.ready)
                  Center(
                    child: WaveAction(
                      label: 'configure your wave',
                      icon: Icons.arrow_forward,
                      onTap: () => context.push('/settings'),
                    ),
                  ),
                if (_tuning) ...[
                  const SizedBox(height: 8),
                  _WaveTuning(
                    mood: _mood,
                    enabled: !result.busy && !_confirming,
                    listening: authed && _listening,
                    current: current != null && _current,
                    listeningEnabled: authed,
                    currentEnabled: current != null,
                    currentTitle: current?.title,
                    onListening: () => setState(() => _listening = !_listening),
                    onCurrent: () => setState(() => _current = !_current),
                  ),
                ],
                if (_inputError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _inputError!,
                      style: const TextStyle(
                        color: AppColors.textMid,
                        fontSize: 12,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                Center(
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (result.busy)
                        WaveAction(
                          label: 'cancel generation',
                          icon: Icons.close,
                          onTap: () => ref
                              .read(recommendationsProvider.notifier)
                              .cancel(),
                        )
                      else if (configured && queue.isNotEmpty)
                        WaveAction(
                          label: 'refresh selection',
                          icon: Icons.refresh,
                          enabled: !_confirming,
                          onTap: _generate,
                        ),
                      Pressable(
                        onTap: () => context.push('/settings'),
                        child: const Padding(
                          padding: EdgeInsets.all(10),
                          child: Text(
                            'model connection',
                            style: TextStyle(
                              color: AppColors.textMid,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (result.error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    result.error!.message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.textMid),
                  ),
                  const SizedBox(height: 10),
                  Center(
                    child: WaveAction(
                      label: 'retry with approval',
                      icon: Icons.refresh,
                      enabled: configured && !_confirming,
                      onTap: _generate,
                    ),
                  ),
                ],
                if (queue.isNotEmpty) ...[
                  const SizedBox(height: 32),
                  Row(
                    children: [
                      const Text(
                        'selected for your wave',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${queue.length} tracks',
                        style: AppTheme.mono(
                          size: 11,
                          color: AppColors.textMid,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'real SoundCloud tracks · reasons suggested by your model',
                    style: TextStyle(color: AppColors.textMid, fontSize: 11),
                  ),
                  const SizedBox(height: 16),
                  for (final item in result.items) ...[
                    TrackRow(track: item.track, queue: queue),
                    Padding(
                      padding: const EdgeInsets.only(left: 12, bottom: 18),
                      child: Text(
                        'model suggestion: ${item.reason}',
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

class _ConsentAction extends StatelessWidget {
  const _ConsentAction({
    required this.label,
    required this.onTap,
    this.active = false,
  });
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    child: Container(
      margin: const EdgeInsets.only(left: 8),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      decoration: BoxDecoration(
        color: active ? AppColors.acid : AppColors.surface2,
        borderRadius: AppTheme.borderRadius,
        border: Border.all(
          width: .5,
          color: active ? AppColors.acid : AppColors.border,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: active ? AppColors.bg : AppColors.textHi,
        ),
      ),
    ),
  );
}

class _WaveTuning extends StatelessWidget {
  static const _inputBorder = OutlineInputBorder(
    borderRadius: AppTheme.borderRadius,
    borderSide: AppTheme.borderSideStatic,
  );
  const _WaveTuning({
    required this.mood,
    required this.enabled,
    required this.listening,
    required this.current,
    required this.listeningEnabled,
    required this.currentEnabled,
    required this.currentTitle,
    required this.onListening,
    required this.onCurrent,
  });
  final TextEditingController mood;
  final bool enabled;
  final bool listening;
  final bool current;
  final bool listeningEnabled;
  final bool currentEnabled;
  final String? currentTitle;
  final VoidCallback onListening;
  final VoidCallback onCurrent;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: mood,
          enabled: enabled,
          maxLength: 500,
          minLines: 1,
          maxLines: 2,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            labelText: 'what would you like to hear?',
            hintText: 'a mood, an artist, a direction — without links',
            counterText: '',
            filled: true,
            fillColor: AppColors.bg,
            isDense: true,
            labelStyle: const TextStyle(fontSize: 12, color: AppColors.textMid),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
            ),
            border: _inputBorder,
            enabledBorder: _inputBorder,
            disabledBorder: _inputBorder,
            focusedBorder: _inputBorder.copyWith(
              borderSide: const BorderSide(
                color: AppColors.acid,
                width: AppTheme.borderWidth,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final preset in [
              'discover something new',
              'quiet evening',
              'focus without vocals',
              'late night energy',
            ])
              WaveAction(
                label: preset,
                enabled: enabled,
                onTap: () => mood.value = TextEditingValue(
                  text: preset,
                  selection: TextSelection.collapsed(offset: preset.length),
                ),
              ),
          ],
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            WaveAction(
              label: listening
                  ? 'listening history · on'
                  : 'listening history · off',
              icon: listening ? Icons.check : Icons.history,
              selected: listening,
              enabled: enabled && listeningEnabled,
              onTap: onListening,
            ),
            WaveAction(
              label: current ? 'current track · on' : 'current track · off',
              icon: current ? Icons.check : Icons.music_note_outlined,
              selected: current,
              enabled: enabled && currentEnabled,
              onTap: onCurrent,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          !listeningEnabled
              ? 'sign in to include likes and listening history.'
              : 'history includes recent likes; shared only with your approval.',
          style: const TextStyle(color: AppColors.textMid, fontSize: 11),
        ),
        if (currentEnabled)
          Text(
            'current track: $currentTitle',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.textMid, fontSize: 11),
          ),
      ],
    ),
  );
}
