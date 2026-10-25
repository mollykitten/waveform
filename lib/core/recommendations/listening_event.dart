/// Explicit playback intent; automatic transitions never masquerade as skips.
enum ListeningTransitionCause {
  naturalCompletion,
  crossfadeCompletion,
  manualNext,
  manualPrevious,
  manualRestart,
  directSelection,
  unplayable,
  stopped,
  disposal,
  accountChange,
}

enum ListeningEvidence { positive, negative, neutral }

/// Validated local partition names contain neither credentials nor token hashes.
bool validListeningIdentity(String value) =>
    value == 'anonymous' || RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(value);

/// User-owned listening facts. No titles, audio locations or service payloads.
class ListeningEvent {
  const ListeningEvent({
    required this.sessionId,
    required this.identity,
    required this.trackId,
    required this.durationMs,
    required this.heardMs,
    required this.finalPositionMs,
    required this.seekCount,
    required this.startedAt,
    required this.endedAt,
    required this.cause,
  });

  final String sessionId;
  final String identity;
  final String trackId;
  final int durationMs;
  final int heardMs;
  final int finalPositionMs;
  final int seekCount;
  final DateTime startedAt;
  final DateTime endedAt;
  final ListeningTransitionCause cause;

  /// A conservative, replaceable interpretation; the persisted facts are primary.
  ListeningEvidence get evidence {
    if (cause == ListeningTransitionCause.unplayable) {
      return ListeningEvidence.neutral;
    }
    if (durationMs > 0 && heardMs >= 30000 && heardMs >= durationMs * .7) {
      return ListeningEvidence.positive;
    }
    if (cause == ListeningTransitionCause.manualNext &&
        seekCount == 0 &&
        durationMs > 0 &&
        heardMs >= 5000 &&
        heardMs < 30000 &&
        heardMs < durationMs * .25) {
      return ListeningEvidence.negative;
    }
    return ListeningEvidence.neutral;
  }

  Map<String, Object> toJson() => {
    'session_id': sessionId,
    'identity': identity,
    'track_id': trackId,
    'duration_ms': durationMs,
    'heard_ms': heardMs,
    'final_position_ms': finalPositionMs,
    'seek_count': seekCount,
    'started_at': startedAt.toUtc().toIso8601String(),
    'ended_at': endedAt.toUtc().toIso8601String(),
    'cause': cause.name,
  };

  factory ListeningEvent.fromJson(Map<String, dynamic> json) {
    final event = ListeningEvent(
      sessionId: json['session_id'] as String,
      identity: json['identity'] as String,
      trackId: json['track_id'] as String,
      durationMs: json['duration_ms'] as int,
      heardMs: json['heard_ms'] as int,
      finalPositionMs: json['final_position_ms'] as int,
      seekCount: json['seek_count'] as int,
      startedAt: DateTime.parse(json['started_at'] as String),
      endedAt: DateTime.parse(json['ended_at'] as String),
      cause: ListeningTransitionCause.values.byName(json['cause'] as String),
    );
    if (!event.isValid) throw const FormatException('invalid listening event');
    return event;
  }

  bool get isValid =>
      validListeningIdentity(identity) &&
      RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(trackId) &&
      RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(sessionId) &&
      durationMs >= 0 &&
      durationMs <= 86400000 &&
      heardMs >= 0 &&
      heardMs <= 604800000 &&
      finalPositionMs >= 0 &&
      finalPositionMs <= 86400000 &&
      seekCount >= 0;
}
