import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';

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
  final _focusNode = FocusNode(debugLabel: 'Pressable');

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_focusChanged);
  }

  void _focusChanged() => setState(() {});

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (!node.hasPrimaryFocus || !widget.enabled || widget.onTap == null) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.enter &&
        event.logicalKey != LogicalKeyboardKey.space) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) widget.onTap?.call();
    return KeyEventResult.handled;
  }

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
    final content = MouseRegion(
      cursor: active ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        excludeFromSemantics: widget.onTap != null,
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
    // Without an action this is a structural wrapper: descendants retain
    // their own semantics, focus traversal and keyboard handling.
    if (widget.onTap == null) return content;
    final focused = active && _focusNode.hasPrimaryFocus;
    return Semantics(
      button: true,
      enabled: active,
      focusable: active,
      focused: active ? focused : null,
      onTap: active ? widget.onTap : null,
      child: Focus(
        focusNode: _focusNode,
        canRequestFocus: active,
        skipTraversal: !active,
        includeSemantics: false,
        onKeyEvent: _handleKey,
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: AppTheme.borderRadius,
            border: focused ? AppTheme.border(AppColors.acid) : null,
          ),
          child: content,
        ),
      ),
    );
  }
}
