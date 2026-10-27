import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../app/theme/colors.dart';
import '../onboarding_kit.dart';
import 'step_layout.dart';

/// 02 — sign in (existing login dialog) or browse; a skeleton of the
/// signed-in library flies in on the right.
class AccountStep extends StatefulWidget {
  const AccountStep({super.key, required this.onSignIn, required this.onSkip});
  final VoidCallback onSignIn;
  final VoidCallback onSkip;

  @override
  State<AccountStep> createState() => _AccountStepState();
}

class _AccountStepState extends State<AccountStep>
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
    return TwoCol(
      left: StepIntro(
        clock: clock,
        eyebrow: 'your account',
        title: 'bring your soundcloud with you',
        body:
            'sign in once and your stream, likes, playlists and follows show '
            "up here. the session token lives in this app's own storage on "
            'this machine.',
        children: [
          Stage(
            clock: clock,
            delay: 380,
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 10,
                children: [
                  OnbButton(
                    label: 'sign in with soundcloud',
                    height: 48,
                    hPad: 24,
                    fontSize: 15,
                    onTap: widget.onSignIn,
                  ),
                  OnbButton(
                    label: 'browse without an account',
                    primary: false,
                    hPad: 18,
                    weight: FontWeight.w500,
                    onTap: widget.onSkip,
                  ),
                ],
              ),
            ),
          ),
          Stage(
            clock: clock,
            delay: 520,
            child: Text(
              'you can sign in later from settings.',
              style: AppTheme.mono(size: 11, height: 1.6),
            ),
          ),
        ],
      ),
      right: ExcludeSemantics(child: _Skeleton(motion: _motion)),
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton({required this.motion});
  final StepMotion motion;

  static const _tiles = [
    ('likes', .58, 380),
    ('playlists', .40, 480),
    ('following', .66, 580),
  ];
  static const _rows = [(.44, 700), (.58, 790), (.36, 880)];

  @override
  Widget build(BuildContext context) {
    final clock = motion.entrance;
    return SizedBox(
      height: 460,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: CardIn(
              clock: clock,
              delay: 200,
              padding: const EdgeInsets.all(20),
              child: Row(
                spacing: 16,
                children: [
                  _Cover(loop: motion.loop),
                  Expanded(child: _CardBody(motion: motion)),
                ],
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 160,
            child: Row(
              spacing: 12,
              children: [
                for (final (label, width, delay) in _tiles)
                  Expanded(
                    child: CardIn(
                      clock: clock,
                      delay: delay,
                      height: 112,
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            label,
                            style: AppTheme.mono(size: 11, letterSpacing: .66),
                          ),
                          Skel(
                            factor: width,
                            height: 20,
                            color: AppColors.surface2,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 296,
            child: Column(
              spacing: 8,
              children: [
                for (final (width, delay) in _rows)
                  CardIn(
                    clock: clock,
                    delay: delay,
                    height: 48,
                    borderColor: AppColors.borderDim,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(
                      spacing: 12,
                      children: [
                        Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: AppColors.surface2,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        Expanded(
                          child: Skel(
                            factor: width,
                            height: 10,
                            color: AppColors.border,
                          ),
                        ),
                        Text('stream', style: AppTheme.mono(size: 11)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.loop});
  final Animation<double> loop;

  @override
  Widget build(BuildContext context) => Container(
    width: 96,
    height: 96,
    padding: const EdgeInsets.only(bottom: 28),
    alignment: Alignment.bottomCenter,
    decoration: BoxDecoration(
      color: AppColors.surface2,
      borderRadius: BorderRadius.circular(3),
    ),
    child: EqBars(
      loop: loop,
      bars: const [
        EqBar(5, 22, AppColors.acid),
        EqBar(5, 40, AppColors.acid, 180),
        EqBar(5, 16, AppColors.acid, 360),
        EqBar(5, 32, AppColors.waveDim, 90),
        EqBar(5, 26, AppColors.waveDim, 270),
      ],
    ),
  );
}

class _CardBody extends StatelessWidget {
  const _CardBody({required this.motion});
  final StepMotion motion;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    spacing: 10,
    children: [
      const Skel(factor: .46, height: 10, color: AppColors.border),
      const Skel(factor: .70, height: 14, color: AppColors.surface2),
      SizedBox(
        height: 36,
        width: double.infinity,
        child: ExcludeSemantics(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: WaveBarsPainter(
                entrance: motion.entrance,
                loop: motion.loop,
                count: 90,
                barWidth: 2,
                maxHeight: 34,
                minHeight: 4,
                seed: 2.1,
                stagger: 9,
                baseDelay: 500,
                litCount: 36,
              ),
            ),
          ),
        ),
      ),
    ],
  );
}
