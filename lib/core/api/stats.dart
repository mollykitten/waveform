import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:talker_flutter/talker_flutter.dart';

import '../../shared/models/track.dart';
import '../log/talker.dart';
import 'providers.dart';
import 'soundcloud_api.dart';

/// Размер страницы и максимум страниц, которые тянем из play-history.
const statsPageSize = 50;
const statsMaxPages = 8;

/// Агрегаты по выборке личной истории прослушиваний (`/me/play-history`).
///
/// Это не вся история и не время прослушивания: [totalTrackLength] — сумма
/// полных длительностей сыгранных треков (api не отдаёт, сколько реально
/// прослушано), а выборка ограничена [statsPageSize] × [statsMaxPages] записей.
class ListeningStats {
  const ListeningStats({
    required this.totalPlays,
    required this.uniqueTracks,
    required this.uniqueArtists,
    required this.totalTrackLength,
    required this.topArtists,
    required this.topGenres,
    this.partial = false,
    this.capped = false,
  });

  /// Размер выборки (число записей истории, попавших в агрегат).
  final int totalPlays;
  final int uniqueTracks;
  final int uniqueArtists;
  final Duration totalTrackLength;
  final List<({String name, int count})> topArtists;
  final List<({String genre, int count})> topGenres;

  /// Одна из следующих страниц не загрузилась: данные неполные.
  final bool partial;

  /// Выборка достигла лимита; более старые записи могут быть, а могут и нет
  /// (следующую страницу не запрашивали).
  final bool capped;

  /// Максимум записей в выборке.
  static const sampleLimit = statsPageSize * statsMaxPages;

  /// История действительно пуста (сбой первой страницы сюда не попадает —
  /// провайдер падает с ошибкой).
  bool get isEmpty => totalPlays == 0;
}

/// Постранично тянем play-history (до [ListeningStats.sampleLimit] записей),
/// группируем и считаем. Безопасно для анона: `historyPage` сам возвращает []
/// если нет авторизации.
final statsProvider = FutureProvider<ListeningStats>(
  (ref) => loadListeningStats(
    ref.read(soundcloudApiProvider),
    ref.read(talkerProvider),
  ),
);

/// Сбой первой страницы пробрасывается (экран покажет ошибку с retry), сбой
/// следующих — отдаёт уже собранное с `partial: true`.
Future<ListeningStats> loadListeningStats(SoundcloudApi api, Talker log) async {
  final all = <Track>[];
  var partial = false;
  var capped = false;
  for (var i = 0; i < statsMaxPages; i++) {
    try {
      final page = await api.historyPage(
        limit: statsPageSize,
        offset: i * statsPageSize,
      );
      if (page.isEmpty) break;
      all.addAll(page);
      if (page.length < statsPageSize) break;
      capped = i == statsMaxPages - 1;
    } catch (e, st) {
      log.warning('stats: page $i failed', e, st);
      if (i == 0) rethrow;
      partial = true;
      break;
    }
  }
  return _aggregate(all, partial: partial, capped: capped);
}

ListeningStats _aggregate(
  List<Track> tracks, {
  required bool partial,
  required bool capped,
}) {
  if (tracks.isEmpty) {
    return const ListeningStats(
      totalPlays: 0,
      uniqueTracks: 0,
      uniqueArtists: 0,
      totalTrackLength: Duration.zero,
      topArtists: [],
      topGenres: [],
    );
  }
  final uniqueIds = <String>{for (final t in tracks) t.id};
  final artistCounts = <String, int>{};
  final genreCounts = <String, int>{};
  var totalMs = 0;
  for (final t in tracks) {
    totalMs += t.durationMs;
    artistCounts.update(t.artist, (v) => v + 1, ifAbsent: () => 1);
    if (t.genre.isNotEmpty) {
      genreCounts.update(t.genre, (v) => v + 1, ifAbsent: () => 1);
    }
  }
  final artistsSorted = artistCounts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final genresSorted = genreCounts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return ListeningStats(
    totalPlays: tracks.length,
    uniqueTracks: uniqueIds.length,
    uniqueArtists: artistCounts.length,
    totalTrackLength: Duration(milliseconds: totalMs),
    partial: partial,
    capped: capped,
    topArtists: [
      for (final e in artistsSorted.take(10)) (name: e.key, count: e.value),
    ],
    topGenres: [
      for (final e in genresSorted.take(8)) (genre: e.key, count: e.value),
    ],
  );
}
