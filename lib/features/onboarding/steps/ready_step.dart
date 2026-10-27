import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../app/theme/colors.dart';
import '../onboarding_kit.dart';

/// 05 — "you're all set": logo bars, headline, and a mini player sliding up
/// with a sweeping waveform.
class ReadyStep extends StatefulWidget {
  const ReadyStep({super.key, required this.onFinish});
  final VoidCallback onFinish;

  @override
  State<ReadyStep> createState() => _ReadyStepState();
}

class _ReadyStepState extends State<ReadyStep> with TickerProviderStateMixin {
  late final _motion = StepMotion(this);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motion.sync(context);
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clock = _motion.entrance;
    return SizedBox.expand(
      child: Stack(
        children: [
          Positioned.fill(
            bottom: 120,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                LogoBars(
                  clock: clock,
                  barWidth: 12,
                  gap: 10,
                  unit: 72,
                  firstDelay: 60,
                  stepDelay: 60,
                  allLit: true,
                ),
                Stage(
                  clock: clock,
                  delay: 380,
                  child: const Padding(
                    padding: EdgeInsets.only(top: 32),
                    child: Text(
                      "you're all set",
                      style: TextStyle(
                        fontSize: 52,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -1.82,
                        height: 1,
                      ),
                    ),
                  ),
                ),
                Stage(
                  clock: clock,
                  delay: 520,
                  child: const Padding(
                    padding: EdgeInsets.only(top: 14),
                    child: Text(
                      'press play and let the wave take it from here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 17,
                        height: 1.5,
                        color: AppColors.textMid,
                      ),
                    ),
                  ),
                ),
                Stage(
                  clock: clock,
                  delay: 700,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 36),
                    child: OnbButton(
                      label: 'start listening',
                      height: 52,
                      hPad: 32,
                      fontSize: 16,
                      onTap: widget.onFinish,
                      icon: const Icon(
                        Icons.play_arrow_rounded,
                        size: 18,
                        color: AppColors.bg,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            left: 40,
            right: 40,
            bottom: 24,
            child: Stage(
              clock: clock,
              delay: 300,
              duration: 900,
              curve: const Cubic(.2, 1.1, .3, 1),
              dy: 106,
              child: ExcludeSemantics(child: _MiniPlayer(motion: _motion)),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniPlayer extends StatelessWidget {
  const _MiniPlayer({required this.motion});
  final StepMotion motion;

  @override
  Widget build(BuildContext context) => Container(
    height: 76,
    padding: const EdgeInsets.symmetric(horizontal: 20),
    decoration: BoxDecoration(
      color: AppColors.surface.withValues(alpha: .82),
      borderRadius: BorderRadius.circular(3),
      border: Border.all(width: .5, color: AppColors.border),
    ),
    child: Row(
      spacing: 20,
      children: [
        Container(
          width: 48,
          height: 48,
          padding: const EdgeInsets.only(bottom: 14),
          alignment: Alignment.bottomCenter,
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(3),
          ),
          child: EqBars(
            loop: motion.loop,
            bars: const [
              EqBar(3, 12, AppColors.acid),
              EqBar(3, 20, AppColors.acid, 200),
              EqBar(3, 9, AppColors.acid, 400),
            ],
          ),
        ),
        SizedBox(
          width: 180,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              const Text(
                'first track',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              Text(
                '◆ my wave',
                style: AppTheme.mono(size: 11, color: AppColors.lime),
              ),
            ],
          ),
        ),
        const _Controls(),
        Text('0:42', style: AppTheme.mono(size: 11)),
        Expanded(
          child: SizedBox(
            height: 36,
            child: RepaintBoundary(
              child: CustomPaint(
                painter: WaveBarsPainter(
                  entrance: motion.entrance,
                  loop: motion.loop,
                  count: 300,
                  barWidth: 2,
                  maxHeight: 30,
                  minHeight: 4,
                  seed: 1.3,
                  stagger: 3,
                  baseDelay: 300,
                  sweep: true,
                ),
              ),
            ),
          ),
        ),
        Text('3:48', style: AppTheme.mono(size: 11)),
      ],
    ),
  );
}

class _Controls extends StatelessWidget {
  const _Controls();

  @override
  Widget build(BuildContext context) => Row(
    spacing: 14,
    children: [
      const Icon(
        Icons.skip_previous_rounded,
        size: 20,
        color: AppColors.textMid,
      ),
      Container(
        width: 36,
        height: 36,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.acid,
        ),
        child: const Icon(Icons.pause_rounded, size: 18, color: AppColors.bg),
      ),
      const Icon(Icons.skip_next_rounded, size: 20, color: AppColors.textMid),
    ],
  );
}
