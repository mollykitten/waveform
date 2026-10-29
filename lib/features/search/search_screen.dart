import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../../core/api/feeds.dart';
import '../../core/api/soundcloud_api.dart';
import '../../shared/format.dart';
import '../../shared/models/artist.dart';
import '../../shared/view_mode.dart';
import '../../shared/widgets/async_view.dart';
import '../../shared/widgets/collection_card.dart';
import '../../shared/widgets/collection_row.dart';
import '../../shared/widgets/cover_art.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/pressable.dart';
import '../../shared/widgets/rail_layout.dart';
import '../../shared/widgets/section_header.dart';
import '../../shared/widgets/track_row.dart';
import '../../shared/widgets/view_toggle.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key, required this.query});

  final String query;

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  static const _tabs = ['tracks', 'people', 'playlists'];
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final q = widget.query.trim();
    if (q.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: AppTheme.topBarHeight),
        child: Center(
          child: Text(
            'type in the search bar above to find tracks, people, playlists',
            style: TextStyle(color: AppColors.textLow),
          ),
        ),
      );
    }
    final results = ref.watch(searchProvider(q));
    return RailLayout(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: AppTheme.topBarHeight),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.pagePad,
              18,
              AppTheme.pagePad,
              4,
            ),
            child: Text(
              'results for “$q”',
              style: AppTheme.mono(size: 12, color: AppColors.textMid),
            ),
          ),
          _Tabs(
            tabs: _tabs,
            current: _tab,
            onSelect: (i) => setState(() => _tab = i),
            // Тогл вида — только на вкладке playlists (там грид коллекций).
            trailing: _tabs[_tab] == 'playlists' ? const ViewToggle() : null,
          ),
          Expanded(
            child: AsyncView<SearchResults>(
              value: results,
              onRetry: () => ref.invalidate(searchProvider(q)),
              data: (r) => _body(r),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(SearchResults r) {
    final pad = const EdgeInsets.fromLTRB(
      AppTheme.pagePad,
      18,
      AppTheme.pagePad,
      AppTheme.playerHeight + 32,
    );
    final q = widget.query.trim();
    switch (_tabs[_tab]) {
      case 'people':
        if (r.artists.isEmpty) {
          return EmptyState(
            icon: Icons.person_search_outlined,
            title: 'no people found',
            subtitle: 'no SoundCloud users matched “$q” — try a shorter query',
          );
        }
        return ListView(
          padding: pad,
          children: [for (final a in r.artists) _ArtistRow(artist: a)],
        );
      case 'playlists':
        if (r.playlists.isEmpty) {
          return EmptyState(
            icon: Icons.library_music_outlined,
            title: 'no playlists found',
            subtitle: 'nothing matched “$q”',
          );
        }
        final mode = ref.watch(viewModeProvider);
        if (mode == ViewMode.list) {
          return ListView(
            padding: pad,
            children: [for (final p in r.playlists) CollectionRow(item: p)],
          );
        }
        return SingleChildScrollView(
          padding: pad,
          child: Wrap(
            spacing: 20,
            runSpacing: 24,
            children: [for (final p in r.playlists) CollectionCard(item: p)],
          ),
        );
      case 'tracks':
      default:
        if (r.tracks.isEmpty) {
          return EmptyState(
            icon: Icons.search_off,
            title: 'no tracks found',
            subtitle: 'no SoundCloud tracks matched “$q”',
          );
        }
        return ListView(
          padding: pad,
          children: [
            const SectionHeader(title: 'tracks'),
            const SizedBox(height: AppTheme.headerGap),
            for (final t in r.tracks) TrackRow(track: t, queue: r.tracks),
          ],
        );
    }
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs({
    required this.tabs,
    required this.current,
    required this.onSelect,
    this.trailing,
  });
  final List<String> tabs;
  final int current;
  final ValueChanged<int> onSelect;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.pagePad),
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
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: i == current ? AppColors.acid : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                alignment: Alignment.center,
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
          if (trailing != null) ...[const Spacer(), trailing!],
        ],
      ),
    );
  }
}

class _ArtistRow extends StatelessWidget {
  const _ArtistRow({required this.artist});
  final Artist artist;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: () => context.push('/artist/${Uri.encodeComponent(artist.handle)}'),
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
            CoverArt(
              seed: artist.coverSeed,
              imageUrl: artist.avatarUrl,
              size: 44,
              circular: true,
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
                          artist.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textHi,
                          ),
                        ),
                      ),
                      if (artist.verified) ...[
                        const SizedBox(width: 5),
                        const Icon(
                          Icons.verified,
                          size: 13,
                          color: AppColors.acid,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${Fmt.count(artist.followers)} followers',
                    style: AppTheme.mono(size: 11, color: AppColors.textMid),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 18, color: AppColors.textLow),
          ],
        ),
      ),
    );
  }
}
