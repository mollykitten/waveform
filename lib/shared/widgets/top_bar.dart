import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:window_manager/window_manager.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../../core/api/feeds.dart';
import '../../core/api/soundcloud_auth.dart';
import '../../features/auth/login_dialog.dart';
import '../../features/omnibox/omnibox_providers.dart';
import '../../features/player/player_controller.dart';
import '../../features/queue/queue_visibility.dart';
import 'cover_art.dart';
import 'pressable.dart';
import 'wave_logo.dart';

/// Верхняя панель оболочки: лого, навигация Home/Feed/Library, поиск,
/// аккаунт (логин/логаут). Активный пункт — по маршруту.
class TopBar extends ConsumerWidget {
  const TopBar({super.key, required this.location});

  final String location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // На macOS оставляем место слева под «светофор» окна.
    // На macOS Flutter-окно использует `titlebarAppearsTransparent` — traffic
    // lights висят поверх контента в верхней-левой зоне. Резервируем 28px
    // сверху на эту зону через `padding`, влево контент идёт от 16px.
    const leftPad = 16.0;
    const topPad = 28.0;
    // Перетаскивание окна — ТОЛЬКО за лого/заголовок и центральную пустую зону.
    // Интерактивные кнопки (поиск, очередь, настройки, аккаунт) вынесены из
    // DragToMoveArea: раньше весь бар был draggable, и двойной клик по кнопкам
    // на macOS разворачивал окно (zoom), а сама draggable-зона была слишком
    // большой. На Windows/Linux это единственный способ двигать окно
    // (titleBarStyle: hidden).
    return Container(
      height: AppTheme.topBarHeight,
      padding: const EdgeInsets.fromLTRB(leftPad, topPad, 16, 0),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.72),
        border: const Border(bottom: AppTheme.borderSideStatic),
      ),
      child: Row(
        children: [
          DragToMoveArea(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const WaveLogo(),
                const SizedBox(width: 10),
                Text(
                  'waveform',
                  style: AppTheme.mono(
                    size: 15,
                    color: AppColors.textHi,
                    weight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 32),
          _NavLink('home', '/', location),
          _NavLink('feed', '/feed', location),
          _NavLink('library', '/library', location),
          _NavLink('discover', '/recommendations', location),
          // Гибкая пустая зона — тоже draggable (но НЕ кнопки справа).
          Expanded(child: DragToMoveArea(child: const SizedBox.expand())),
          const SizedBox(width: 16),
          Flexible(
            flex: 4,
            child: Align(
              alignment: Alignment.centerRight,
              child: SizedBox(width: 240, child: const _SearchField()),
            ),
          ),
          const SizedBox(width: 16),
          if (kDebugMode) ...[
            Pressable(
              onTap: () => context.push('/logs'),
              child: Tooltip(
                message: 'logs',
                child: Icon(Icons.terminal, size: 16, color: AppColors.textLow),
              ),
            ),
            const SizedBox(width: 14),
          ],
          Consumer(
            builder: (context, ref, _) {
              final on = ref.watch(queueVisibleProvider);
              return Pressable(
                onTap: () => ref.read(queueVisibleProvider.notifier).toggle(),
                child: Tooltip(
                  message: 'queue',
                  child: Icon(
                    Icons.queue_music,
                    size: 16,
                    color: on ? AppColors.acid : AppColors.textLow,
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: 14),
          Pressable(
            // Гард от наслоения окон настроек: не пушим /settings, если уже на нём.
            onTap: () {
              if (location != '/settings') context.push('/settings');
            },
            child: const Tooltip(
              message: 'settings',
              child: Icon(
                Icons.settings_outlined,
                size: 16,
                color: AppColors.textLow,
              ),
            ),
          ),
          const SizedBox(width: 14),
          const _Account(),
        ],
      ),
    );
  }
}

/// Аккаунт: разлогинен → кнопка «log in»; залогинен → аватар с меню (logout).
class _Account extends ConsumerWidget {
  const _Account();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authed = ref.watch(authControllerProvider).isAuthenticated;

    if (!authed) {
      return Pressable(
        onTap: () => showLoginDialog(context),
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.acid,
            borderRadius: AppTheme.borderRadius,
          ),
          child: Text(
            'log in',
            style: AppTheme.mono(
              size: 12,
              color: AppColors.bg,
              weight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    // Реальная аватарка из профиля (/me через rail); до загрузки — процедурная.
    final me = ref.watch(railProvider).asData?.value.me;
    return PopupMenuButton<String>(
      tooltip: 'account',
      color: AppColors.surface2,
      shape: const RoundedRectangleBorder(borderRadius: AppTheme.borderRadius),
      onSelected: (v) {
        if (v == 'logout') ref.read(authControllerProvider.notifier).signOut();
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'logout',
          child: Text(
            'log out',
            style: AppTheme.mono(size: 12, color: AppColors.textHi),
          ),
        ),
      ],
      child: CoverArt(
        seed: 'me',
        imageUrl: me?.avatarUrl,
        size: 30,
        circular: true,
      ),
    );
  }
}

class _NavLink extends StatelessWidget {
  const _NavLink(this.label, this.path, this.location);

  final String label;
  final String path;
  final String location;

  bool get _active => path == '/' ? location == '/' : location.startsWith(path);

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => context.go(path),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: _active ? FontWeight.w600 : FontWeight.w400,
              color: _active ? AppColors.textHi : AppColors.textMid,
            ),
          ),
        ),
      ),
    );
  }
}

/// Триггер-поле в TopBar — визуально похоже на input, но при тапе открывает
/// центральную ⌘K-палитру. Сам ввод и результаты — в overlay'е (см. AppShell).
/// Placeholder подмешивает now-playing для дополнительной discoverability.
class _SearchField extends ConsumerWidget {
  const _SearchField();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(playerControllerProvider).track;
    final controller = ref.watch(omniboxControllerProvider);

    return GestureDetector(
      onTap: () => ref.read(omniboxOpenProvider.notifier).open(),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          width: double.infinity,
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: AppColors.bg,
            borderRadius: AppTheme.borderRadius,
            border: AppTheme.border(),
          ),
          child: Row(
            children: [
              const Icon(Icons.search, size: 15, color: AppColors.textLow),
              const SizedBox(width: 8),
              Expanded(
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller,
                  builder: (context, value, _) {
                    final hasQuery = value.text.isNotEmpty;
                    final display = hasQuery
                        ? value.text
                        : (track != null
                              ? 'playing: ${track.artist} — ${track.title}'
                              : 'search tracks, artists, playlists…');
                    return Text(
                      display,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: hasQuery ? AppColors.textHi : AppColors.textLow,
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 8),
              // Кейбординг-хинт.
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  border: AppTheme.border(),
                ),
                child: Text(
                  '⌘K',
                  style: AppTheme.mono(
                    size: 9,
                    color: AppColors.textLow,
                    weight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
