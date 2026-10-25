import 'dart:convert';

import '../../shared/models/track.dart';

/// Safe failures: never retain transport exceptions, headers or response bodies.
enum AiFailure implements Exception {
  configuration('configure a valid endpoint and model first'),
  credentials('model access denied — check your session key'),
  rateLimit('model rate limit reached — try again later'),
  timeout('the model took too long — try again'),
  network('could not reach the model endpoint'),
  malformed('the model returned an invalid recommendation response'),
  noTracks('no matching playable SoundCloud tracks were found'),
  source('could not search SoundCloud — try again'),
  cancelled('generation cancelled');

  const AiFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Bounded public metadata only. No URLs, descriptions or stream credentials.
Map<String, String> trackMetadata(Track track) => {
  'id': boundedText(track.id, 64),
  'title': boundedText(track.title, 160),
  'artist': boundedText(track.artist, 120),
  'genre': boundedText(track.genre, 60),
};

String boundedText(String value, int limit) {
  final clean = value
      .replaceAll(RegExp(r'(?:https?://|www\.)\S+', caseSensitive: false), '')
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
      .trim();
  return String.fromCharCodes(clean.runes.take(limit));
}

String validatedMood(String mood) {
  if (mood.runes.length > 500 ||
      RegExp(
        r'https?://|www\.|soundcloud\.com',
        caseSensitive: false,
      ).hasMatch(mood) ||
      RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]').hasMatch(mood)) {
    throw AiFailure.configuration;
  }
  return mood.trim();
}

Map<String, dynamic> _object(String raw) {
  if (utf8.encode(raw).length > 16384) throw AiFailure.malformed;
  try {
    final value = jsonDecode(raw);
    if (value is Map<String, dynamic>) return value;
  } catch (_) {
    throw AiFailure.malformed;
  }
  throw AiFailure.malformed;
}

/// Strict plan parser. Model text is data, never executable tool instructions.
List<String> parseSearchPlan(String raw) {
  final value = _object(raw);
  final queries = value['queries'];
  if (value.length != 1 ||
      queries is! List ||
      queries.isEmpty ||
      queries.length > 2) {
    throw AiFailure.malformed;
  }
  final result = <String>[];
  for (final query in queries) {
    if (query is! String ||
        query.trim().isEmpty ||
        query.runes.length > 120 ||
        RegExp(
          r'[\x00-\x1f\x7f]|https?://|www\.',
          caseSensitive: false,
        ).hasMatch(query) ||
        result.contains(query.trim())) {
      throw AiFailure.malformed;
    }
    result.add(query.trim());
  }
  return result;
}

class Recommendation {
  const Recommendation(this.track, this.reason);
  final Track track;
  final String reason;
}

/// Only original candidate objects may leave the ranker. Reject the entire
/// response on unknown/duplicate IDs instead of silently accepting hallucination.
List<Recommendation> parseRanking(String raw, List<Track> candidates) {
  final value = _object(raw);
  final items = value['recommendations'];
  if (value.length != 1 || items is! List || items.length > 10) {
    throw AiFailure.malformed;
  }
  final allowed = {for (final track in candidates) track.id: track};
  final seen = <String>{};
  final result = <Recommendation>[];
  for (final item in items) {
    if (item is! Map ||
        item.length != 2 ||
        item['id'] is! String ||
        item['reason'] is! String) {
      throw AiFailure.malformed;
    }
    final id = item['id'] as String;
    final reason = item['reason'] as String;
    final track = allowed[id];
    if (track == null ||
        !seen.add(id) ||
        reason.trim().isEmpty ||
        reason.runes.length > 240 ||
        RegExp(
          r'[\x00-\x1f\x7f]|https?://|www\.',
          caseSensitive: false,
        ).hasMatch(reason)) {
      throw AiFailure.malformed;
    }
    result.add(Recommendation(track, reason.trim()));
  }
  return result;
}
