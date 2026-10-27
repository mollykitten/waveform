import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../app/theme/colors.dart';
import '../onboarding_kit.dart';
import 'step_layout.dart';

/// 04 — an omnibox with a blinking caret, and the key rows "pressing" in turn
/// while their label lights up. Rows mirror the real bindings in
/// `lib/app/shortcut_bindings.dart`.
class ShortcutsStep extends StatefulWidget {
  const ShortcutsStep({super.key});

  @override
  State<ShortcutsStep> createState() => _ShortcutsStepState();
}

class _ShortcutsStepState extends State<ShortcutsStep>
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
    final mod = Platform.isMacOS ? '⌘' : 'Ctrl';
    final shift = Platform.isMacOS ? '⇧' : 'Shift';
    final rows = [
      ([mod, 'K'], 'search anything'),
      (['space'], 'play / pause'),
      (['←', '→'], 'seek 5s'),
      ([shift, '↑', '↓'], 'volume'),
      ([mod, 'L'], 'your likes'),
    ];
    return TwoCol(
      left: StepIntro(
        clock: clock,
        eyebrow: 'shortcuts',
        title: 'hands stay on the keys',
        body:
            'search everything from one bar, paste a soundcloud link to jump '
            'straight to it, and drive the player without the mouse. media '
            'keys work too.',
        children: [
          Stage(
            clock: clock,
            delay: 380,
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _Omnibox(loop: _motion.loop, mod: mod),
            ),
          ),
        ],
      ),
      right: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 10,
        children: [
          for (var i = 0; i < rows.length; i++)
            CardIn(
              clock: clock,
              delay: 200 + i * 90,
              height: 64,
              borderColor: AppColors.borderDim,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _KeyRow(
                loop: _motion.loop,
                caps: rows[i].$1,
                label: rows[i].$2,
                delayMs: 1200 + i * 1200,
              ),
            ),
        ],
      ),
    );
  }
}

class _Omnibox extends StatelessWidget {
  const _Omnibox({required this.loop, required this.mod});
  final Animation<double> loop;
  final String mod;

  @override
  Widget build(BuildContext context) => Container(
    height: 52,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(3),
      border: Border.all(width: .5, color: AppColors.border),
    ),
    child: Row(
      spacing: 12,
      children: [
        const Icon(Icons.search_rounded, size: 16, color: AppColors.textMid),
        const Text('deep house', style: TextStyle(fontSize: 14)),
        AnimatedBuilder(
          animation: loop,
          builder: (context, _) => Opacity(
            opacity: elapsedSeconds(loop) % 1 < .5 ? 1 : 0,
            child: Container(width: 1.5, height: 16, color: AppColors.acid),
          ),
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(3),
            border: Border.all(width: .5, color: AppColors.border),
          ),
          child: Text('${mod}K', style: AppTheme.mono(size: 11)),
        ),
      ],
    ),
  );
}

/// 0 at rest, 1 fully pressed: ease-out in over 4 % of the 6 s cycle, hold to
/// 10 %, ease-out back by 16 %.
double pressAmount(double seconds, int delayMs) {
  final t = seconds - delayMs / 1000;
  if (t < 0) return 0;
  final p = (t / 6) % 1;
  if (p < .04) return Curves.easeOut.transform(p / .04);
  if (p < .10) return 1;
  if (p < .16) return 1 - Curves.easeOut.transform((p - .10) / .06);
  return 0;
}

class _KeyRow extends StatelessWidget {
  const _KeyRow({
    required this.loop,
    required this.caps,
    required this.label,
    required this.delayMs,
  });
  final Animation<double> loop;
  final List<String> caps;
  final String label;
  final int delayMs;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: loop,
    builder: (context, _) {
      final a = pressAmount(elapsedSeconds(loop), delayMs);
      return Row(
        spacing: 16,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 132),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 6,
              children: [for (final cap in caps) _Keycap(cap, pressed: a)],
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: Color.lerp(AppColors.textMid, AppColors.textHi, a),
            ),
          ),
        ],
      );
    },
  );
}

class _Keycap extends StatelessWidget {
  const _Keycap(this.cap, {required this.pressed});
  final String cap;
  final double pressed;

  @override
  Widget build(BuildContext context) => Transform.translate(
    offset: Offset(0, 2 * pressed),
    child: Container(
      constraints: const BoxConstraints(minWidth: 36),
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(
          width: .5,
          color: Color.lerp(AppColors.border, AppColors.acid, pressed)!,
        ),
        boxShadow: [
          if (pressed < 1)
            BoxShadow(
              offset: Offset(0, 2 * (1 - pressed)),
              color: AppColors.border,
            ),
        ],
      ),
      child: Text(
        cap,
        style: AppTheme.mono(
          size: 13,
          color: Color.lerp(AppColors.textHi, AppColors.acid, pressed)!,
        ),
      ),
    ),
  );
}
