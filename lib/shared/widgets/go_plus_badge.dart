import 'package:flutter/material.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';

/// Маркер GO+ трека (платная подписка SoundCloud) — приглушённый, «заблокировано».
/// Не активный элемент, поэтому без acid: серая рамка + замок.
class GoPlusBadge extends StatelessWidget {
  const GoPlusBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: AppTheme.borderRadius,
        border: AppTheme.border(),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock, size: 9, color: AppColors.textMid),
          const SizedBox(width: 3),
          Text(
            'GO+',
            style: AppTheme.mono(
              size: 10,
              color: AppColors.textMid,
              weight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}
