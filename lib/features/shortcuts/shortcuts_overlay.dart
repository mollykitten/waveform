import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';

class ShortcutsOverlayOpen extends Notifier<bool> {
  @override
  bool build() => false;
  void open() => state = true;
  void close() => state = false;
}

final shortcutsOverlayOpenProvider =
    NotifierProvider<ShortcutsOverlayOpen, bool>(ShortcutsOverlayOpen.new);

/// Канонический список — единственный источник правды для подсказки.
const kShortcutRows = <(String, String)>[
  ('space', 'play / pause'),
  ('→ / ←', 'seek ±5s'),
  ('shift + → / ←', 'next / previous track'),
  ('shift + ↑ / ↓', 'volume up / down'),
  ('M', 'mute'),
  ('L', 'like playing track'),
  ('shift + L', 'repeat'),
  ('R', 'repost playing track'),
  ('0 … 9', 'seek to position'),
  ('P', 'go to playing track'),
  ('S', 'search'),
  ('shift + S', 'shuffle'),
  ('Q', 'show queue'),
  ('H', 'this help'),
  ('G then L / S / C / P / H', 'go to likes / feed / library / profile / history'),
  ('⌘K', 'command palette'),
  ('⌘L', 'go to likes'),
  ('⌘,', 'settings'),
  ('⌘⇧L', 'logs'),
  ('⌘⇧C', 'copy link'),
];

/// Full-screen blur modal listing all keyboard shortcuts.
/// Mirrors the visual idiom of the ⌘K omnibox overlay.
class ShortcutsOverlay extends ConsumerWidget {
  const ShortcutsOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void close() =>
        ref.read(shortcutsOverlayOpenProvider.notifier).close();

    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) {
        if (e is KeyDownEvent &&
            (e.logicalKey == LogicalKeyboardKey.escape ||
                e.logicalKey == LogicalKeyboardKey.keyH)) {
          close();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Stack(
        children: [
          // Backdrop blur + dim scrim. Tap anywhere outside the card closes.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: close,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Container(
                    color: AppColors.bg.withValues(alpha: 0.45)),
              ),
            ),
          ),
          // Centred card. GestureDetector absorbs taps so they don't bubble
          // to the scrim and close the overlay.
          Center(
            child: GestureDetector(
              onTap: () {},
              behavior: HitTestBehavior.opaque,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Container(
                  margin: const EdgeInsets.all(24),
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: AppTheme.borderRadius,
                    border: AppTheme.border(),
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Keyboard shortcuts',
                          style: TextStyle(
                            color: AppColors.textHi,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 16),
                        for (final (keys, label) in kShortcutRows)
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 220,
                                  child: Text(
                                    keys,
                                    style: AppTheme.mono(
                                      size: 12,
                                      color: AppColors.textHi,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    label,
                                    style: const TextStyle(
                                      color: AppColors.textMid,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
