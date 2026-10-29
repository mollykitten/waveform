/// Тип подборки — определяет вид карточки и подпись.
enum CollectionKind {
  mix, // авто-микс «MIX 1…5» с крупным лейблом
  album, // альбом исполнителя
  playlist, // пользовательский плейлист
  station, // артист-радио (круглая обложка)
  autoMix, // системная подборка: Daily Drops, Weekly Wave
}

/// Куда ведёт тап по карточке. Карточка может представлять трек (лайки/история),
/// плейлист/альбом или артиста — id/handle интерпретируются по target.
enum CollectionTarget { track, playlist, artist }

/// Любая обложечная сущность ленты открытий: микс, альбом, плейлист,
/// станция, авто-подборка. На моках.
class Collection {
  const Collection({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.kind,
    this.trackCount = 0,
    this.mixLabel,
    this.wordmark,
    this.coverUrl,
    this.target = CollectionTarget.playlist,
    this.handle,
    bool? circular,
  }) : _circular = circular;

  /// Куда вести по тапу (трек/плейлист/артист).
  final CollectionTarget target;

  /// Permalink артиста (для target == artist). null → роутим по title.
  final String? handle;

  final bool? _circular;

  final String id;
  final String title;
  final String subtitle;
  final CollectionKind kind;
  final int trackCount;

  /// Крупная плашка на обложке микса, напр. «MIX 2».
  final String? mixLabel;

  /// Вордмарк для авто-подборок, напр. «DAILY DROPS».
  final String? wordmark;

  /// URL обложки (реальный арт). null → процедурная обложка по seed.
  final String? coverUrl;

  /// Станции и профили рисуем круглой обложкой.
  bool get isCircular =>
      _circular ??
      (kind == CollectionKind.station || target == CollectionTarget.artist);

  /// Seed для процедурной обложки.
  String get coverSeed => id;
}
