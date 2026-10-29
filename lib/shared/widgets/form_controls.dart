import 'package:flutter/material.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import 'pressable.dart';

/// The compact typography used by ordinary form labels and supporting copy.
const formTextStyle = TextStyle(
  fontSize: 12,
  height: 1.5,
  color: AppColors.textMid,
);
const formHeadingStyle = TextStyle(
  fontSize: 14,
  height: 1.5,
  fontWeight: FontWeight.w600,
  color: AppColors.textHi,
);

/// Visual priority of an action within a form group.
enum FormActionKind { primary, secondary, quiet }

/// A shared form action retaining Pressable's focus and keyboard behavior.
class FormAction extends StatelessWidget {
  const FormAction({
    super.key,
    required this.label,
    this.onTap,
    this.kind = FormActionKind.secondary,
    this.icon,
    this.iconSize = 14,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
    this.busy = false,
    this.busyLabel,
    this.selected = false,
  });
  final String label;
  final VoidCallback? onTap;
  final FormActionKind kind;
  final IconData? icon;
  final double iconSize;

  /// Allows an inline action to align its leading edge with nearby fields.
  final EdgeInsetsGeometry padding;
  final bool busy;
  final String? busyLabel;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final primary = kind == FormActionKind.primary;
    final quiet = kind == FormActionKind.quiet;
    final active = onTap != null && !busy;
    final color = primary
        ? AppColors.bg
        : active || busy
        ? (quiet ? AppColors.textMid : AppColors.textHi)
        : AppColors.textLow;
    Widget content(String text, {bool loading = false}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null || busyLabel != null) ...[
          SizedBox(
            width: iconSize,
            height: iconSize,
            child: loading
                ? CircularProgressIndicator(strokeWidth: 1.5, color: color)
                : icon == null
                ? const SizedBox()
                : Icon(icon, size: iconSize, color: color),
          ),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ),
      ],
    );
    return Semantics(
      selected: selected,
      child: Pressable(
        enabled: active,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 36),
          padding: padding,
          decoration: BoxDecoration(
            color: primary
                ? AppColors.acid
                : quiet
                ? Colors.transparent
                : AppColors.surface2,
            borderRadius: AppTheme.borderRadius,
            border: quiet
                ? null
                : AppTheme.border(
                    selected || primary
                        ? AppColors.acid
                        : active
                        ? AppColors.waveDim
                        : AppColors.borderDim,
                  ),
          ),
          child: busy
              ? Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    Visibility(
                      visible: false,
                      maintainSize: true,
                      maintainAnimation: true,
                      maintainState: true,
                      child: content(label),
                    ),
                    Positioned.fill(
                      child: content(busyLabel ?? label, loading: true),
                    ),
                  ],
                )
              : content(label),
        ),
      ),
    );
  }
}

/// A field label stays above the input, including while empty and unfocused.
class FormFieldLabel extends StatelessWidget {
  const FormFieldLabel({super.key, required this.label, required this.child});
  final String label;
  final Widget child;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(label, style: formTextStyle),
      const SizedBox(height: 8),
      Semantics(label: label, child: child),
    ],
  );
}

/// Consistent decoration for multiline and technical form inputs.
InputDecoration formInputDecoration({String? hint}) {
  const border = OutlineInputBorder(
    borderRadius: AppTheme.borderRadius,
    borderSide: AppTheme.borderSideStatic,
  );
  return InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(
      fontSize: 13,
      height: 1.5,
      color: AppColors.textMid,
    ),
    counterText: '',
    filled: true,
    fillColor: AppColors.bg,
    isDense: true,
    constraints: const BoxConstraints(minHeight: 40),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    border: border,
    enabledBorder: border,
    disabledBorder: border,
    focusedBorder: border.copyWith(
      borderSide: const BorderSide(color: AppColors.acid, width: .5),
    ),
  );
}
