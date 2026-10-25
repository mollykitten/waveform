import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../../core/api/feeds.dart';
import '../../core/api/soundcloud_auth.dart';
import '../../core/audio/playback_prefs.dart';
import '../../core/cache/image_cache.dart';
import '../../core/deeplinks/clipboard_watcher.dart';
import '../../core/lastfm/lastfm_constants.dart';
import '../../core/lastfm/lastfm_session.dart';
import '../../core/log/talker.dart';
import '../../shared/url_share.dart';
import '../../shared/widgets/cover_art.dart';
import '../../shared/widgets/pressable.dart';
import '../../shared/widgets/section_header.dart';
import '../../shared/widgets/toast.dart';
import '../../shared/widgets/view_toggle.dart';
import '../auth/login_dialog.dart';

/// Версия отображается в секции About; обновлять руками синхронно с pubspec.yaml.
// Bumped on every tagged release. Matches `version:` in pubspec.yaml.
const _kAppVersion = '0.3.0';
const _kRepoUrl = 'https://github.com/mollybyte/waveform';

/// Экран настроек. Сейчас покрывает то, что реально реализовано: аккаунт,
/// вид списков, кэш обложек, выход на логи и about. Тема / Last.fm / качество
/// стрима появятся, когда сама фича в коде заведётся.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.pagePad,
            AppTheme.topBarHeight + 20,
            AppTheme.pagePad,
            AppTheme.playerHeight + 32,
          ),
          children: const [
            _Back(),
            SizedBox(height: 16),
            _Title(),
            SizedBox(height: 28),
            _AccountSection(),
            SizedBox(height: 28),
            _ViewSection(),
            SizedBox(height: 28),
            _LinksSection(),
            SizedBox(height: 28),
            _PlaybackSection(),
            SizedBox(height: 28),
            _ShortcutsSection(),
            SizedBox(height: 28),
            _LastfmSection(),
            SizedBox(height: 28),
            _CacheSection(),
            SizedBox(height: 28),
            _LogsSection(),
            SizedBox(height: 28),
            _AboutSection(),
          ],
        ),
      ),
    );
  }
}

class _Back extends StatelessWidget {
  const _Back();
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Pressable(
        onTap: () => context.canPop() ? context.pop() : context.go('/'),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.chevron_left, size: 18, color: AppColors.textMid),
            Text(
              'back',
              style: AppTheme.mono(size: 12, color: AppColors.textMid),
            ),
          ],
        ),
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title();
  @override
  Widget build(BuildContext context) {
    return const Text(
      'settings',
      style: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        color: AppColors.textHi,
      ),
    );
  }
}

class _AccountSection extends ConsumerWidget {
  const _AccountSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authed = ref.watch(authControllerProvider).isAuthenticated;
    final me = ref.watch(railProvider).asData?.value.me;
    return _Section(
      title: 'account',
      child: authed
          ? Row(
              children: [
                CoverArt(
                  seed: 'artist-${me?.handle ?? 'me'}',
                  imageUrl: me?.avatarUrl,
                  size: 44,
                  circular: true,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        me?.name ?? 'logged in',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textHi,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '@${me?.handle ?? ''}',
                        style: AppTheme.mono(
                          size: 11,
                          color: AppColors.textMid,
                        ),
                      ),
                    ],
                  ),
                ),
                _Button(
                  label: 'sign out',
                  onTap: () =>
                      ref.read(authControllerProvider.notifier).signOut(),
                ),
              ],
            )
          : Row(
              children: [
                Expanded(
                  child: Text(
                    'not signed in',
                    style: AppTheme.mono(size: 12, color: AppColors.textMid),
                  ),
                ),
                _Button(
                  label: 'sign in',
                  onTap: () => showLoginDialog(context),
                ),
              ],
            ),
    );
  }
}

/// Справка по всем глобальным шорткатам. Платформа определяется один раз
/// (Cmd на macOS, Ctrl на остальных) — соответствует логике в AppShell.
class _ShortcutsSection extends StatelessWidget {
  const _ShortcutsSection();

  @override
  Widget build(BuildContext context) {
    // ВНИМАНИЕ: держать в синхроне с web-parity биндингами —
    // `lib/app/shortcut_bindings.dart` и `kShortcutRows`
    // (`lib/features/shortcuts/shortcuts_overlay.dart`, оверлей по клавише H).
    final mac = Platform.isMacOS;
    final mod = mac ? '⌘' : 'Ctrl';
    final shift = mac ? '⇧' : 'Shift';
    return _Section(
      title: 'shortcuts',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ShortcutGroup('playback', [
            _ShortcutRow(['Space'], 'play / pause'),
            _ShortcutRow(['→'], 'seek forward 5s'),
            _ShortcutRow(['←'], 'seek backward 5s'),
            _ShortcutRow([shift, '→'], 'next track'),
            _ShortcutRow([shift, '←'], 'previous track'),
            _ShortcutRow([shift, '↑'], 'volume up'),
            _ShortcutRow([shift, '↓'], 'volume down'),
            _ShortcutRow(['M'], 'mute'),
            _ShortcutRow(['0–9'], 'seek to position (0–90%)'),
          ]),
          _ShortcutGroup('playing track', [
            _ShortcutRow(['L'], 'like'),
            _ShortcutRow([shift, 'L'], 'repeat'),
            _ShortcutRow(['R'], 'repost'),
            _ShortcutRow([shift, 'S'], 'shuffle'),
            _ShortcutRow(['P'], 'go to playing track'),
          ]),
          _ShortcutGroup('view & search', [
            _ShortcutRow(['S'], 'search'),
            _ShortcutRow(['Q'], 'toggle queue'),
            _ShortcutRow(['H'], 'this shortcuts list'),
          ]),
          _ShortcutGroup('go to — tap G, then a key', [
            _ShortcutRow(['G', 'L'], 'likes'),
            _ShortcutRow(['G', 'S'], 'feed'),
            _ShortcutRow(['G', 'C'], 'library'),
            _ShortcutRow(['G', 'P'], 'profile'),
            _ShortcutRow(['G', 'H'], 'history'),
          ]),
          _ShortcutGroup('navigation', [
            _ShortcutRow([mod, 'K'], 'open command palette'),
            _ShortcutRow([mod, 'L'], 'jump to likes'),
            _ShortcutRow([mod, ','], 'open settings'),
            _ShortcutRow([mod, shift, 'L'], 'open logs'),
            _ShortcutRow([mod, shift, 'C'], 'copy current link'),
          ]),
          _ShortcutGroup('on /track page', [
            _ShortcutRow(['↵'], 'play / resume this track'),
          ]),
          _ShortcutGroup('inside command palette', [
            _ShortcutRow(['↑', '↓'], 'move highlight between results'),
            _ShortcutRow(['↵'], 'open selected result'),
            _ShortcutRow(['Esc'], 'close palette'),
          ]),
        ],
      ),
    );
  }
}

class _ShortcutGroup extends StatelessWidget {
  const _ShortcutGroup(this.title, this.rows);
  final String title;
  final List<_ShortcutRow> rows;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              title.toUpperCase(),
              style: AppTheme.mono(
                size: 9,
                color: AppColors.textLow,
                weight: FontWeight.w700,
                letterSpacing: 1.4,
              ),
            ),
          ),
          ...rows,
        ],
      ),
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow(this.keys, this.action);
  final List<String> keys;
  final String action;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          // Фиксированная ширина под клавишные капсы — выравниваем колонку.
          SizedBox(
            width: 140,
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (var i = 0; i < keys.length; i++) ...[
                  if (i > 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Text(
                        '+',
                        style: AppTheme.mono(
                          size: 10,
                          color: AppColors.textLow,
                        ),
                      ),
                    ),
                  _KeyCap(label: keys[i]),
                ],
              ],
            ),
          ),
          Expanded(
            child: Text(
              action,
              style: AppTheme.mono(
                size: 12,
                color: AppColors.textHi,
                weight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _KeyCap extends StatelessWidget {
  const _KeyCap({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(3),
        border: AppTheme.border(),
      ),
      child: Text(
        label,
        style: AppTheme.mono(
          size: 10.5,
          color: AppColors.textHi,
          weight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _LastfmSection extends ConsumerStatefulWidget {
  const _LastfmSection();
  @override
  ConsumerState<_LastfmSection> createState() => _LastfmSectionState();
}

class _LastfmSectionState extends ConsumerState<_LastfmSection> {
  bool _busy = false;

  Future<void> _connect() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final client = ref.read(lastfmClientProvider);
      final token = await client.getAuthToken();
      if (token == null) throw 'auth.getToken returned null';
      final authUrl =
          'https://www.last.fm/api/auth/'
          '?api_key=$lastfmApiKey&token=$token';
      await openExternalUrl(authUrl);
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: AppTheme.borderRadius,
            side: const BorderSide(
              color: AppColors.border,
              width: AppTheme.borderWidth,
            ),
          ),
          title: Text(
            'connect last.fm',
            style: AppTheme.mono(
              size: 14,
              color: AppColors.textHi,
              weight: FontWeight.w600,
            ),
          ),
          content: Text(
            'authorize Waveform in your browser, then click continue',
            style: AppTheme.mono(size: 12, color: AppColors.textMid),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: Text(
                'cancel',
                style: AppTheme.mono(size: 12, color: AppColors.textMid),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(c).pop(true),
              child: Text(
                'continue',
                style: AppTheme.mono(
                  size: 12,
                  color: AppColors.acid,
                  weight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
      if (ok != true) return;
      final session = await client.getSession(token);
      if (session == null) throw 'auth.getSession returned null';
      ref
          .read(lastfmSessionProvider.notifier)
          .set(LastfmSession(key: session.key, name: session.name));
      if (mounted) {
        showToast(context, 'connected as @${session.name}');
      }
    } catch (e, st) {
      ref.read(talkerProvider).warning('lastfm connect failed', e, st);
      if (mounted) {
        showToast(context, 'last.fm connect failed');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(lastfmSessionProvider);
    if (!lastfmConfigured) {
      return _Section(
        title: 'last.fm',
        child: Text(
          'Last.fm scrobbling is not configured.\n'
          'Set lastfmApiKey + lastfmSharedSecret in '
          'lib/core/lastfm/lastfm_constants.dart to enable.',
          style: AppTheme.mono(size: 11, color: AppColors.textMid),
        ),
      );
    }
    return _Section(
      title: 'last.fm',
      child: Row(
        children: [
          Expanded(
            child: Text(
              session != null
                  ? 'connected as @${session.name}'
                  : 'scrobble plays to Last.fm',
              style: AppTheme.mono(size: 12, color: AppColors.textMid),
            ),
          ),
          if (session != null)
            _Button(
              label: 'disconnect',
              onTap: () => ref.read(lastfmSessionProvider.notifier).clear(),
            )
          else
            _Button(
              label: _busy ? 'connecting…' : 'connect last.fm',
              onTap: _connect,
            ),
        ],
      ),
    );
  }
}

class _PlaybackSection extends ConsumerWidget {
  const _PlaybackSection();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(playbackPrefsProvider);
    final c = ref.read(playbackPrefsProvider.notifier);
    final ms = prefs.crossfadeMs;
    final label = ms == 0
        ? 'gapless (0 s)'
        : '${(ms / 1000).toStringAsFixed(1)} s crossfade';
    return _Section(
      title: 'playback',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'crossfade between tracks',
                  style: AppTheme.mono(size: 12, color: AppColors.textMid),
                ),
              ),
              Text(
                label,
                style: AppTheme.mono(
                  size: 12,
                  color: AppColors.textHi,
                  weight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 2,
              activeTrackColor: AppColors.acid,
              inactiveTrackColor: AppColors.border,
              thumbColor: AppColors.textHi,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 11),
            ),
            child: Slider(
              value: ms.toDouble(),
              min: 0,
              max: 6000,
              divisions: 12,
              onChanged: (v) => c.setCrossfadeMs(v.round()),
            ),
          ),
        ],
      ),
    );
  }
}

class _LinksSection extends ConsumerWidget {
  const _LinksSection();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(clipboardWatchEnabledProvider);
    return _Section(
      title: 'links',
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'open SoundCloud links from clipboard',
                  style: AppTheme.mono(size: 12, color: AppColors.textMid),
                ),
                const SizedBox(height: 3),
                Text(
                  'copy a soundcloud.com link → offer to open it here',
                  style: AppTheme.mono(size: 10, color: AppColors.textLow),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: on,
            activeThumbColor: AppColors.acid,
            onChanged: (_) =>
                ref.read(clipboardWatchEnabledProvider.notifier).toggle(),
          ),
        ],
      ),
    );
  }
}

class _ViewSection extends StatelessWidget {
  const _ViewSection();
  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'view',
      child: Row(
        children: [
          Expanded(
            child: Text(
              'library & search layout',
              style: AppTheme.mono(size: 12, color: AppColors.textMid),
            ),
          ),
          const ViewToggle(),
        ],
      ),
    );
  }
}

class _CacheSection extends StatefulWidget {
  const _CacheSection();
  @override
  State<_CacheSection> createState() => _CacheSectionState();
}

class _CacheSectionState extends State<_CacheSection> {
  bool _busy = false;

  Future<void> _clear() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await waveformImageCache.emptyCache();
      if (!mounted) return;
      showToast(context, 'cover cache cleared');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'cache',
      child: Row(
        children: [
          Expanded(
            child: Text(
              'clear downloaded cover art',
              style: AppTheme.mono(size: 12, color: AppColors.textMid),
            ),
          ),
          _Button(label: _busy ? 'clearing…' : 'clear', onTap: _clear),
        ],
      ),
    );
  }
}

class _LogsSection extends StatelessWidget {
  const _LogsSection();
  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'logs',
      child: Row(
        children: [
          Expanded(
            child: Text(
              'in-app Talker log screen',
              style: AppTheme.mono(size: 12, color: AppColors.textMid),
            ),
          ),
          _Button(label: 'open', onTap: () => context.push('/logs')),
        ],
      ),
    );
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection();
  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'about',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'version',
                  style: AppTheme.mono(size: 12, color: AppColors.textMid),
                ),
              ),
              Text(
                _kAppVersion,
                style: AppTheme.mono(
                  size: 12,
                  color: AppColors.textHi,
                  weight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Text(
                  'source code',
                  style: AppTheme.mono(size: 12, color: AppColors.textMid),
                ),
              ),
              _Button(label: 'open ↗', onTap: () => openExternalUrl(_kRepoUrl)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Карточка-секция: моно-заголовок + содержимое в кадре с тонким бордером.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: title),
        const SizedBox(height: AppTheme.headerGap),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: AppTheme.borderRadius,
            border: AppTheme.border(),
          ),
          child: child,
        ),
      ],
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: AppTheme.borderRadius,
          border: AppTheme.border(),
        ),
        child: Text(
          label,
          style: AppTheme.mono(
            size: 11,
            color: AppColors.textHi,
            weight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
