import 'dart:async';

import '../../shared/models/track.dart';
import '../api/soundcloud_api.dart';

/// The signed-in user's home stream (uploads and reposts of followed accounts)
/// as a candidate source. Rank is freshness: the API returns newest first.
class StreamSource {
  StreamSource({
    required this.api,
    this.limit = 40,
    this.reuse = const Duration(minutes: 5),
    this.retryAfter = const Duration(minutes: 1),
    DateTime Function()? now,
    this.onWarning,
  }) : _now = now ?? DateTime.now;

  final SoundcloudApi api;

  /// Most stream items requested per fetch.
  final int limit;

  /// A fetched stream is reused this long, so refills do not repeat it.
  final Duration reuse;

  /// After a failure the stream is not retried for this long, so a slow or
  /// broken endpoint cannot delay every refill.
  final Duration retryAfter;
  final DateTime Function() _now;
  final void Function(String message)? onWarning;

  String? _identity;
  DateTime? _fetchedAt;
  DateTime? _failedAt;
  List<Track> _tracks = const [];

  /// Fresh stream tracks, newest first. Empty when the stream cannot be read:
  /// the wave keeps working from its other sources.
  Future<List<Track>> candidates(String identity) async {
    final failed = _failedAt;
    if (failed != null && _now().difference(failed) < retryAfter) {
      return const [];
    }
    final fetched = _fetchedAt;
    if (_identity == identity &&
        fetched != null &&
        _now().difference(fetched) < reuse) {
      return _tracks;
    }
    try {
      final tracks = await api
          .streamTracks(limit: limit)
          .timeout(const Duration(seconds: 10));
      _identity = identity;
      _failedAt = null;
      _fetchedAt = _now();
      return _tracks = tracks.take(limit).toList();
    } catch (error) {
      _failedAt = _now();
      onWarning?.call('stream candidates unavailable: ${error.runtimeType}');
      return const [];
    }
  }
}
