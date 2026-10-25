import 'package:flutter/material.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../../shared/widgets/pressable.dart';

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
            style: FilledButton.styleFrom(
              shape: const RoundedRectangleBorder(
                borderRadius: AppTheme.borderRadius,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
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
    this.expanded = false,
  });
  final bool expanded;
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
      if (!widget.expanded)
        TextButton.icon(
          onPressed: widget.enabled
              ? () => setState(() => _expanded = !_expanded)
              : null,
          icon: Icon(_expanded ? Icons.remove : Icons.add, size: 14),
          label: const Text('add a mood (optional)'),
        ),
      if (_expanded || widget.expanded)
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: TextField(
            key: const ValueKey('wave-mood'),
            controller: widget.controller,
            enabled: widget.enabled,
            maxLength: 500,
            minLines: 1,
            maxLines: 3,
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              labelText: 'what are you in the mood for?',
              hintText: 'a quiet evening, a long run, something new…',
              counterText: '',
              filled: true,
              fillColor: AppColors.bg,
              isDense: true,
              labelStyle: const TextStyle(
                fontSize: 12,
                color: AppColors.textMid,
              ),
              contentPadding: const EdgeInsets.all(12),
              border: const OutlineInputBorder(
                borderRadius: AppTheme.borderRadius,
                borderSide: AppTheme.borderSideStatic,
              ),
              enabledBorder: const OutlineInputBorder(
                borderRadius: AppTheme.borderRadius,
                borderSide: AppTheme.borderSideStatic,
              ),
              focusedBorder: const OutlineInputBorder(
                borderRadius: AppTheme.borderRadius,
                borderSide: BorderSide(color: AppColors.acid, width: .5),
              ),
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
          _ConsentAction(
            onTap: () => Navigator.pop(context, false),
            label: 'not now',
          ),
          _ConsentAction(
            onTap: () => Navigator.pop(context, true),
            label: 'allow and play',
            active: true,
          ),
        ],
      ),
    ) ??
    false;

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
