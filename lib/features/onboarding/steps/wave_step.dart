import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../app/theme/colors.dart';
import '../../recommendations/widgets/wave_hero.dart' show WaveRibbonPainter;
import '../onboarding_kit.dart';
import 'step_layout.dart';

/// 03 — folding ribbons (the real [WaveRibbonPainter]) around the "my wave"
/// mark, and three theses about how the queue is built.
class WaveStep extends StatefulWidget {
  const WaveStep({super.key});

  @override
  State<WaveStep> createState() => _WaveStepState();
}

class _WaveStepState extends State<WaveStep> with TickerProviderStateMixin {
  late final _motion = StepMotion(this);
  late final _ribbons = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 14),
  );

  static const _points = [
    (
      '01',
      'related, not random.',
      'built from the neighbours of tracks you like.',
      420,
    ),
    (
      '02',
      'skips and dislikes steer it.',
      'a disliked track stays out of the wave for a while.',
      520,
    ),
    (
      '03',
      'stays on this device.',
      'your listening signals never leave the app.',
      620,
    ),
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motion.sync(context);
    if (MediaQuery.disableAnimationsOf(context)) {
      _ribbons
        ..stop()
        ..value = 0;
    } else if (!_ribbons.isAnimating) {
      _ribbons.repeat();
    }
  }

  @override
  void dispose() {
    _ribbons.dispose();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clock = _motion.entrance;
    return TwoCol(
      left: SizedBox(
        height: 400,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: ExcludeSemantics(
                child: Stage(
                  clock: clock,
                  duration: 1400,
                  dy: 0,
                  scale: .94,
                  child: RepaintBoundary(
                    child: CustomPaint(painter: WaveRibbonPainter(_ribbons)),
                  ),
                ),
              ),
            ),
            Stage(clock: clock, delay: 240, child: const _WaveMark()),
          ],
        ),
      ),
      right: StepIntro(
        clock: clock,
        eyebrow: 'my wave',
        title: 'a queue that never runs dry',
        body:
            'press play once — my wave keeps going with tracks related to '
            'what you already like, and refills the queue before it ends.',
        maxWidth: 480,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 8),
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(width: .5, color: AppColors.borderDim),
              ),
            ),
            child: Column(
              children: [
                for (final (n, title, sub, delay) in _points)
                  Stage(
                    clock: clock,
                    delay: delay,
                    child: _Point(n: n, title: title, sub: sub),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WaveMark extends StatelessWidget {
  const _WaveMark();

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            Icon(Icons.play_arrow_rounded, size: 48, color: AppColors.textHi),
            Text(
              'my wave',
              style: TextStyle(
                fontSize: 44,
                height: 1.1,
                fontWeight: FontWeight.w700,
                letterSpacing: -1.8,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 4),
      const SizedBox(
        width: 290,
        child: Text(
          'an endless queue of real soundcloud tracks, picked from what you '
          'like.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, height: 1.6, color: AppColors.textMid),
        ),
      ),
    ],
  );
}

class _Point extends StatelessWidget {
  const _Point({required this.n, required this.title, required this.sub});
  final String n;
  final String title;
  final String sub;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 14),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(width: .5, color: AppColors.borderDim)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      spacing: 16,
      children: [
        SizedBox(width: 20, child: Text(n, style: AppTheme.mono(size: 11))),
        Expanded(
          child: Text.rich(
            TextSpan(
              text: '$title ',
              children: [
                TextSpan(
                  text: sub,
                  style: const TextStyle(color: AppColors.textMid),
                ),
              ],
            ),
            style: const TextStyle(fontSize: 14, height: 1.5),
          ),
        ),
      ],
    ),
  );
}
