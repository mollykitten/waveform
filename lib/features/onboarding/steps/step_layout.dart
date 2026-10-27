import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../app/theme/colors.dart';
import '../onboarding_kit.dart';

/// Two equal columns, 80 px apart, inside the 1120 px content column.
class TwoCol extends StatelessWidget {
  const TwoCol({super.key, required this.left, required this.right});
  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) => SizedBox.expand(
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1280),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 80),
          child: Row(
            spacing: 80,
            children: [
              Expanded(child: left),
              Expanded(child: right),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Lime eyebrow, 44 px headline and grey lede shared by the text columns.
class StepIntro extends StatelessWidget {
  const StepIntro({
    super.key,
    required this.clock,
    required this.eyebrow,
    required this.title,
    required this.body,
    this.maxWidth = 460,
    this.children = const [],
  });

  final Animation<double> clock;
  final String eyebrow;
  final String title;
  final String body;
  final double maxWidth;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 20,
        children: [
          Stage(
            clock: clock,
            child: Text(
              '◆ $eyebrow',
              style: AppTheme.mono(
                size: 12,
                color: AppColors.lime,
                letterSpacing: .96,
              ),
            ),
          ),
          Stage(
            clock: clock,
            delay: 120,
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 44,
                fontWeight: FontWeight.w700,
                letterSpacing: -1.32,
                height: 1.08,
              ),
            ),
          ),
          Stage(
            clock: clock,
            delay: 240,
            child: Text(
              body,
              style: const TextStyle(
                fontSize: 16,
                height: 1.6,
                color: AppColors.textMid,
              ),
            ),
          ),
          ...children,
        ],
      ),
    ),
  );
}

/// Skeleton bar used by the placeholder cards.
class Skel extends StatelessWidget {
  const Skel({
    super.key,
    required this.factor,
    required this.height,
    required this.color,
  });
  final double factor;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    widthFactor: factor,
    alignment: Alignment.centerLeft,
    child: Container(
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );
}

/// Surface card that flies in with a small scale, `cardIn` in the mock.
class CardIn extends StatelessWidget {
  const CardIn({
    super.key,
    required this.clock,
    required this.delay,
    required this.child,
    this.height,
    this.padding = EdgeInsets.zero,
    this.borderColor = AppColors.border,
  });

  final Animation<double> clock;
  final int delay;
  final Widget child;
  final double? height;
  final EdgeInsets padding;
  final Color borderColor;

  @override
  Widget build(BuildContext context) => Stage(
    clock: clock,
    delay: delay,
    duration: 760,
    curve: const Cubic(.2, .9, .25, 1),
    dy: 28,
    scale: .96,
    child: Container(
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(width: .5, color: borderColor),
      ),
      child: child,
    ),
  );
}
