import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../models/collection.dart';
import 'cover_art.dart';
import 'pressable.dart';

/// Компактный list-вариант [CollectionCard]: cover слева (квадрат/круг),
/// title + subtitle (mono), счётчик треков (mono справа), chevron. Те же
/// правила маршрутизации по `Collection.target` — карточка сама ведёт.
class CollectionRow extends StatelessWidget {
  const CollectionRow({super.key, required this.item});

  final Collection item;

  void _open(BuildContext context) {
    switch (item.target) {
      case CollectionTarget.track:
        context.push('/track/${item.id}');
      case CollectionTarget.playlist:
        context.push('/playlist/${Uri.encodeComponent(item.id)}');
      case CollectionTarget.artist:
        context.push(
          '/artist/${Uri.encodeComponent(item.handle ?? item.title)}',
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: () => _open(context),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: AppTheme.borderRadius,
          border: AppTheme.border(),
        ),
        child: Row(
          children: [
            // Hero только для track/playlist (artist — круглый, без hero,
            // чтобы не было квадратного halo при анимации).
            _maybeHero(
              item: item,
              child: CoverArt(
                seed: item.coverSeed,
                imageUrl: item.coverUrl,
                size: 44,
                circular: item.isCircular,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textHi,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.mono(size: 11, color: AppColors.textMid),
                  ),
                ],
              ),
            ),
            if (item.trackCount > 0) ...[
              const SizedBox(width: 12),
              Text(
                '${item.trackCount} tracks',
                style: AppTheme.mono(size: 11, color: AppColors.textLow),
              ),
            ],
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, size: 18, color: AppColors.textLow),
          ],
        ),
      ),
    );
  }
}

/// Возвращает [child], обёрнутый в Hero, если коллекция ведёт на trackОrplaylist-
/// деталь (там тоже есть Hero с тем же тегом). Для артиста — возвращает как есть
/// (avatar круглый, Hero rect-shape выглядел бы как halo).
Widget _maybeHero({required Collection item, required Widget child}) {
  switch (item.target) {
    case CollectionTarget.track:
      return Hero(tag: 'cover-track-${item.id}', child: child);
    case CollectionTarget.playlist:
      return Hero(tag: 'cover-playlist-${item.id}', child: child);
    case CollectionTarget.artist:
      return child;
  }
}
