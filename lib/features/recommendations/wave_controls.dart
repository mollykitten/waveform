import 'package:flutter/material.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';

/// Small, provider-independent controls shared by the wave screen and settings.
class WaveConnectionCard extends StatelessWidget {
  const WaveConnectionCard({
    super.key,
    required this.connected,
    required this.busy,
    required this.onConnect,
    required this.onDisconnect,
    this.message,
  });

  final bool connected;
  final bool busy;
  final VoidCallback? onConnect;
  final VoidCallback? onDisconnect;
  final String? message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: AppTheme.borderRadius,
      border: AppTheme.border(),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.auto_awesome_outlined,
              size: 18,
              color: AppColors.textMid,
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'ChatGPT',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            if (connected)
              Text(
                'connected',
                style: AppTheme.mono(size: 10, color: AppColors.textMid),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          connected
              ? 'ready for your next wave'
              : 'connect your ChatGPT account once. then press play and '
                    'discover music from your listening. an eligible ChatGPT subscription is required; availability depends on your account.',
          style: const TextStyle(color: AppColors.textMid, height: 1.5),
        ),
        if (message != null) ...[
          const SizedBox(height: 10),
          Text(message!, style: const TextStyle(color: AppColors.textMid)),
        ],
        const SizedBox(height: 14),
        if (busy)
          const Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 10),
              Text('connecting…'),
            ],
          )
        else if (connected)
          TextButton(
            onPressed: onDisconnect,
            child: const Text('disconnect ChatGPT'),
          )
        else
          FilledButton(
            onPressed: onConnect,
            child: const Text('continue with ChatGPT'),
          ),
      ],
    ),
  );
}

class WaveMoodField extends StatefulWidget {
  const WaveMoodField({
    super.key,
    required this.controller,
    this.enabled = true,
  });
  final TextEditingController controller;
  final bool enabled;

  @override
  State<WaveMoodField> createState() => _WaveMoodFieldState();
}

class _WaveMoodFieldState extends State<WaveMoodField> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextButton.icon(
        onPressed: widget.enabled
            ? () => setState(() => _expanded = !_expanded)
            : null,
        icon: Icon(_expanded ? Icons.remove : Icons.add, size: 14),
        label: const Text('add a mood (optional)'),
      ),
      if (_expanded)
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: TextField(
            key: const ValueKey('wave-mood'),
            controller: widget.controller,
            enabled: widget.enabled,
            maxLength: 500,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'what are you in the mood for?',
              hintText: 'a quiet evening, a long run, something new…',
            ),
          ),
        ),
    ],
  );
}

/// One destination-bound approval; callers persist it through the core API.
Future<bool> showWaveListeningConsent(
  BuildContext context, {
  required String destination,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('make my wave personal'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'allow your model to use the titles, artists, genres and '
                'track IDs from your likes, recent listening and current track. '
                'up to 20 seed tracks help choose real SoundCloud music.',
              ),
              const SizedBox(height: 12),
              const Text(
                'your optional mood and the same metadata for up to 40 '
                'public search candidates are also sent. no audio, descriptions, '
                'comments, private links or SoundCloud credentials are shared.',
              ),
              const SizedBox(height: 12),
              Text(
                'sent to $destination',
                style: AppTheme.mono(size: 11, color: AppColors.textMid),
              ),
              const SizedBox(height: 12),
              const Text(
                'we will remember this choice for this destination and '
                'account. you can revoke it in settings. your provider may retain '
                'metadata or charge for requests.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('allow and play'),
          ),
        ],
      ),
    ) ??
    false;
