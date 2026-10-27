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

class Recommendation {
  const Recommendation(this.track, this.reason);
  final Track track;
  final String reason;
}
