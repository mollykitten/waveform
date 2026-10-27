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
    this.busy = false,
    this.enabled = true,
    this.active = true,
  });

  final String description;
  final String actionLabel;
  final VoidCallback onPlay;
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
          ],
        ),
      ],
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
    final radiusX = math.min(size.width * .24, 166.0);
    final radiusY = size.height * .45;
    final time = phase.value * math.pi * 2;
    final bounds = Rect.fromCenter(
      center: centre,
      width: radiusX * 2,
      height: radiusY * 2,
    );
    for (var fold = 0; fold < 2; fold++) {
      for (var layer = 0; layer < 2; layer++) {
        _paintFold(
          canvas,
          centre,
          radiusX,
          radiusY,
          time,
          bounds,
          lower: fold == 0,
          layer: layer,
        );
      }
    }
  }

  void _paintFold(
    Canvas canvas,
    Offset centre,
    double radiusX,
    double radiusY,
    double time,
    Rect bounds, {
    required bool lower,
    required int layer,
  }) {
    final outer = <Offset>[];
    final inner = <Offset>[];
    final edge = <Offset>[];
    for (var step = 0; step <= 80; step++) {
      final t = step / 80;
      final angle = lower ? 2.85 - t * 2.65 : 3.45 + t * 2.7;
      final taper = math.pow(math.sin(t * math.pi), 1.6).toDouble();
      final drift = math.sin(time + t * 4 + (lower ? 0 : 1.2));
      final crossing =
          math.sin(t * math.pi * 2 + time) * taper * layer * (lower ? 13 : 7);
      final point =
          centre +
          Offset(
            math.cos(angle) * radiusX + drift * taper * 5 + crossing,
            math.sin(angle) * radiusY +
                taper * drift * 4 +
                crossing * math.cos(t * math.pi),
          );
      final wideFold = math.exp(
        -math.pow(t - .57 - math.sin(time) * .035, 2) / .065,
      );
      final width =
          taper * (2 + (lower ? 21 : 10) * wideFold) * (layer == 0 ? 1 : .65);
      final normal = Offset(math.cos(angle), math.sin(angle));
      outer.add(point + normal * width * .5);
      inner.add(point - normal * width * .5);
      edge.add(point - normal * width * .35);
    }
    final ribbon = _smoothLoop([...outer, ...inner.reversed]);
    final bodyShader = LinearGradient(
      colors: [
        const Color(0x00FF8A00),
        Color(lower ? 0x08FF8A00 : 0x03FF8A00),
        Color(lower ? 0x20FF9D25 : 0x10FF9D25),
        Color(lower ? 0x10FF6B00 : 0x06FF6B00),
        const Color(0x00FF6B00),
      ],
      stops: const [0, .15, .5, .78, 1],
    ).createShader(bounds);
    canvas.drawPath(
      ribbon,
      Paint()
        ..shader = bodyShader
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    canvas.drawPath(ribbon, Paint()..shader = bodyShader);
    final edgeShader = LinearGradient(
      colors: [
        const Color(0x00FF8A00),
        Color(lower ? 0x14FF8A00 : 0x06FF8A00),
        Color(lower ? 0x66FFB84D : 0x26FFB84D),
        Color(lower ? 0x40FF7800 : 0x0AFF7800),
        const Color(0x00FF7800),
      ],
      stops: const [0, .2, .48, .7, 1],
    ).createShader(bounds);
    canvas.drawPath(
      _smoothLine(edge),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = layer == 0 ? 1.1 : .7
        ..shader = edgeShader,
    );
    if (lower && layer == 0) {
      final highlight = edge.sublist(31, 46);
      canvas.drawPath(
        _smoothLine(highlight),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.7
          ..shader = const LinearGradient(
            colors: [Color(0x00FFCB70), Color(0xA6FFCB70), Color(0x00FFCB70)],
          ).createShader(Rect.fromPoints(highlight.first, highlight.last)),
      );
    }
  }

  Path _smoothLine(List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var index = 1; index < points.length - 1; index++) {
      final next = (points[index] + points[index + 1]) / 2;
      path.quadraticBezierTo(
        points[index].dx,
        points[index].dy,
        next.dx,
        next.dy,
      );
    }
    return path..lineTo(points.last.dx, points.last.dy);
  }

  Path _smoothLoop(List<Offset> points) {
    final start = (points.last + points.first) / 2;
    final path = Path()..moveTo(start.dx, start.dy);
    for (var index = 0; index < points.length; index++) {
      final point = points[index];
      final next = (point + points[(index + 1) % points.length]) / 2;
      path.quadraticBezierTo(point.dx, point.dy, next.dx, next.dy);
    }
    return path..close();
  }

  @override
  bool shouldRepaint(covariant WaveRibbonPainter oldDelegate) =>
      oldDelegate.phase != phase;
}
