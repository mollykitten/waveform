import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../app/theme/colors.dart';
import '../onboarding_kit.dart';

/// 01 — logo bars spring in, wordmark rises, a full-width waveform grows in
/// and a "played" sweep loops across it.
class WelcomeStep extends StatefulWidget {
  const WelcomeStep({super.key, required this.onNext});
  final VoidCallback onNext;

  @override
  State<WelcomeStep> createState() => _WelcomeStepState();
}

class _WelcomeStepState extends State<WelcomeStep>
    with TickerProviderStateMixin {
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
        alignment: Alignment.center,
        children: [
          Positioned(
            left: 80,
            right: 80,
            bottom: 36,
            height: 72,
            child: ExcludeSemantics(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: WaveBarsPainter(
                    entrance: clock,
                    loop: _motion.loop,
                    count: 224,
                    barWidth: 3,
                    maxHeight: 64,
                    minHeight: 6,
                    seed: 0,
                    stagger: 4,
                    sweep: true,
                  ),
                ),
              ),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LogoBars(clock: clock, barWidth: 18, gap: 14, unit: 120),
              Stage(
                clock: clock,
                delay: 520,
                child: const Padding(
                  padding: EdgeInsets.only(top: 40),
                  child: Text(
                    'waveform',
                    style: TextStyle(
                      fontSize: 64,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -2.56,
                      height: 1,
                    ),
                  ),
                ),
              ),
              Stage(
                clock: clock,
                delay: 700,
                child: const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Text(
                    'soundcloud, quieter. a desktop client for the music you '
                    'already follow.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 18,
                      height: 1.5,
                      color: AppColors.textMid,
                    ),
                  ),
                ),
              ),
              Stage(
                clock: clock,
                delay: 900,
                child: Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: OnbButton(
                    label: 'get started',
                    height: 48,
                    hPad: 28,
                    fontSize: 15,
                    onTap: widget.onNext,
                    icon: const Icon(
                      Icons.arrow_forward_rounded,
                      size: 16,
                      color: AppColors.bg,
                    ),
                  ),
                ),
              ),
              Stage(
                clock: clock,
                delay: 1100,
                child: Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Text(
                    'macOS · windows · linux',
                    style: AppTheme.mono(size: 11, letterSpacing: .66),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
