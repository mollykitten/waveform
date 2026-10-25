import 'dart:math';

/// Доменная модель трека. Наполняется живым api-v2 (см. core/api/mappers.dart);
/// моки из mock_tracks.dart — только для тестов/offline (`--dart-define=MOCK=true`).
class Track {
  const Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.durationMs,
    required this.likes,
    required this.reposts,
    required this.plays,
    required this.waveform,
    this.waveformUrl,
    this.artistPermalink,
    this.coverUrl,
    this.streamCandidates = const [],
    this.drmStreamCandidates = const [],
    this.permalinkUrl,
    this.minted = false,
    this.genre = 'electronic',
    this.postedAt = '3 days ago',
    this.description = '',
  });

  final String id;
  final String title;
  final String artist;

  /// Permalink (URL-слаг) артиста для resolve. null → роутим по имени.
  final String? artistPermalink;
  final int durationMs;
  final int likes;
  final int reposts;
  final int plays;
  final String genre;
  final String postedAt;
  final String description;

  /// Handle для роутинга на /artist/:handle — permalink, иначе имя.
  String get artistHandle =>
      (artistPermalink != null && artistPermalink!.isNotEmpty)
      ? artistPermalink!
      : artist;

  /// Амплитуды баров waveform, нормализованные в диапазон 0..1. Это либо
  /// РЕАЛЬНАЯ форма (если уже подгружена), либо процедурная заглушка по id.
  final List<double> waveform;

  /// URL реальной waveform-формы трека (`waveform_url` из api-v2). Лениво
  /// подгружается виджетом [LiveWaveform] в списках/плеере, чтобы форма
  /// совпадала со страницей трека. null → только процедурная заглушка.
  final String? waveformUrl;

  /// URL обложки. null → процедурная обложка (offline-режим разработки).
  final String? coverUrl;

  /// URL транскодингов из `media.transcodings` api-v2, упорядоченные по
  /// предпочтению (HLS → progressive). Каждый требует резолва через
  /// [SoundcloudApi.resolveStreamUrl]; плеер перебирает их, пока один не
  /// заиграет (часть ссылок протухает и отдаёт 404). Пусто → не проигрываем.
  final List<String> streamCandidates;

  /// URL Widevine-транскодингов (`ctr-encrypted-hls`) для GO+ треков, которые
  /// just_audio не играет напрямую. Плеер пробует их через [DrmStreamService]
  /// (дешифровка Go-ядром scdrm в локальный файл). Пусто → не DRM.
  final List<String> drmStreamCandidates;

  /// Первый (предпочтительный) источник; null → трек не проигрываем.
  String? get streamUrl =>
      streamCandidates.isEmpty ? null : streamCandidates.first;

  /// Постоянный URL трека на soundcloud.com (для «share» и «open in browser»).
  final String? permalinkUrl;

  /// web3-маркер: трек заминчен как NFT.
  final bool minted;

  Duration get duration => Duration(milliseconds: durationMs);

  Track copyWith({List<double>? waveform, bool? minted}) => Track(
    id: id,
    title: title,
    artist: artist,
    durationMs: durationMs,
    likes: likes,
    reposts: reposts,
    plays: plays,
    waveform: waveform ?? this.waveform,
    waveformUrl: waveformUrl,
    artistPermalink: artistPermalink,
    coverUrl: coverUrl,
    streamCandidates: streamCandidates,
    drmStreamCandidates: drmStreamCandidates,
    permalinkUrl: permalinkUrl,
    minted: minted ?? this.minted,
    genre: genre,
    postedAt: postedAt,
    description: description,
  );

  /// Детерминированная waveform из seed — стабильна между перезапусками.
  static List<double> generateWaveform(int seed, {int bars = 140}) {
    final rnd = Random(seed);
    return List<double>.generate(bars, (i) {
      // Низкочастотная огибающая + высокочастотный джиттер — похоже на музыку.
      final envelope =
          0.35 + 0.45 * (sin(i / bars * pi * 3 + seed) * 0.5 + 0.5);
      final jitter = rnd.nextDouble() * 0.5;
      return (envelope * 0.6 + jitter * 0.4).clamp(0.04, 1.0);
    });
  }
}
