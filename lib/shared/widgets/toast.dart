import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import 'pressable.dart';

/// Кнопка-действие внутри тоста (например «open in Waveform» / «verify»).
typedef ToastAction = ({String label, VoidCallback onTap});

/// Показывает тост справа-вверху экрана. Закрывается тапом по телу (вложенные
/// кнопки работают отдельно — gesture arena отдаёт тап `Pressable`'у действия)
/// и авто-исчезает через [duration]. На overlay'е, а не `SnackBar`: тот
/// привязан к низу экрана и не умеет top-right.
void showToast(
  BuildContext context,
  String message, {
  ToastAction? action,
  Duration duration = const Duration(seconds: 4),
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  _ToastManager.instance.show(overlay, message, action, duration);
}

class _ToastEntry {
  _ToastEntry(this.id, this.message, this.action, this.duration);
  final int id;
  final String message;
  final ToastAction? action;
  final Duration duration;
}

/// Глобальный менеджер: держит один OverlayEntry со стопкой тостов справа-вверху.
class _ToastManager {
  _ToastManager._();
  static final _ToastManager instance = _ToastManager._();

  final List<_ToastEntry> _entries = [];
  final ValueNotifier<List<_ToastEntry>> _notifier =
      ValueNotifier<List<_ToastEntry>>(const []);
  OverlayEntry? _overlayEntry;
  int _seq = 0;

  void show(
    OverlayState overlay,
    String message,
    ToastAction? action,
    Duration duration,
  ) {
    final entry = _ToastEntry(++_seq, message, action, duration);
    _entries.add(entry);
    _notifier.value = List.of(_entries);
    if (_overlayEntry == null) {
      _overlayEntry = OverlayEntry(
        builder: (_) => _ToastLayer(notifier: _notifier, onDismiss: dismiss),
      );
      overlay.insert(_overlayEntry!);
    }
    Future.delayed(duration, () => dismiss(entry.id));
  }

  void dismiss(int id) {
    final before = _entries.length;
    _entries.removeWhere((e) => e.id == id);
    if (_entries.length == before) return;
    _notifier.value = List.of(_entries);
    if (_entries.isEmpty) {
      _overlayEntry?.remove();
      _overlayEntry = null;
    }
  }
}

class _ToastLayer extends StatelessWidget {
  const _ToastLayer({required this.notifier, required this.onDismiss});
  final ValueListenable<List<_ToastEntry>> notifier;
  final void Function(int id) onDismiss;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: AppTheme.topBarHeight + 12,
      right: 16,
      // Material-предок: без него Text в Overlay рисуется с жёлтым двойным
      // подчёркиванием (индикатор «нет Material ancestor»).
      child: Material(
        type: MaterialType.transparency,
        child: ValueListenableBuilder<List<_ToastEntry>>(
          valueListenable: notifier,
          builder: (_, entries, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final e in entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _ToastCard(
                    key: ValueKey(e.id),
                    entry: e,
                    onDismiss: () => onDismiss(e.id),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToastCard extends StatefulWidget {
  const _ToastCard({super.key, required this.entry, required this.onDismiss});
  final _ToastEntry entry;
  final VoidCallback onDismiss;

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entry = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _entry.value = 1;
    } else if (_entry.isDismissed) {
      _entry.forward();
    }
  }

  @override
  void dispose() {
    _entry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final onDismiss = widget.onDismiss;
    return AnimatedBuilder(
      animation: _entry,
      builder: (_, child) {
        final t = Curves.easeOutCubic.transform(_entry.value);
        return Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset((1 - t) * 16, 0),
            child: child,
          ),
        );
      },
      child: GestureDetector(
        // Тап по телу тоста закрывает его. Кнопка действия — вложенный
        // Pressable, он выигрывает в gesture arena и не закрывает «случайно».
        onTap: onDismiss,
        behavior: HitTestBehavior.opaque,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 340),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: AppTheme.borderRadius,
            border: AppTheme.border(),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  entry.message,
                  style: AppTheme.mono(size: 12, color: AppColors.textHi),
                ),
              ),
              if (entry.action != null) ...[
                const SizedBox(width: 14),
                Pressable(
                  onTap: () {
                    entry.action!.onTap();
                    onDismiss();
                  },
                  child: Text(
                    entry.action!.label,
                    style: AppTheme.mono(
                      size: 12,
                      color: AppColors.acid,
                      weight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
