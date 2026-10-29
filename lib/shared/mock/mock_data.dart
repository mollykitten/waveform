import '../../features/home/mock_tracks.dart';
import '../models/artist.dart';
import '../models/collection.dart';
import '../models/comment.dart';
import '../models/feed_post.dart';
import '../models/track.dart';

/// Единый источник мок-данных на время разработки (до реального SoundCloud API).
abstract final class Mock {
  /// Сводка профиля для правого рейла.
  static const plays7d = 1192;

  static List<Track> get tracks => mockTracks;

  /// Поиск трека по id (для /track/:id); запасной — первый.
  static Track trackById(String id) =>
      mockTracks.firstWhere((t) => t.id == id, orElse: () => mockTracks.first);

  /// Похожие треки (всё, кроме текущего).
  static List<Track> related(String id) =>
      mockTracks.where((t) => t.id != id).take(4).toList();

  /// Комментарии трека, привязанные к таймкодам (масштабируем под длительность).
  static List<Comment> commentsFor(Track t) {
    const raw = [
      ('voidwave', 0.06, 'this intro is unreal 🔥'),
      ('k-machina', 0.21, 'mix on this is so clean'),
      ('proof.of.stake', 0.38, 'minted instantly, no regrets'),
      ('lo—fi—daemon', 0.55, 'that breakdown though'),
      ('gas.fee.ghost', 0.74, 'on repeat all week'),
      ('cartographer', 0.9, 'outro >>>'),
    ];
    return [
      for (final (i, (author, frac, text)) in raw.indexed)
        Comment(
          id: 'mock-c-${t.id}-$i',
          author: author,
          timecodeMs: (frac * t.durationMs).round(),
          text: text,
        ),
    ];
  }

  // ── Home: «from your stream» ──────────────────────────────────────────────
  static List<Track> get stream => mockTracks.take(3).toList();

  // ── Home: «More of what you like» (треки как обложки) ─────────────────────
  static const moreYouLike = [
    Collection(
      id: 'm1',
      title: 'the cut',
      subtitle: 'retriborn',
      kind: CollectionKind.playlist,
    ),
    Collection(
      id: 'm2',
      title: 'шура кинул барыгу',
      subtitle: 'polkovniksobr',
      kind: CollectionKind.playlist,
    ),
    Collection(
      id: 'm3',
      title: 'lovesong',
      subtitle: 'kai angel & 9mice',
      kind: CollectionKind.playlist,
    ),
    Collection(
      id: 'm4',
      title: 'wifiskeleton — 32 gigs',
      subtitle: 'your prom date',
      kind: CollectionKind.playlist,
    ),
    Collection(
      id: 'm5',
      title: 'lonown x ri',
      subtitle: 'zāran.²',
      kind: CollectionKind.playlist,
    ),
    Collection(
      id: 'm6',
      title: 'concrete / neon',
      subtitle: 'k-machina',
      kind: CollectionKind.playlist,
    ),
  ];

  // ── Home: «Recently played» (микс круглых артистов и обложек) ─────────────
  static const recentlyPlayed = [
    Collection(
      id: 'rp1',
      title: 'voidwave',
      subtitle: '420 followers',
      kind: CollectionKind.station,
      circular: true,
    ),
    Collection(
      id: 'rp2',
      title: 'эдик и данил',
      subtitle: 'SELFISH',
      kind: CollectionKind.album,
    ),
    Collection(
      id: 'rp3',
      title: 'dope (remix)',
      subtitle: 'made for you',
      kind: CollectionKind.playlist,
    ),
    Collection(
      id: 'rp4',
      title: 'GHETTO GARDEN',
      subtitle: 'Finesse Music · 2020',
      kind: CollectionKind.album,
    ),
    Collection(
      id: 'rp5',
      title: 'k-machina',
      subtitle: '27.5K followers',
      kind: CollectionKind.station,
      circular: true,
    ),
    Collection(
      id: 'rp6',
      title: 'Made for you',
      subtitle: 'weekly mix',
      kind: CollectionKind.mix,
      mixLabel: 'MIX 2',
    ),
  ];

  // ── Home: «Mixed for you» ─────────────────────────────────────────────────
  static const mixedForYou = [
    Collection(
      id: 'mx1',
      title: 'Late Night Drift',
      subtitle: 'arkham, jessie luck',
      kind: CollectionKind.mix,
      mixLabel: 'MIX 1',
    ),
    Collection(
      id: 'mx2',
      title: 'After Hours',
      subtitle: 'immmortal, еверсинс',
      kind: CollectionKind.mix,
      mixLabel: 'MIX 2',
    ),
    Collection(
      id: 'mx3',
      title: 'Concrete Bloom',
      subtitle: 'archyb0ld, iona juli',
      kind: CollectionKind.mix,
      mixLabel: 'MIX 3',
    ),
    Collection(
      id: 'mx4',
      title: 'Portwave',
      subtitle: 'anybun, riserays',
      kind: CollectionKind.mix,
      mixLabel: 'MIX 4',
    ),
    Collection(
      id: 'mx5',
      title: 'Greyscale',
      subtitle: 'riserays, lo-fi daemon',
      kind: CollectionKind.mix,
      mixLabel: 'MIX 5',
    ),
  ];

  // ── Home + Library: «Albums for you» ──────────────────────────────────────
  static const albums = [
    Collection(
      id: 'al1',
      title: 'KngBrando',
      subtitle: 'lil uzi vert · 2016',
      kind: CollectionKind.album,
      trackCount: 14,
    ),
    Collection(
      id: 'al2',
      title: 'A Love Letter to You',
      subtitle: 'trippie redd · 2023',
      kind: CollectionKind.album,
      trackCount: 11,
    ),
    Collection(
      id: 'al3',
      title: 'Needle Guy',
      subtitle: 'dylan brady · 2026',
      kind: CollectionKind.album,
      trackCount: 9,
    ),
    Collection(
      id: 'al4',
      title: 'Awakening my InnerB',
      subtitle: 'trippie redd · 2016',
      kind: CollectionKind.album,
      trackCount: 16,
    ),
    Collection(
      id: 'al5',
      title: '17',
      subtitle: 'xxxtentacion · 2017',
      kind: CollectionKind.album,
      trackCount: 11,
    ),
  ];

  // ── Home + Library: «Stations» (круглые) ─────────────────────────────────
  static const stations = [
    Collection(
      id: 'st1',
      title: 'polkovniksobr',
      subtitle: 'artist station',
      kind: CollectionKind.station,
    ),
    Collection(
      id: 'st2',
      title: 'xsonsss',
      subtitle: 'artist station',
      kind: CollectionKind.station,
    ),
    Collection(
      id: 'st3',
      title: 'bladexxd',
      subtitle: 'artist station',
      kind: CollectionKind.station,
    ),
    Collection(
      id: 'st4',
      title: 'zāran.²',
      subtitle: 'artist station',
      kind: CollectionKind.station,
    ),
    Collection(
      id: 'st5',
      title: 'archyb0ld',
      subtitle: 'artist station',
      kind: CollectionKind.station,
    ),
  ];

  // ── Home: «Liked by» ──────────────────────────────────────────────────────
  static const likedBy = [
    Collection(
      id: 'lb1',
      title: "lovesomemama's Picks",
      subtitle: 'liked by lovesomemama',
      kind: CollectionKind.playlist,
    ),
    Collection(
      id: 'lb2',
      title: "katya's Picks",
      subtitle: 'liked by katya',
      kind: CollectionKind.playlist,
    ),
    Collection(
      id: 'lb3',
      title: "Seemann's Picks",
      subtitle: 'liked by Seemann',
      kind: CollectionKind.playlist,
    ),
    Collection(
      id: 'lb4',
      title: "nitebol's Picks",
      subtitle: 'liked by nitebol',
      kind: CollectionKind.playlist,
    ),
  ];

  // ── Home: «Made for you» (авто-подборки с вордмарком) ─────────────────────
  static const madeForYou = [
    Collection(
      id: 'mf1',
      title: 'Daily Drops',
      subtitle: 'new releases based on your taste',
      kind: CollectionKind.autoMix,
      wordmark: 'DAILY DROPS',
    ),
    Collection(
      id: 'mf2',
      title: 'Weekly Wave',
      subtitle: 'the best of Waveform',
      kind: CollectionKind.autoMix,
      wordmark: 'WEEKLY WAVE',
    ),
  ];

  // ── Home: «New crew, suggested for you» (артисты, круглые) ────────────────
  static const newCrew = [
    Collection(
      id: 'nc1',
      title: 'Port Fish',
      subtitle: '970 followers',
      kind: CollectionKind.station,
      circular: true,
    ),
    Collection(
      id: 'nc2',
      title: 'Living With High',
      subtitle: '4 followers',
      kind: CollectionKind.station,
      circular: true,
    ),
    Collection(
      id: 'nc3',
      title: 'lord winter',
      subtitle: '271 followers',
      kind: CollectionKind.station,
      circular: true,
    ),
    Collection(
      id: 'nc4',
      title: 'Ambient Noise Sen',
      subtitle: '141 followers',
      kind: CollectionKind.station,
      circular: true,
    ),
    Collection(
      id: 'nc5',
      title: 'cartographer',
      subtitle: '39 followers',
      kind: CollectionKind.station,
      circular: true,
    ),
  ];

  // ── Library: likes grid (треки как обложки) ───────────────────────────────
  static const likes = [
    Collection(
      id: 'lk1',
      title: 'шура кинул барыгу',
      subtitle: 'polkovniksobr',
      kind: CollectionKind.playlist,
    ),
    Collection(
      id: 'lk2',
      title: 'sil-a + xsonsss',
      subtitle: 'xsonsss',
      kind: CollectionKind.playlist,
    ),
    Collection(
      id: 'lk3',
      title: 'dope (remix)',
      subtitle: 'bladexxd',
      kind: CollectionKind.playlist,
    ),
    Collection(
      id: 'lk4',
      title: 'id (lonown x riserayss)',
      subtitle: 'zāran.²',
      kind: CollectionKind.playlist,
    ),
    Collection(
      id: 'lk5',
      title: 'DOGGIE DANCE',
      subtitle: 'archyb0ld',
      kind: CollectionKind.playlist,
    ),
    Collection(
      id: 'lk6',
      title: 'SUNSET',
      subtitle: 'lucki',
      kind: CollectionKind.album,
    ),
  ];

  // ── Library: playlists ────────────────────────────────────────────────────
  static const playlists = [
    Collection(
      id: 'pl1',
      title: 'late drives',
      subtitle: '24 tracks',
      kind: CollectionKind.playlist,
      trackCount: 24,
    ),
    Collection(
      id: 'pl2',
      title: 'late night',
      subtitle: '12 tracks',
      kind: CollectionKind.playlist,
      trackCount: 12,
    ),
    Collection(
      id: 'pl3',
      title: 'field recordings',
      subtitle: '8 tracks',
      kind: CollectionKind.playlist,
      trackCount: 8,
    ),
    Collection(
      id: 'pl4',
      title: 'sunday greyscale',
      subtitle: '31 tracks',
      kind: CollectionKind.playlist,
      trackCount: 31,
    ),
  ];

  // ── Right rail ────────────────────────────────────────────────────────────
  static const artistsToFollow = [
    Artist(
      id: 'a1',
      handle: 'your prom date',
      followers: 2182,
      trackCount: 109,
    ),
    Artist(
      id: 'a2',
      handle: 'JEEMBO',
      followers: 4366,
      trackCount: 71,
      verified: true,
    ),
    Artist(id: 'a3', handle: 'wifiskeleton', followers: 4982, trackCount: 78),
  ];

  static List<Track> get listeningHistory =>
      mockTracks.skip(1).take(4).toList();

  // ── Feed ──────────────────────────────────────────────────────────────────
  static List<FeedPost> get feed => [
    FeedPost(
      id: 'f1',
      actor: 'hyperforms',
      action: FeedAction.reposted,
      timeAgo: '18 minutes ago',
      track: mockTracks[0],
      tag: 'dubstep',
      comments: 9,
    ),
    FeedPost(
      id: 'f2',
      actor: 'limedisx',
      action: FeedAction.reposted,
      timeAgo: '4 hours ago',
      track: mockTracks[4],
      tag: 'ambient',
      comments: 4,
    ),
    FeedPost(
      id: 'f3',
      actor: 'Romi Lux',
      action: FeedAction.posted,
      timeAgo: '4 hours ago',
      track: mockTracks[2],
      tag: 'house',
      comments: 12,
    ),
    FeedPost(
      id: 'f4',
      actor: 'k-machina',
      action: FeedAction.posted,
      timeAgo: '7 hours ago',
      track: mockTracks[1],
      tag: 'dark-techno',
      comments: 2,
    ),
    FeedPost(
      id: 'f5',
      actor: 'gas.fee.ghost',
      action: FeedAction.reposted,
      timeAgo: '11 hours ago',
      track: mockTracks[5],
      tag: 'field-rec',
      comments: 1,
    ),
  ];
}
