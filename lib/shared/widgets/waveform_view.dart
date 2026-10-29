import 'package:flutter/material.dart';

import '../../app/theme/colors.dart';

/// Waveform во всю ширину: прослушанная часть — acid orange, буферизированная
/// (но ещё не сыгранная) — приглушённый acid, остальная — waveDim.
/// Клик вызывает [onSeek] (доля 0..1) сразу; драг — один раз на отпускание,
/// а пока он идёт, курсор рисуется по локальной позиции пальца/мыши.
class WaveformView extends StatefulWidget {
  const WaveformView({
    super.key,
    required this.bars,
    this.progress = 0,
    this.buffered = 0,
    this.onSeek,
    this.height = 64,
    this.markers = const [],
  });

  final List<double> bars;
  final double progress;

  /// Доля буферизированного (0..1). Третий тиер между played и unplayed —
  /// видно «как далеко» зашёл preload (на плохом коннекте — где stall).
  final double buffered;
  final ValueChanged<double>? onSeek;
  final double height;

  /// Доли (0..1) для маркеров комментариев над дорожкой.
  final List<double> markers;

  @override
  State<WaveformView> createState() => _WaveformViewState();
}

class _WaveformViewState extends State<WaveformView> {
  /// Доля под курсором во время драга; null — драга нет.
  double? _dragFraction;

  double _fractionAt(double dx, double width) =>
      width <= 0 ? 0.0 : (dx / width).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final onSeek = widget.onSeek;
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, c) {
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: onSeek == null
                ? null
                : (d) => onSeek(_fractionAt(d.localPosition.dx, c.maxWidth)),
            onHorizontalDragStart: onSeek == null
                ? null
                : (d) => setState(
                    () => _dragFraction = _fractionAt(
                      d.localPosition.dx,
                      c.maxWidth,
                    ),
                  ),
            onHorizontalDragUpdate: onSeek == null
                ? null
                : (d) => setState(
                    () => _dragFraction = _fractionAt(
                      d.localPosition.dx,
                      c.maxWidth,
                    ),
                  ),
            onHorizontalDragEnd: onSeek == null
                ? null
                : (_) {
                    final f = _dragFraction;
                    setState(() => _dragFraction = null);
                    if (f != null) onSeek(f);
                  },
            onHorizontalDragCancel: () {
              if (_dragFraction != null) setState(() => _dragFraction = null);
            },
            child: CustomPaint(
              size: Size(c.maxWidth, widget.height),
              painter: _WaveformPainter(
                bars: widget.bars,
                progress: _dragFraction ?? widget.progress,
                buffered: widget.buffered,
                markers: widget.markers,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.bars,
    required this.progress,
    this.buffered = 0,
    this.markers = const [],
  });

  final List<double> bars;
  final double progress;
  final double buffered;
  final List<double> markers;

  static const double _gap = 1.5;
  static const double _minBar = 2;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;

    // Подгоняем число баров под ширину, чтобы не сжимать в кашу.
    final maxBars = (size.width / (_minBar + _gap)).floor().clamp(
      1,
      bars.length,
    );
    final step = bars.length / maxBars;
    final barWidth = (size.width - _gap * (maxBars - 1)) / maxBars;

    final mid = size.height / 2;
    final playedX = size.width * progress;
    // Граница буфера — никогда левее курсора (защита от bouncing буфера назад
    // при seek в неисчисленные секунды воспроизведения).
    final bufferedX = size.width * buffered.clamp(progress, 1.0);

    final played = Paint()..color = AppColors.acid;
    // Третий тиер: приглушённый acid между played и unplayed.
    final bufferedPaint = Paint()
      ..color = AppColors.acid.withValues(alpha: 0.35);
    final dim = Paint()..color = AppColors.waveDim;

    for (var i = 0; i < maxBars; i++) {
      final amp = bars[(i * step).floor()];
      final h = (amp * size.height).clamp(2.0, size.height);
      final x = i * (barWidth + _gap);
      final rect = Rect.fromLTWH(x, mid - h / 2, barWidth, h);
      final cx = x + barWidth / 2;
      final Paint p;
      if (cx <= playedX) {
        p = played;
      } else if (cx <= bufferedX) {
        p = bufferedPaint;
      } else {
        p = dim;
      }
      canvas.drawRect(rect, p);
    }

    // Маркеры комментариев — маленькие lime-точки над дорожкой.
    final marker = Paint()..color = AppColors.lime;
    for (final f in markers) {
      canvas.drawCircle(Offset(size.width * f, 3), 2.2, marker);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress ||
      old.buffered != buffered ||
      old.bars != bars ||
      old.markers != markers;
}
