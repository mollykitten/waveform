import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/waveform_samples.dart';
import 'waveform_view.dart';

/// [WaveformView], который лениво подгружает РЕАЛЬНУЮ форму трека из
/// `waveformUrl` (с общим кэшем) и рисует её вместо процедурной заглушки.
/// Пока грузится / если не удалось — показывает [fallbackBars]. Убирает
/// расхождение «в списках/плеере одна форма, на странице трека другая».
class LiveWaveform extends ConsumerWidget {
  const LiveWaveform({
    super.key,
    required this.waveformUrl,
    required this.fallbackBars,
    this.progress = 0,
    this.buffered = 0,
    this.onSeek,
    this.height = 64,
    this.markers = const [],
  });

  final String? waveformUrl;
  final List<double> fallbackBars;
  final double progress;
  final double buffered;
  final ValueChanged<double>? onSeek;
  final double height;
  final List<double> markers;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = waveformUrl;
    final real = url == null || url.isEmpty
        ? null
        : ref.watch(waveformSamplesProvider(url)).asData?.value;
    return WaveformView(
      bars: real ?? fallbackBars,
      progress: progress,
      buffered: buffered,
      onSeek: onSeek,
      height: height,
      markers: markers,
    );
  }
}
