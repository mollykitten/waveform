import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../../core/api/feeds.dart';
import '../../core/api/followed_users.dart';
import '../../core/api/providers.dart';
import '../../core/api/soundcloud_api.dart';
import '../../shared/format.dart';
import '../../shared/models/artist.dart';
import '../../shared/models/collection.dart';
import '../../shared/models/track.dart';
import '../../shared/widgets/async_view.dart';
import '../../shared/widgets/collection_card.dart';
import '../../shared/widgets/cover_art.dart';
import '../../shared/widgets/pressable.dart';
import '../../shared/widgets/section_header.dart';
import '../../shared/widgets/track_row.dart';

class ArtistScreen extends ConsumerStatefulWidget {
  const ArtistScreen({super.key, required this.handle});

  final String handle;

  @override
  ConsumerState<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends ConsumerState<ArtistScreen> {
  static const _tabs = ['popular', 'tracks', 'albums', 'playlists', 'reposts'];
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(artistProfileProvider(widget.handle));
    return AsyncView<ArtistProfile>(
      value: profile,
      onRetry: () => ref.invalidate(artistProfileProvider(widget.handle)),
      data: (p) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.pagePad,
              AppTheme.topBarHeight + 20,
              AppTheme.pagePad,
              AppTheme.playerHeight + 32,
            ),
            children: [
              const _BackButton(),
              const SizedBox(height: 16),
              _Header(
                artist: p.artist,
                following: ref.watch(
                  followedUsersProvider.select((s) => s.contains(p.artist.id)),
                ),
                onFollow: () => ref
                    .read(followedUsersProvider.notifier)
                    .toggle(p.artist.id),
              ),
              const SizedBox(height: 28),
              _TabBar(
                tabs: _tabs,
                current: _tab,
                onSelect: (i) => setState(() => _tab = i),
              ),
              const SizedBox(height: 24),
              _body(p),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(ArtistProfile p) {
    switch (_tabs[_tab]) {
      case 'albums':
        return _grid('albums', p.albums);
      case 'playlists':
        return _grid('playlists', p.playlists);
      case 'reposts':
        return RepostsTab(key: ValueKey(p.artist.id), userId: p.artist.id);
      case 'tracks':
        return _tracks('all tracks', p.tracks);
      case 'popular':
      default:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _tracks('popular tracks', p.tracks.take(4).toList()),
            const SizedBox(height: AppTheme.sectionGap),
            _grid('albums', p.albums),
          ],
        );
    }
  }

  Widget _tracks(String title, List<Track> tracks) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: title),
        const SizedBox(height: AppTheme.headerGap),
        for (final t in tracks) TrackRow(track: t, queue: tracks),
      ],
    );
  }

  Widget _grid(String title, List<Collection> items) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: title),
        const SizedBox(height: AppTheme.headerGap),
        Wrap(
          spacing: 20,
          runSpacing: 24,
          children: [for (final it in items) CollectionCard(item: it)],
        ),
      ],
    );
  }
}

/// Artist's own reposts (not the spotlight), paged by cursor.
class RepostsTab extends ConsumerStatefulWidget {
  const RepostsTab({super.key, required this.userId});

  final String userId;

  @override
  ConsumerState<RepostsTab> createState() => _RepostsTabState();
}

class _RepostsTabState extends ConsumerState<RepostsTab> {
  final _tracks = <Track>[];
  String? _next;
  bool _loading = false;
  bool _failed = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _more();
  }

  Future<void> _more() async {
    if (_loading || _done) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final page = await ref
          .read(soundcloudApiProvider)
          .userRepostsPage(widget.userId, nextHref: _next);
      if (!mounted) return;
      setState(() {
        _tracks.addAll(page.tracks);
        _next = page.nextHref;
        _done = page.nextHref == null;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'reposts'),
        const SizedBox(height: AppTheme.headerGap),
        for (final t in _tracks) TrackRow(track: t, queue: _tracks),
        if (_tracks.isEmpty && _done)
          Text(
            'no reposts yet',
            style: AppTheme.mono(size: 12, color: AppColors.textMid),
          ),
        if (_loading)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'loading…',
              style: AppTheme.mono(size: 12, color: AppColors.textMid),
            ),
          )
        else if (_failed || !_done)
          Pressable(
            onTap: _more,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                _failed ? 'failed to load — tap to retry' : 'load more',
                style: AppTheme.mono(size: 12, color: AppColors.textMid),
              ),
            ),
          ),
      ],
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton();

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

class _Header extends StatelessWidget {
  const _Header({
    required this.artist,
    required this.following,
    required this.onFollow,
  });

  final Artist artist;
  final bool following;
  final VoidCallback onFollow;

  @override
  Widget build(BuildContext context) {
    // following-count в домене нет — производное от handle, чисто для шапки.
    final followingCount = 40 + artist.handle.hashCode.abs() % 600;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        CoverArt(
          seed: 'artist-${artist.handle}',
          imageUrl: artist.avatarUrl,
          size: 104,
          circular: true,
        ),
        const SizedBox(width: 24),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      artist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textHi,
                      ),
                    ),
                  ),
                  if (artist.verified) ...[
                    const SizedBox(width: 8),
                    const Icon(Icons.verified, size: 18, color: AppColors.acid),
                  ],
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 22,
                runSpacing: 6,
                children: [
                  _Stat(value: Fmt.count(artist.followers), label: 'followers'),
                  _Stat(value: Fmt.count(followingCount), label: 'following'),
                  _Stat(value: '${artist.trackCount}', label: 'tracks'),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 20),
        _FollowButton(following: following, onTap: onFollow),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          value,
          style: AppTheme.mono(
            size: 15,
            color: AppColors.textHi,
            weight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 5),
        Text(label, style: AppTheme.mono(size: 11, color: AppColors.textLow)),
      ],
    );
  }
}

class _FollowButton extends StatelessWidget {
  const _FollowButton({required this.following, required this.onTap});
  final bool following;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
        decoration: BoxDecoration(
          color: following ? Colors.transparent : AppColors.acid,
          borderRadius: AppTheme.borderRadius,
          border: AppTheme.border(
            following ? AppColors.border : AppColors.acid,
          ),
        ),
        child: Text(
          following ? 'following' : 'follow',
          style: AppTheme.mono(
            size: 12,
            color: following ? AppColors.textHi : AppColors.bg,
            weight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({
    required this.tabs,
    required this.current,
    required this.onSelect,
  });

  final List<String> tabs;
  final int current;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: AppTheme.borderSideStatic),
      ),
      child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++)
            Pressable(
              onTap: () => onSelect(i),
              child: Container(
                margin: const EdgeInsets.only(right: 22),
                padding: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: i == current ? AppColors.acid : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: Text(
                  tabs[i],
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: i == current
                        ? FontWeight.w600
                        : FontWeight.w400,
                    color: i == current ? AppColors.textHi : AppColors.textMid,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
