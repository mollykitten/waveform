import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/theme/colors.dart';
import '../../shared/widgets/pressable.dart';

/// Length of the one-shot entrance timeline every step plays on mount.
/// Individual [Stage]s live inside it by real milliseconds.
const kEntrance = Duration(milliseconds: 2600);

/// Looping clock for sweeps, key presses, eq and caret. 660 s is a common
/// multiple of every period used (1 s, 1.1 s, 6 s, 10 s), so the wrap is
/// invisible.
const kLoopSeconds = 660;

const kEase = Cubic(.2, .8, .2, 1);
const kSpring = Cubic(.2, 1.5, .4, 1);

/// Owns the two clocks of a step. Reduced motion pins the entrance on its
/// final frame and the loop on zero (static end state); [TickerMode] mutes
/// the tickers when the step is off screen.
class StepMotion {
  StepMotion(TickerProvider vsync)
    : entrance = AnimationController(vsync: vsync, duration: kEntrance),
      loop = AnimationController(
        vsync: vsync,
        duration: const Duration(seconds: kLoopSeconds),
      );

  final AnimationController entrance;
  final AnimationController loop;

  void sync(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      entrance.value = 1;
      loop
        ..stop()
        ..value = 0;
      return;
    }
    if (!entrance.isAnimating && entrance.value < 1) entrance.forward();
    if (!loop.isAnimating) loop.repeat();
  }

  void dispose() {
    entrance.dispose();
    loop.dispose();
  }
}

double elapsedSeconds(Animation<double> loop) => loop.value * kLoopSeconds;

/// Fade + rise (+ optional scale) driven by the entrance clock.
class Stage extends StatelessWidget {
  const Stage({
    super.key,
    required this.clock,
    required this.child,
    this.delay = 0,
    this.duration = 680,
    this.curve = kEase,
    this.dy = 14,
    this.scale = 1,
  });

  final Animation<double> clock;
  final Widget child;
  final int delay;
  final int duration;
  final Curve curve;
  final double dy;
  final double scale;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: clock,
    child: child,
    builder: (context, child) {
      final raw = (clock.value * kEntrance.inMilliseconds - delay) / duration;
      if (raw >= 1) return child!;
      final p = curve.transform(raw.clamp(0.0, 1.0));
      Widget out = Transform.translate(
        offset: Offset(0, (1 - p) * dy),
        child: child,
      );
      if (scale != 1) {
        out = Transform.scale(scale: scale + (1 - scale) * p, child: out);
      }
      return Opacity(opacity: p.clamp(0.0, 1.0), child: out);
    },
  );
}

/// Bar growing from its base with an overshoot, like the logo mark.
class RiseBar extends StatelessWidget {
  const RiseBar({
    super.key,
    required this.clock,
    required this.delay,
    required this.child,
    this.duration = 900,
  });

  final Animation<double> clock;
  final int delay;
  final int duration;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: clock,
    child: child,
    builder: (context, child) {
      final raw = (clock.value * kEntrance.inMilliseconds - delay) / duration;
      if (raw >= 1) return child!;
      final p = kSpring.transform(raw.clamp(0.0, 1.0));
      return Transform(
        alignment: Alignment.bottomCenter,
        transform: Matrix4.diagonal3Values(1, math.max(p, 0), 1),
        child: child,
      );
    },
  );
}

/// The five-bar mark. Heights are the canonical logo geometry; the last two
/// bars stay `waveDim` unless [allLit].
class LogoBars extends StatelessWidget {
  const LogoBars({
    super.key,
    required this.clock,
    required this.barWidth,
    required this.gap,
    required this.unit,
    this.firstDelay = 100,
    this.stepDelay = 90,
    this.allLit = false,
  });

  final Animation<double> clock;
  final double barWidth;
  final double gap;

  /// Height of the tallest bar; the rest scale from the logo proportions.
  final double unit;
  final int firstDelay;
  final int stepDelay;
  final bool allLit;

  static const _ratios = [.5, 1.0, .35, .8, .6];

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      height: unit,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        spacing: gap,
        children: [
          for (var i = 0; i < _ratios.length; i++)
            RiseBar(
              clock: clock,
              delay: firstDelay + i * stepDelay,
              child: Container(
                width: barWidth,
                height: unit * _ratios[i],
                decoration: BoxDecoration(
                  color: i < 3 || allLit ? AppColors.acid : AppColors.waveDim,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// Waveform bars grown in with a stagger; optionally a sweeping "played" part
/// ([sweep]) or a fixed lit prefix ([litCount]). Paint-only.
class WaveBarsPainter extends CustomPainter {
  WaveBarsPainter({
    required this.entrance,
    required this.loop,
    required this.count,
    required this.barWidth,
    required this.maxHeight,
    required this.minHeight,
    required this.seed,
    required this.stagger,
    this.baseDelay = 0,
    this.sweep = false,
    this.litCount = 0,
  }) : super(repaint: Listenable.merge([entrance, if (sweep) loop])) {
    heights = [
      for (var i = 0; i < count; i++)
        (minHeight +
                (maxHeight - minHeight) *
                    (math.sin(i * .37 + seed) * .6 +
                            math.sin(i * .113 + seed * 2) * .4)
                        .abs() *
                    (.55 + .45 * math.sin(i / count * math.pi)))
            .roundToDouble(),
    ];
  }

  final Animation<double> entrance;
  final Animation<double> loop;
  final int count;
  final double barWidth;
  final double maxHeight;
  final double minHeight;
  final double seed;
  final int stagger;
  final int baseDelay;
  final bool sweep;
  final int litCount;
  late final List<double> heights;

  static const _gap = 2.0;

  /// Fraction of the bars that is "played" at [t] seconds into the step: the
  /// resting 38 % until the first sweep starts, then 0 → 100 % over 8.5 s,
  /// holding 1.5 s.
  static double playedAt(double t) {
    if (t < 1.6) return .38;
    return math.min(1, (((t - 1.6) % 10) / 10) / .85);
  }

  void _bars(Canvas canvas, Size size, Color Function(int) colorFor) {
    final n = math.min(
      count,
      ((size.width + _gap) / (barWidth + _gap)).floor(),
    );
    final ms = entrance.value * kEntrance.inMilliseconds;
    final paint = Paint();
    for (var i = 0; i < n; i++) {
      final q = kEase.transform(
        ((ms - baseDelay - i * stagger) / 520).clamp(0.0, 1.0),
      );
      if (q == 0) continue;
      final h = heights[i] * (.04 + .96 * q);
      final x = i * (barWidth + _gap);
      paint.color = colorFor(i).withValues(alpha: q);
      canvas.drawRRect(
        RRect.fromLTRBR(
          x,
          (size.height - h) / 2,
          x + barWidth,
          (size.height + h) / 2,
          const Radius.circular(1),
        ),
        paint,
      );
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    _bars(
      canvas,
      size,
      (i) => i < litCount ? AppColors.acid : AppColors.waveDim,
    );
    if (!sweep) return;
    final width = size.width * playedAt(elapsedSeconds(loop));
    canvas
      ..save()
      ..clipRect(Rect.fromLTWH(0, 0, width, size.height));
    _bars(canvas, size, (_) => AppColors.acid);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant WaveBarsPainter old) =>
      old.entrance != entrance ||
      old.loop != loop ||
      old.count != count ||
      old.seed != seed ||
      old.sweep != sweep ||
      old.litCount != litCount;
}

/// Looping equaliser: bars scale between 1, .45 and .85 of their height.
class EqBars extends StatelessWidget {
  const EqBars({super.key, required this.loop, required this.bars});

  final Animation<double> loop;
  final List<EqBar> bars;

  @override
  Widget build(BuildContext context) {
    final width =
        bars.fold<double>(0, (w, b) => w + b.width) + 3 * (bars.length - 1);
    final height = bars.fold<double>(0, (h, b) => math.max(h, b.height));
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size(width, height),
          painter: _EqPainter(loop, bars),
        ),
      ),
    );
  }
}

class EqBar {
  const EqBar(this.width, this.height, this.color, [this.delayMs = 0]);
  final double width;
  final double height;
  final Color color;
  final int delayMs;
}

class _EqPainter extends CustomPainter {
  _EqPainter(this.loop, this.bars) : super(repaint: loop);
  final Animation<double> loop;
  final List<EqBar> bars;

  static double scaleAt(double seconds, int delayMs) {
    final t = seconds - delayMs / 1000;
    if (t < 0) return 1;
    final p = (t / 1.1) % 1;
    const stops = [0.0, .3, .6, 1.0];
    const values = [1.0, .45, .85, 1.0];
    for (var i = 0; i < 3; i++) {
      if (p <= stops[i + 1]) {
        final k = Curves.easeInOut.transform(
          (p - stops[i]) / (stops[i + 1] - stops[i]),
        );
        return values[i] + (values[i + 1] - values[i]) * k;
      }
    }
    return 1;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final seconds = elapsedSeconds(loop);
    var x = 0.0;
    for (final bar in bars) {
      final h = bar.height * scaleAt(seconds, bar.delayMs);
      canvas.drawRRect(
        RRect.fromLTRBR(
          x,
          size.height - h,
          x + bar.width,
          size.height,
          const Radius.circular(1),
        ),
        Paint()..color = bar.color,
      );
      x += bar.width + 3;
    }
  }

  @override
  bool shouldRepaint(covariant _EqPainter old) => old.bars != bars;
}

/// Onboarding button: acid primary or hairline ghost, with the shared spring
/// press and a hover border on the ghost.
class OnbButton extends StatefulWidget {
  const OnbButton({
    super.key,
    required this.label,
    required this.onTap,
    this.primary = true,
    this.height = 44,
    this.hPad = 22,
    this.fontSize = 14,
    this.weight = FontWeight.w600,
    this.icon,
  });

  final String label;
  final VoidCallback onTap;
  final bool primary;
  final double height;
  final double hPad;
  final double fontSize;
  final FontWeight weight;
  final Widget? icon;

  @override
  State<OnbButton> createState() => _OnbButtonState();
}

class _OnbButtonState extends State<OnbButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final primary = widget.primary;
    final fg = primary ? AppColors.bg : AppColors.textHi;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Semantics(
        button: true,
        label: widget.label,
        excludeSemantics: true,
        child: Pressable(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: kEase,
            height: widget.height,
            padding: EdgeInsets.symmetric(horizontal: widget.hPad),
            decoration: BoxDecoration(
              color: primary ? AppColors.acid : Colors.transparent,
              borderRadius: BorderRadius.circular(3),
              border: primary
                  ? null
                  : Border.all(
                      width: .5,
                      color: _hover ? AppColors.textMid : AppColors.border,
                    ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 10,
              children: [
                Text(
                  widget.label,
                  style: TextStyle(
                    color: fg,
                    fontSize: widget.fontSize,
                    fontWeight: widget.weight,
                    height: 1,
                  ),
                ),
                ?widget.icon,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
