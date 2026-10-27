import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:window_manager/window_manager.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../auth/login_dialog.dart';
import 'onboarding_gate.dart';
import 'onboarding_kit.dart';
import 'steps/account_step.dart';
import 'steps/ready_step.dart';
import 'steps/shortcuts_step.dart';
import 'steps/wave_step.dart';
import 'steps/welcome_step.dart';

const _names = ['welcome', 'account', 'my wave', 'shortcuts', 'ready'];

/// First-run tour at `/welcome`, outside the shell. Return/→ next, ← back,
/// Esc skips; finishing or skipping stores the "seen" flag.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key, this.initialStep = 0});
  final int initialStep;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  late int _step = widget.initialStep.clamp(0, _names.length - 1);
  bool _forward = true;
  bool _leaving = false;

  void _go(int index) {
    final next = index.clamp(0, _names.length - 1);
    if (next == _step) return;
    setState(() {
      _forward = next > _step;
      _step = next;
    });
  }

  void _next() => _step >= _names.length - 1 ? _leave() : _go(_step + 1);

  void _back() => _go(_step - 1);

  void _leave() {
    if (_leaving) return;
    _leaving = true;
    ref.read(onboardingGateProvider).complete();
    context.go('/');
  }

  Future<void> _signIn() async {
    await showLoginDialog(context);
    if (mounted) _next();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.arrowRight) {
      _next();
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _back();
    } else if (key == LogicalKeyboardKey.escape) {
      _leave();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Widget _stepView(int step) => switch (step) {
    0 => WelcomeStep(onNext: _next),
    1 => AccountStep(onSignIn: _signIn, onSkip: _next),
    2 => const WaveStep(),
    3 => const ShortcutsStep(),
    _ => ReadyStep(onFinish: _leave),
  };

  Widget _transition(Widget child, Animation<double> animation) {
    final incoming = child.key == ValueKey(_step);
    final dx = (_forward ? 1 : -1) * .02;
    final slide = Tween(
      begin: Offset(incoming ? dx : -dx, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: animation, curve: kEase));
    return FadeTransition(
      opacity: animation,
      child: SlideTransition(position: slide, child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Column(
          children: [
            _Header(step: _step),
            Expanded(
              child: AnimatedSwitcher(
                duration: reduced
                    ? Duration.zero
                    : const Duration(milliseconds: 360),
                transitionBuilder: _transition,
                layoutBuilder: (current, previous) => Stack(
                  fit: StackFit.expand,
                  children: [...previous, ?current],
                ),
                child: KeyedSubtree(
                  key: ValueKey(_step),
                  child: _stepView(_step),
                ),
              ),
            ),
            if (_step > 0 && _step < _names.length - 1)
              _Footer(step: _step, onBack: _back, onNext: _next, onGo: _go),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.step});
  final int step;

  @override
  Widget build(BuildContext context) => DragToMoveArea(
    child: Container(
      // The hidden title bar leaves the macOS window buttons over the top-left
      // corner; sink the header below them.
      height: Platform.isMacOS ? 92 : 72,
      padding: EdgeInsets.fromLTRB(40, Platform.isMacOS ? 20 : 0, 40, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            spacing: 10,
            children: [_MiniLogo(), _Wordmark()],
          ),
          Text(
            '0${step + 1} / 05 · ${_names[step]}',
            style: AppTheme.mono(size: 12, letterSpacing: .48),
          ),
        ],
      ),
    ),
  );
}

class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) => const Text(
    'waveform',
    style: TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      letterSpacing: -.15,
      height: 1,
    ),
  );
}

class _MiniLogo extends StatelessWidget {
  const _MiniLogo();

  static const _bars = [
    (9.0, AppColors.acid),
    (18.0, AppColors.acid),
    (6.0, AppColors.acid),
    (14.0, AppColors.waveDim),
    (11.0, AppColors.waveDim),
  ];

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      height: 18,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        spacing: 2,
        children: [
          for (final (height, color) in _bars)
            Container(
              width: 3,
              height: height,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
        ],
      ),
    ),
  );
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.step,
    required this.onBack,
    required this.onNext,
    required this.onGo,
  });
  final int step;
  final VoidCallback onBack;
  final VoidCallback onNext;
  final ValueChanged<int> onGo;

  @override
  Widget build(BuildContext context) => Container(
    height: 88,
    padding: const EdgeInsets.symmetric(horizontal: 40),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        OnbButton(
          label: 'back',
          primary: false,
          hPad: 18,
          weight: FontWeight.w500,
          onTap: onBack,
        ),
        _Dots(step: step, onGo: onGo),
        OnbButton(label: step == 3 ? 'finish' : 'continue', onTap: onNext),
      ],
    ),
  );
}

class _Dots extends StatelessWidget {
  const _Dots({required this.step, required this.onGo});
  final int step;
  final ValueChanged<int> onGo;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: 6,
    children: [
      for (var i = 0; i < _names.length; i++)
        Semantics(
          button: true,
          label: 'go to ${_names[i]}',
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onGo(i),
              child: Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 2),
                alignment: Alignment.center,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 360),
                  curve: const Cubic(.2, .9, .25, 1),
                  width: i == step ? 28 : 10,
                  height: 4,
                  decoration: BoxDecoration(
                    color: i == step ? AppColors.acid : AppColors.waveDim,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );
}
