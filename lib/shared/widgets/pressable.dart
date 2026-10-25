import 'package:flutter/material.dart';

/// Apple-like тактильность: лёгкое spring-сжатие при нажатии + pointer-курсор.
/// Оборачивает любой интерактивный элемент.
///
/// Hover-подсветка специально НЕ рисуется — для разнородных детей (круг,
/// прямоугольник, ряд) она выглядела как квадратное halo вне формы. Если
/// нужен hover-эффект, реализуй его на самом ребёнке (border/opacity/scale).
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.scale = 0.97,
    this.enabled = true,
    @Deprecated('No-op; hover fill was removed') this.hoverFill = false,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double scale;
  final bool enabled;
  final bool hoverFill;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  @override
  void didUpdateWidget(covariant Pressable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled || widget.onTap == null) _down = false;
  }

  void _setDown(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && widget.onTap != null;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return MouseRegion(
      cursor: active ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTap: active ? widget.onTap : null,
        onTapDown: active ? (_) => _setDown(true) : null,
        onTapUp: active ? (_) => _setDown(false) : null,
        onTapCancel: active ? () => _setDown(false) : null,
        child: AnimatedScale(
          scale: active && _down && !reducedMotion ? widget.scale : 1,
          duration: reducedMotion
              ? Duration.zero
              : Duration(milliseconds: _down ? 90 : 220),
          // Лёгкий «отскок» на отпускании — пружинный характер.
          curve: _down ? Curves.easeOut : Curves.easeOutBack,
          child: widget.child,
        ),
      ),
    );
  }
}
