import 'package:flutter/material.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../../shared/widgets/form_controls.dart';

/// Keeps an action group together, moving it below the information when needed.
class WaveControlRow extends StatelessWidget {
  const WaveControlRow({
    super.key,
    required this.information,
    required this.actions,
  });
  final Widget information;
  final Widget? actions;

  @override
  Widget build(BuildContext context) => actions == null
      ? information
      : LayoutBuilder(
          builder: (context, constraints) => OverflowBar(
            alignment: MainAxisAlignment.spaceBetween,
            overflowAlignment: OverflowBarAlignment.end,
            spacing: 12,
            overflowSpacing: 8,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                child: information,
              ),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                child: actions!,
              ),
            ],
          ),
        );
}

/// A hairline indeterminate rail: an orange sliver travelling along a dim
/// track. Static under reduced motion.
class WaveProgressRail extends StatefulWidget {
  const WaveProgressRail({super.key});
  @override
  State<WaveProgressRail> createState() => _WaveProgressRailState();
}

class _WaveProgressRailState extends State<WaveProgressRail>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 2,
    child: AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => CustomPaint(
        painter: _RailPainter(_controller.value),
        size: const Size.fromHeight(2),
      ),
    ),
  );
}

class _RailPainter extends CustomPainter {
  _RailPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = AppColors.waveDim.withValues(alpha: .6),
    );
    final eased = Curves.easeInOut.transform(t);
    final width = size.width * .28;
    final left = -width + (size.width + width) * eased;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(
      Rect.fromLTWH(left, 0, width, size.height),
      Paint()..color = AppColors.acid,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RailPainter old) => old.t != t;
}

/// Connection identity and controls stay together above destination privacy.
class WaveConnectionCard extends StatelessWidget {
  const WaveConnectionCard({
    super.key,
    required this.connected,
    required this.busy,
    required this.onConnect,
    required this.onDisconnect,
    this.message,
    this.accountLabel,
    this.footer,
  });
  final bool connected;
  final bool busy;
  final VoidCallback? onConnect;
  final VoidCallback? onDisconnect;
  final String? message;
  final String? accountLabel;
  final Widget? footer;

  Widget get _information => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text('ChatGPT', style: formHeadingStyle),
          if (connected) const Text('connected', style: formTextStyle),
        ],
      ),
      if (connected && accountLabel != null) ...[
        const SizedBox(height: 4),
        Text(accountLabel!, style: formTextStyle),
      ],
      SizedBox(height: connected ? 4 : 8),
      Text(
        connected
            ? 'ready for your next wave'
            : 'connect your ChatGPT account once. then press play and discover music from your listening. an eligible ChatGPT subscription is required; availability depends on your account.',
        style: formTextStyle,
      ),
    ],
  );

  Widget get _action => FormAction(
    label: connected ? 'disconnect ChatGPT' : 'continue with ChatGPT',
    icon: connected ? Icons.link_off : null,
    iconSize: connected ? 16 : 14,
    busyLabel: 'connecting…',
    busy: busy,
    kind: connected ? FormActionKind.secondary : FormActionKind.primary,
    onTap: connected ? onDisconnect : onConnect,
  );

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('wave-connection-card'),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: AppTheme.borderRadius,
      border: AppTheme.border(),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (connected)
          WaveControlRow(information: _information, actions: _action)
        else ...[
          _information,
          const SizedBox(height: 8),
          Align(alignment: Alignment.centerLeft, child: _action),
        ],
        if (message != null) ...[
          const SizedBox(height: 8),
          Text(message!, style: formTextStyle),
        ],
        ?footer,
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
        Align(
          alignment: Alignment.centerLeft,
          child: FormAction(
            onTap: widget.enabled
                ? () => setState(() => _expanded = !_expanded)
                : null,
            icon: _expanded ? Icons.remove : Icons.add,
            label: 'add a mood (optional)',
            kind: FormActionKind.quiet,
          ),
        ),
      if (_expanded || widget.expanded) ...[
        if (!widget.expanded) const SizedBox(height: 8),
        FormFieldLabel(
          label: 'what are you in the mood for?',
          child: TextField(
            key: const ValueKey('wave-mood'),
            controller: widget.controller,
            enabled: widget.enabled,
            maxLength: 500,
            minLines: 1,
            maxLines: 3,
            style: const TextStyle(fontSize: 13, height: 1.5),
            decoration: formInputDecoration(
              hint: 'a quiet evening, a long run, something new…',
            ),
          ),
        ),
      ],
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
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: _ConsentAction(
              onTap: () => Navigator.pop(context, true),
              label: 'allow and play',
              active: true,
            ),
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
  Widget build(BuildContext context) => FormAction(
    label: label,
    onTap: onTap,
    kind: active ? FormActionKind.primary : FormActionKind.secondary,
  );
}
