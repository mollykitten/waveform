import 'dart:async';

import 'package:dio/dio.dart';
import 'package:waveform_app/core/recommendations/listening_store.dart';
import 'package:waveform_app/core/recommendations/models.dart';
import 'package:waveform_app/core/recommendations/recommendation_service.dart';
import 'package:waveform_app/core/recommendations/vector_engine.dart';
import 'package:waveform_app/core/recommendations/vector_store.dart';
import 'package:waveform_app/shared/models/track.dart';

import 'support.dart';

/// Returns twenty fresh candidates on the first call and records limits.
class PoolService extends RecommendationService {
  PoolService(TestSoundcloud api)
    : super(
        api: api,
        vectorEngine: VectorEngine(
          api: api,
          store: VectorStore(),
          listening: ListeningStore(),
        ),
      );
  int calls = 0;
  int issued = 0;

  /// Sizes of successive answers; afterwards every answer is empty.
  List<int>? scripted;
  WaveFailure? failure;

  /// Sources handed out in rotation to the issued tracks.
  List<WaveSource> sources = const [WaveSource.related];

  /// Makes the first call wait for this completer.
  Completer<void>? holdFirst;

  /// Makes every call after the first wait for this completer.
  Completer<void>? holdAfterFirst;
  final limits = <int>[];

  @override
  Future<List<Recommendation>> generate({
    required String listeningIdentity,
    required CancelToken cancelToken,
    Track? currentTrack,
    Set<String> excludedTrackIds = const {},
    Set<String> localExcludedTrackIds = const {},
    void Function()? checkCurrent,
    int limit = 10,
  }) async {
    calls++;
    limits.add(limit);
    if (failure != null) throw failure!;
    if (calls == 1) await holdFirst?.future;
    if (calls > 1) await holdAfterFirst?.future;
    checkCurrent?.call();
    if (scripted != null) {
      final size = scripted!.isEmpty ? 0 : scripted!.removeAt(0);
      return [
        for (var i = 0; i < size; i++)
          Recommendation(
            realTrack('t${++issued}'),
            'a possible fit',
            source: sources[issued % sources.length],
          ),
      ];
    }
    return [
      for (var i = 0; i < 20; i++)
        Recommendation(realTrack('t${i + 1}'), 'a possible fit'),
    ];
  }
}
