import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../models/collection.dart';
import 'cover_art.dart';
import 'pressable.dart';

/// Карточка подборки для каруселей и сеток: обложка (квадрат/круг) с оверлеями
/// (MIX-плашка, вордмарк, hover-play) + название и подпись.
class CollectionCard extends StatefulWidget {
  const CollectionCard({super.key, required this.item, this.size = 150});

  final Collection item;
  final double size;

  @override
  State<CollectionCard> createState() => _CollectionCardState();
}

class _CollectionCardState extends State<CollectionCard> {
  bool _hover = false;

  /// Навигация по типу карточки: трек / плейлист / артист.
  void _open() {
    final item = widget.item;
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
    final item = widget.item;
    final circular = item.isCircular;

    return SizedBox(
      width: widget.size,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Pressable(
          onTap: _open,
          child: Column(
            crossAxisAlignment: circular
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.start,
            children: [
              _Cover(item: item, size: widget.size, hover: _hover),
              const SizedBox(height: 10),
              Text(
                item.title,
                textAlign: circular ? TextAlign.center : TextAlign.start,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textHi,
                ),
              ),
              const SizedBox(height: 3),
              _Subtitle(item: item, center: circular),
            ],
          ),
        ),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.item, required this.size, required this.hover});

  final Collection item;
  final double size;
  final bool hover;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          // Подсветка бордера при наведении. Без AnimatedContainer: иначе при
          // переиспользовании ячейки rect↔circle Flutter пытается анимировать
          // декорацию (круг + borderRadius) и падает с ассертом.
          Container(
            decoration: BoxDecoration(
              shape: item.isCircular ? BoxShape.circle : BoxShape.rectangle,
              borderRadius: item.isCircular ? null : AppTheme.borderRadius,
              border: Border.all(
                color: hover ? AppColors.border : Colors.transparent,
                width: AppTheme.borderWidth,
              ),
            ),
            // Hero только для track/playlist — у артиста круг, и rect-Hero
            // оставлял бы квадратный halo на анимации.
            child: _maybeHero(
              item: item,
              child: CoverArt(
                seed: item.coverSeed,
                imageUrl: item.coverUrl,
                size: size,
                circular: item.isCircular,
              ),
            ),
          ),

          // Вордмарк авто-подборок (DAILY DROPS / WEEKLY WAVE).
          if (item.wordmark != null) _Wordmark(text: item.wordmark!),

          // Плашка MIX N.
          if (item.mixLabel != null)
            Positioned(left: 8, bottom: 8, child: _Plate(text: item.mixLabel!)),

          // Hover-play.
          Positioned(
            right: item.isCircular ? size / 2 - 18 : 8,
            bottom: 8,
            child: AnimatedOpacity(
              key: ValueKey(MediaQuery.disableAnimationsOf(context)),
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : AppTheme.motion,
              opacity: hover ? 1 : 0,
              child: Container(
                width: 36,
                height: 36,
                decoration: const BoxDecoration(
                  color: AppColors.acid,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.play_arrow,
                  color: AppColors.bg,
                  size: 22,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Wordmark extends StatelessWidget {
  const _Wordmark({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        alignment: Alignment.bottomLeft,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: AppTheme.borderRadius,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, AppColors.bg.withValues(alpha: 0.55)],
          ),
        ),
        child: Text(
          text,
          style: AppTheme.mono(
            size: 15,
            color: AppColors.textHi,
            weight: FontWeight.w700,
            letterSpacing: 1,
            height: 1.1,
          ),
        ),
      ),
    );
  }
}

class _Plate extends StatelessWidget {
  const _Plate({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.bg.withValues(alpha: 0.78),
        borderRadius: AppTheme.borderRadius,
        border: AppTheme.border(),
      ),
      child: Text(
        text,
        style: AppTheme.mono(
          size: 11,
          color: AppColors.textHi,
          weight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

Widget _maybeHero({required Collection item, required Widget child}) {
  // Missing API ids map to '0'; they do not identify a shared cover.
  if (item.id.isEmpty || item.id == '0') return child;

  switch (item.target) {
    case CollectionTarget.track:
      return Hero(tag: 'cover-track-${item.id}', child: child);
    case CollectionTarget.playlist:
      return Hero(tag: 'cover-playlist-${item.id}', child: child);
    case CollectionTarget.artist:
      return child;
  }
}

class _Subtitle extends StatelessWidget {
  const _Subtitle({required this.item, required this.center});

  final Collection item;
  final bool center;

  @override
  Widget build(BuildContext context) {
    return Text(
      item.subtitle,
      textAlign: center ? TextAlign.center : TextAlign.start,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppTheme.mono(size: 11, color: AppColors.textMid),
    );
  }
}
