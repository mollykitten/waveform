import 'package:flutter/material.dart';

import '../../app/theme/colors.dart';

/// Keeps an action group together, moving it below the information when needed.
class WaveControlRow extends StatelessWidget {
  const WaveControlRow({
    super.key,
    required this.information,
    required this.actions,
  });
  final Widget information;
  final Widget? actions;

  @override
  Widget build(BuildContext context) => actions == null
      ? information
      : LayoutBuilder(
          builder: (context, constraints) => OverflowBar(
            alignment: MainAxisAlignment.spaceBetween,
            overflowAlignment: OverflowBarAlignment.end,
            spacing: 12,
            overflowSpacing: 8,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                child: information,
              ),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                child: actions!,
              ),
            ],
          ),
        );
}

/// A hairline indeterminate rail: an orange sliver travelling along a dim
/// track. Static under reduced motion.
class WaveProgressRail extends StatefulWidget {
  const WaveProgressRail({super.key});
  @override
  State<WaveProgressRail> createState() => _WaveProgressRailState();
}

class _WaveProgressRailState extends State<WaveProgressRail>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 2,
    child: AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => CustomPaint(
        painter: _RailPainter(_controller.value),
        size: const Size.fromHeight(2),
      ),
    ),
  );
}

class _RailPainter extends CustomPainter {
  _RailPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = AppColors.waveDim.withValues(alpha: .6),
    );
    final eased = Curves.easeInOut.transform(t);
    final width = size.width * .28;
    final left = -width + (size.width + width) * eased;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(
      Rect.fromLTWH(left, 0, width, size.height),
      Paint()..color = AppColors.acid,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RailPainter old) => old.t != t;
}
