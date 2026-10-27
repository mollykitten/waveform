import 'package:flutter/material.dart';

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
