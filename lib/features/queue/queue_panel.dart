import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../../shared/models/track.dart';
import '../../shared/widgets/cover_art.dart';
import '../../shared/widgets/pressable.dart';
import '../player/player_controller.dart';
import 'queue_visibility.dart';

/// Правая queue-панель. Сверху — playing-карточка, под ней — реорордерится
/// список "up next". Закрыть — крестик в шапке или toggle в TopBar.
class QueuePanel extends ConsumerStatefulWidget {
  const QueuePanel({super.key});

  @override
  ConsumerState<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends ConsumerState<QueuePanel> {
  // Программные (не tab-stop) точки фокуса строк, чтобы после перестановки
  // или удаления фокус оставался на осмысленном элементе.
  final Map<String, FocusNode> _rowFocus = {};
  final FocusNode _emptyFocus = FocusNode(
    debugLabel: 'queue empty',
    skipTraversal: true,
  );

  @override
  void dispose() {
    for (final node in _rowFocus.values) {
      node.dispose();
    }
    _emptyFocus.dispose();
    super.dispose();
  }

  FocusNode _focusFor(String id) => _rowFocus.putIfAbsent(
    id,
    () => FocusNode(debugLabel: 'queue row $id', skipTraversal: true),
  );

  void _pruneFocus(Set<String> liveIds) {
    final stale = _rowFocus.keys.where((id) => !liveIds.contains(id)).toList();
    if (stale.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final id in stale) {
        _rowFocus.remove(id)?.dispose();
      }
    });
  }

  void _afterMutation(VoidCallback focusStep) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) focusStep();
    });
  }

  void _move(PlayerController pc, List<Track> upcoming, int index, int delta) {
    final target = index + delta;
    if (target < 0 || target >= upcoming.length) return;
    final id = upcoming[index].id;
    // ReorderableListView: вставка «после» элемента задаётся индексом + 1.
    pc.reorderUpcoming(index, delta < 0 ? target : target + 1);
    _afterMutation(() {
      // Кнопка, ставшая недоступной на границе, роняет фокус — возвращаем
      // его на ту же строку; иначе фокус остался на нажатой кнопке.
      final focused = FocusManager.instance.primaryFocus;
      if (focused == null ||
          !focused.canRequestFocus ||
          focused.context == null) {
        _rowFocus[id]?.requestFocus();
      }
    });
  }

  void _remove(PlayerController pc, List<Track> upcoming, int index) {
    final neighbour = index + 1 < upcoming.length
        ? upcoming[index + 1].id
        : (index > 0 ? upcoming[index - 1].id : null);
    pc.removeFromQueue(upcoming[index].id);
    _afterMutation(() {
      final node = neighbour == null ? _emptyFocus : _rowFocus[neighbour];
      node?.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerControllerProvider);
    // Подписка на queueVersion → когда меняется queue, перечитываем upcoming.
    ref.watch(playerControllerProvider.select((s) => s.queueVersion));
    final pc = ref.read(playerControllerProvider.notifier);
    final upcoming = pc.upcomingTracks;
    final current = player.track;
    _pruneFocus({for (final t in upcoming) t.id});

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(left: AppTheme.borderSideStatic),
      ),
      child: Column(
        children: [
          _Header(
            current: current,
            upcomingCount: upcoming.length,
            onClose: () => ref.read(queueVisibleProvider.notifier).hide(),
          ),
          const Divider(color: AppColors.border, height: 0.5, thickness: 0.5),
          Expanded(
            child: upcoming.isEmpty
                ? _EmptyUpcoming(focusNode: _emptyFocus)
                : ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                    itemCount: upcoming.length,
                    buildDefaultDragHandles: false,
                    onReorder: pc.reorderUpcoming,
                    proxyDecorator: (child, _, _) =>
                        Material(color: Colors.transparent, child: child),
                    itemBuilder: (context, index) {
                      final t = upcoming[index];
                      return _QueueRow(
                        key: ValueKey('q-${t.id}'),
                        track: t,
                        index: index,
                        count: upcoming.length,
                        focusNode: _focusFor(t.id),
                        onMoveUp: () => _move(pc, upcoming, index, -1),
                        onMoveDown: () => _move(pc, upcoming, index, 1),
                        onRemove: () => _remove(pc, upcoming, index),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.current,
    required this.upcomingCount,
    required this.onClose,
  });
  final Track? current;
  final int upcomingCount;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'QUEUE',
                  style: AppTheme.mono(
                    size: 10,
                    color: AppColors.textLow,
                    weight: FontWeight.w600,
                    letterSpacing: 1.4,
                  ),
                ),
              ),
              Pressable(
                onTap: onClose,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.close, size: 14, color: AppColors.textMid),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (current != null)
            Row(
              children: [
                CoverArt(
                  seed: current!.id,
                  imageUrl: current!.coverUrl,
                  size: 40,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        current!.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textHi,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        current!.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.mono(
                          size: 11,
                          color: AppColors.textMid,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            )
          else
            Text(
              'nothing playing',
              style: AppTheme.mono(size: 12, color: AppColors.textMid),
            ),
          const SizedBox(height: 12),
          Text(
            upcomingCount == 0 ? 'UP NEXT' : 'UP NEXT · $upcomingCount',
            style: AppTheme.mono(
              size: 10,
              color: AppColors.textLow,
              weight: FontWeight.w600,
              letterSpacing: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyUpcoming extends StatelessWidget {
  const _EmptyUpcoming({required this.focusNode});
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: focusNode,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: Text(
            'queue is empty\nplay a playlist to see what\'s next',
            textAlign: TextAlign.center,
            style: AppTheme.mono(size: 11, color: AppColors.textLow),
          ),
        ),
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    super.key,
    required this.track,
    required this.index,
    required this.count,
    required this.focusNode,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onRemove,
  });
  final Track track;
  final int index;
  final int count;
  final FocusNode focusNode;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: focusNode,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.bg,
          borderRadius: AppTheme.borderRadius,
          border: AppTheme.border(),
        ),
        child: Row(
          children: [
            Pressable(
              onTap: () => context.push('/track/${track.id}'),
              child: CoverArt(
                seed: track.id,
                imageUrl: track.coverUrl,
                size: 36,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textHi,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.mono(size: 10, color: AppColors.textMid),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            _RowAction(
              label: 'move ${track.title} up',
              icon: Icons.keyboard_arrow_up,
              onTap: index > 0 ? onMoveUp : null,
            ),
            _RowAction(
              label: 'move ${track.title} down',
              icon: Icons.keyboard_arrow_down,
              onTap: index < count - 1 ? onMoveDown : null,
            ),
            _RowAction(
              label: 'remove ${track.title} from queue',
              icon: Icons.close,
              onTap: onRemove,
            ),
            // Drag-handle для ReorderableListView. Помещаем в самый правый край.
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.only(left: 2, right: 4),
                child: Icon(
                  Icons.drag_handle,
                  size: 16,
                  color: AppColors.textLow,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Именованная иконка-кнопка строки очереди; `onTap == null` — недоступна
/// (граница списка), Pressable сам исключает её из фокуса и действий.
class _RowAction extends StatelessWidget {
  const _RowAction({
    required this.label,
    required this.icon,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: Pressable(
        onTap: onTap,
        enabled: onTap != null,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            icon,
            size: 14,
            color: onTap == null ? AppColors.border : AppColors.textLow,
          ),
        ),
      ),
    );
  }
}
