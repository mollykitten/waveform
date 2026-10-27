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
    DateTime Function()? now,
    this.onWarning,
  }) : _now = now ?? DateTime.now;

  final SoundcloudApi api;

  /// Most stream items requested per fetch.
  final int limit;

  /// A fetched stream is reused this long, so refills do not repeat it.
  final Duration reuse;
  final DateTime Function() _now;
  final void Function(String message)? onWarning;

  String? _identity;
  DateTime? _fetchedAt;
  List<Track> _tracks = const [];

  /// Fresh stream tracks, newest first. Empty when the stream cannot be read:
  /// the wave keeps working from its other sources.
  Future<List<Track>> candidates(String identity) async {
    final fetched = _fetchedAt;
    if (_identity == identity &&
        fetched != null &&
        _now().difference(fetched) < reuse) {
      return _tracks;
    }
    try {
      final tracks = await api
          .streamTracks(limit: limit)
          .timeout(const Duration(seconds: 25));
      _identity = identity;
      _fetchedAt = _now();
      return _tracks = tracks.take(limit).toList();
    } catch (error) {
      onWarning?.call('stream candidates unavailable: ${error.runtimeType}');
      return const [];
    }
  }
}
