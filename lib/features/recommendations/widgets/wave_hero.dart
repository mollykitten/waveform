import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/theme/colors.dart';
import '../../../shared/widgets/pressable.dart';

/// A quiet, open centre surrounded by slowly folding amber ribbons.
class WaveHero extends StatefulWidget {
  const WaveHero({
    super.key,
    required this.description,
    required this.actionLabel,
    required this.onPlay,
    required this.onTune,
    this.busy = false,
    this.enabled = true,
    this.active = true,
  });

  final String description;
  final String actionLabel;
  final VoidCallback onPlay;
  final VoidCallback onTune;
  final bool busy;
  final bool enabled;
  final bool active;

  @override
  State<WaveHero> createState() => _WaveHeroState();
}

class _WaveHeroState extends State<WaveHero>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final _motion = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 14),
  );
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(covariant WaveHero oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMotion();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncMotion();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  void _syncMotion() {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final animate =
        !reduced &&
        widget.active &&
        _foreground &&
        TickerMode.valuesOf(context).enabled;
    if (animate && !_motion.isAnimating) _motion.repeat();
    if (!animate) {
      _motion.stop();
      if (reduced) _motion.value = 0;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 400,
    child: Stack(
      alignment: Alignment.center,
      children: [
        Positioned.fill(
          child: ExcludeSemantics(
            child: RepaintBoundary(
              child: ClipRect(
                child: CustomPaint(painter: WaveRibbonPainter(_motion)),
              ),
            ),
          ),
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              label: widget.actionLabel,
              child: Pressable(
                key: const ValueKey('wave-primary'),
                enabled: widget.enabled && !widget.busy,
                onTap: widget.onPlay,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.play_arrow_rounded,
                        size: 48,
                        color: AppColors.textHi,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'my wave',
                        style: TextStyle(
                          fontSize: 44,
                          height: 1.1,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -1.8,
                          color: AppColors.textHi,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: 290,
              child: Text(
                widget.description,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.textMid,
                  fontSize: 12,
                  height: 1.6,
                ),
              ),
            ),
            const SizedBox(height: 20),
            WaveAction(
              label: 'tune your wave',
              icon: Icons.tune,
              onTap: widget.onTune,
            ),
          ],
        ),
      ],
    ),
  );
}

/// Compact keyboard-accessible control shared by the wave and its tuning shelf.
class WaveAction extends StatelessWidget {
  const WaveAction({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.selected = false,
    this.enabled = true,
  });
  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    child: Pressable(
      enabled: enabled,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.surface2 : AppColors.surface,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(
            width: .5,
            color: selected ? AppColors.acid : AppColors.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 14,
                color: enabled
                    ? (selected ? AppColors.acid : AppColors.textMid)
                    : AppColors.textLow,
              ),
              const SizedBox(width: 7),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: enabled ? AppColors.textHi : AppColors.textLow,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Paint-only animation: the controls and page never rebuild on a tick.
class WaveRibbonPainter extends CustomPainter {
  WaveRibbonPainter(this.phase) : super(repaint: phase);
  final Animation<double> phase;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final radiusX = math.min(size.width * .39, 310.0);
    final radiusY = size.height * .36;
    final time = phase.value * math.pi * 2;
    final bounds = Rect.fromCenter(
      center: centre,
      width: radiusX * 2.3,
      height: radiusY * 2.5,
    );
    for (var layer = 0; layer < 5; layer++) {
      final points = <Offset>[];
      for (var step = 0; step < 96; step++) {
        final angle = step / 96 * math.pi * 2;
        final fold =
            math.sin(angle * 3 + time + layer * .36) * .08 +
            math.cos(angle * 2 - time + layer * .27) * .055;
        final radius = 1 + fold + (layer - 2) * .047;
        points.add(
          centre +
              Offset(
                math.cos(angle) * radiusX * radius +
                    math.sin(angle * 2 + time) * 12,
                math.sin(angle) * radiusY * radius +
                    math.cos(angle * 3 - time + layer * .4) * 12,
              ),
        );
      }
      final path = Path();
      final start = (points.last + points.first) / 2;
      path.moveTo(start.dx, start.dy);
      for (var index = 0; index < points.length; index++) {
        final point = points[index];
        final next = (point + points[(index + 1) % points.length]) / 2;
        path.quadraticBezierTo(point.dx, point.dy, next.dx, next.dy);
      }
      path.close();
      final shader = const SweepGradient(
        colors: [
          Color(0xFFFF6800),
          Color(0x33FF5500),
          Color(0xFFFFB800),
          Color(0xFFFFE191),
          Color(0x44FF5500),
          Color(0xFFFF6800),
        ],
        stops: [0, .18, .42, .58, .8, 1],
      ).createShader(bounds);
      final bloom = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8 + layer * 2.0
        ..color = const Color(0x10FF8A00)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
      canvas.drawPath(path, bloom);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4 + layer * 1.1
          ..shader = shader
          ..color = Colors.white.withValues(alpha: .16),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = layer == 2 ? 1.6 : .7
          ..shader = shader,
      );
    }
  }

  @override
  bool shouldRepaint(covariant WaveRibbonPainter oldDelegate) =>
      oldDelegate.phase != phase;
}
