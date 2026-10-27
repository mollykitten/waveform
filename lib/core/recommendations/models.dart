import '../../shared/models/track.dart';

/// Safe failures: never retain transport exceptions, headers or response bodies.
enum WaveFailure implements Exception {
  signIn('sign in to SoundCloud to play your wave'),
  noTracks('no matching playable SoundCloud tracks were found'),
  source('could not reach SoundCloud — try again'),
  network('could not load your wave — try again'),
  cancelled('generation cancelled');

  const WaveFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Bounded public text only: no URLs or control characters.
String boundedText(String value, int limit) {
  final clean = value
      .replaceAll(RegExp(r'(?:https?://|www\.)\S+', caseSensitive: false), '')
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
      .trim();
  return String.fromCharCodes(clean.runes.take(limit));
}

/// Where a wave candidate came from. Stored with local listening facts so the
/// sources can later be compared by completions and skips.
enum WaveSource {
  related('from related tracks, ranked using local listening interests'),
  stream('from your stream'),
  coLikers('liked by people with similar likes');

  const WaveSource(this.reason);

  /// The short explanation shown next to a track of this source.
  final String reason;

  /// Unknown names (a newer file read by an older build) read as null.
  static WaveSource? tryParse(Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

class Recommendation {
  const Recommendation(
    this.track,
    this.reason, {
    this.source = WaveSource.related,
  });
  final Track track;
  final String reason;
  final WaveSource source;
}
