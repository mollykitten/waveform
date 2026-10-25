import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../../core/api/soundcloud_auth.dart';
import '../../core/recommendations/ai_client.dart';
import '../../core/recommendations/models.dart';
import '../../core/recommendations/providers.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/track_row.dart';
import '../player/player_controller.dart';

class RecommendationsScreen extends ConsumerStatefulWidget {
  const RecommendationsScreen({super.key});
  @override
  ConsumerState<RecommendationsScreen> createState() =>
      _RecommendationsScreenState();
}

class _RecommendationsScreenState extends ConsumerState<RecommendationsScreen> {
  final _mood = TextEditingController();
  bool _listening = false;
  bool _current = false;
  bool _confirming = false;
  String? _inputError;

  @override
  void dispose() {
    _mood.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    if (_confirming) return;
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
      setState(
        () => _inputError =
            'describe a mood (up to 500 characters, '
            'without links), or select a track or listening metadata',
      );
      return;
    }
    setState(() {
      _confirming = true;
      _inputError = null;
    });
    final destination = settings.config.destination;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
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
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('approve and generate'),
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
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.pagePad,
        AppTheme.topBarHeight + 24,
        AppTheme.pagePad,
        AppTheme.playerHeight + 32,
      ),
      children: [
        const Text(
          'ai recommendations',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        const Text(
          'your model suggests music; every result is a real '
          'SoundCloud track. reasons are model suggestions, not audio analysis.',
        ),
        TextButton(
          onPressed: () => context.push('/settings'),
          child: const Text('configure AI endpoint and model'),
        ),
        if (!settings.ready) const LinearProgressIndicator(),
        if (settings.ready && !configured)
          const EmptyState(
            compact: true,
            icon: Icons.tune,
            title: 'configure your model first',
            subtitle:
                'use an OpenAI-compatible endpoint or your own Ollama. '
                'no model server starts automatically.',
          ),
        TextField(
          controller: _mood,
          maxLength: 500,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'what would you like to hear?',
            hintText:
                'a mood, an artist, or something to explore — without links',
          ),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('include recent likes and listening history'),
          subtitle: Text(
            authed
                ? 'optional; up to 20 seed tracks, approved below'
                : 'sign in to SoundCloud to use listening metadata',
          ),
          value: authed && _listening,
          onChanged: !authed || result.busy
              ? null
              : (value) => setState(() => _listening = value ?? false),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('include the currently playing track'),
          subtitle: Text(
            current == null ? 'no current track' : current.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          value: current != null && _current,
          onChanged: current == null || result.busy
              ? null
              : (value) => setState(() => _current = value ?? false),
        ),
        if (_inputError != null) Text(_inputError!),
        Wrap(
          spacing: 12,
          children: [
            FilledButton(
              onPressed: configured && !result.busy && !_confirming
                  ? _generate
                  : null,
              child: Text(
                result.items.isEmpty
                    ? 'generate recommendations'
                    : 'generate again',
              ),
            ),
            if (result.busy)
              TextButton(
                onPressed: () =>
                    ref.read(recommendationsProvider.notifier).cancel(),
                child: const Text('cancel generation'),
              ),
          ],
        ),
        if (result.busy) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
          const Text(
            'planning, searching SoundCloud and ranking… '
            'previous results stay available',
          ),
        ],
        if (result.error != null) ...[
          const SizedBox(height: 16),
          Text(
            result.error!.message,
            style: const TextStyle(color: AppColors.textMid),
          ),
          TextButton(
            onPressed: configured && !_confirming ? _generate : null,
            child: const Text('retry with approval'),
          ),
        ],
        if (configured &&
            result.items.isEmpty &&
            !result.busy &&
            result.error == null)
          const EmptyState(
            compact: true,
            icon: Icons.auto_awesome_outlined,
            title: 'ready to discover',
            subtitle:
                'describe what you want and generate. metadata is sent '
                'only after you approve the destination.',
          ),
        const SizedBox(height: 20),
        for (final item in result.items) ...[
          TrackRow(track: item.track, queue: queue),
          Padding(
            padding: const EdgeInsets.only(left: 12, bottom: 18),
            child: Text(
              'model suggestion: ${item.reason}',
              style: const TextStyle(color: AppColors.textMid, fontSize: 12),
            ),
          ),
        ],
      ],
    );
  }
}
