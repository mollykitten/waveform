import '../../shared/models/track.dart';

/// Мок-лента на время разработки (до подключения реального SoundCloud API).
final List<Track> mockTracks = [
  Track(
    id: 't1',
    title: 'Subharmonic Drift',
    artist: 'voidwave',
    durationMs: 254000,
    likes: 12400,
    reposts: 892,
    plays: 341000,
    genre: 'ambient techno',
    postedAt: '2 days ago',
    description:
        'late-night session, all hardware, one take. '
        'tag me in your edits.',
    waveform: Track.generateWaveform(11),
  ),
  Track(
    id: 't2',
    title: 'Concrete / Neon',
    artist: 'k-machina',
    durationMs: 188000,
    likes: 8230,
    reposts: 410,
    plays: 129000,
    waveform: Track.generateWaveform(27),
  ),
  Track(
    id: 't3',
    title: 'Ledger Lullaby',
    artist: 'proof.of.stake',
    durationMs: 322000,
    likes: 45100,
    reposts: 3120,
    plays: 1280000,
    genre: 'downtempo',
    postedAt: '1 week ago',
    description:
        'slowed the whole thing down until it felt like falling asleep on-chain.',
    waveform: Track.generateWaveform(42),
  ),
  Track(
    id: 't4',
    title: 'Greyscale Sunday',
    artist: 'lo—fi—daemon',
    durationMs: 201000,
    likes: 2210,
    reposts: 88,
    plays: 33400,
    waveform: Track.generateWaveform(58),
  ),
  Track(
    id: 't5',
    title: 'Mempool Romance',
    artist: 'gas.fee.ghost',
    durationMs: 276000,
    likes: 18900,
    reposts: 1540,
    plays: 502000,
    waveform: Track.generateWaveform(73),
  ),
  Track(
    id: 't6',
    title: 'Null Island',
    artist: 'cartographer',
    durationMs: 167000,
    likes: 990,
    reposts: 31,
    plays: 14200,
    waveform: Track.generateWaveform(91),
  ),
];
