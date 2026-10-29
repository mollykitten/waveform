import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/providers.dart';

/// Real waveform bins shared by track views and the wave envelope.
/// Successful results stay cached for this container's lifetime. Pending requests
/// survive listener changes to avoid duplicate fetches. Failed or empty results
/// are discarded once all listeners detach, allowing a new demand to retry.
final waveformSamplesProvider = FutureProvider.autoDispose
    .family<List<double>?, String>((ref, url) async {
      if (url.isEmpty) return null;
      final cache = ref.keepAlive();
      try {
        final samples = await ref
            .read(soundcloudApiProvider)
            .fetchWaveform(url);
        if (samples == null || samples.isEmpty) {
          cache.close();
          return null;
        }
        return List<double>.unmodifiable(samples);
      } catch (_) {
        cache.close();
        rethrow;
      }
    }, retry: (retryCount, error) => null);
