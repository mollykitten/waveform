import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../player/player_controller.dart';
import '../../../shared/providers/waveform_samples.dart';

/// Interpolates real, normalized waveform bins at a track progress fraction.
/// Invalid amplitudes are silent; values outside 0..1 are clamped.
double sampleWaveformEnergy(List<double> samples, double progress) {
  if (samples.isEmpty || !progress.isFinite) return 0;
  final index = progress.clamp(0.0, 1.0) * (samples.length - 1);
  final left = index.floor();
  final right = math.min(left + 1, samples.length - 1);
  double amplitude(int i) =>
      samples[i].isFinite ? samples[i].clamp(0.0, 1.0) : 0;
  return amplitude(left) +
      (amplitude(right) - amplitude(left)) * (index - left);
}

/// A waveform envelope proxy for the owned wave's advancing playback.
/// This uses fetched waveform bins, not a PCM or FFT audio meter. Missing bins
/// and stopped observations produce zero. The stable listenable repaints locally.
class WaveEnergy extends ConsumerStatefulWidget {
  const WaveEnergy({super.key, required this.enabled, required this.builder});

  final bool enabled;
  final Widget Function(BuildContext, ValueListenable<double>) builder;

  @override
  ConsumerState<WaveEnergy> createState() => _WaveEnergyState();
}

class _WaveEnergyState extends ConsumerState<WaveEnergy>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _energy = ValueNotifier<double>(0);
  late final Ticker _ticker;
  ProviderSubscription<AsyncValue<List<double>?>>? _samplesSubscription;
  PlayerState? _player;
  List<double>? _samples;
  String? _url;
  bool _visible = true;
  bool _motion = false;
  double _target = 0;
  Duration _elapsed = Duration.zero;
  Duration _lastFrame = Duration.zero;
  Duration _lastAdvance = Duration.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _visible =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _ticker = createTicker(_tick);
    ref.listenManual(
      playerControllerProvider,
      (_, next) => _observe(next),
      fireImmediately: true,
    );
  }

  bool get _allowed => widget.enabled && _visible && _motion;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motion =
        TickerMode.valuesOf(context).enabled &&
        !(MediaQuery.maybeOf(context)?.disableAnimations ?? false);
    _reset();
  }

  @override
  void didUpdateWidget(WaveEnergy oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) _reset();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = state == AppLifecycleState.resumed;
    _reset();
  }

  void _reset() {
    _ticker.stop();
    _elapsed = _lastFrame = _lastAdvance = Duration.zero;
    _target = 0;
    _energy.value = 0;
  }

  void _observe(PlayerState next) {
    final previous = _player;
    _player = next;
    final url = next.track?.waveformUrl;
    final identityChanged =
        previous?.track?.id != next.track?.id ||
        previous?.sessionVersion != next.sessionVersion ||
        _url != url;
    if (_url != url) _loadSamples(url);
    if (identityChanged || previous?.seekVersion != next.seekVersion) {
      _reset();
      return;
    }
    if (!_allowed ||
        !next.isPlaying ||
        next.muted ||
        next.volume <= 0 ||
        next.track == null ||
        next.track!.durationMs <= 0) {
      _reset();
      return;
    }
    final delta = next.position - (previous?.position ?? next.position);
    if (delta.isNegative || delta > const Duration(milliseconds: 1500)) {
      _reset();
      return;
    }
    if (delta == Duration.zero || _samples == null) return;
    _target = sampleWaveformEnergy(_samples!, next.progress);
    _lastAdvance = _elapsed;
    if (!_ticker.isActive) _ticker.start();
  }

  void _loadSamples(String? url) {
    _samplesSubscription?.close();
    _url = url;
    _samples = null;
    if (url == null || url.isEmpty) return;
    _samplesSubscription = ref.listenManual(waveformSamplesProvider(url), (
      _,
      value,
    ) {
      if (!mounted || _url != url) return;
      _samples = value.asData?.value;
      // Loading completion alone must never animate a stationary player.
      _reset();
    }, fireImmediately: true);
  }

  void _tick(Duration elapsed) {
    _elapsed = elapsed;
    if (!_allowed ||
        elapsed - _lastAdvance > const Duration(milliseconds: 750)) {
      _reset();
      return;
    }
    final dt = (elapsed - _lastFrame).inMicroseconds / 1000000;
    _lastFrame = elapsed;
    final timeConstant = _target > _energy.value ? .045 : .14;
    final weight = 1 - math.exp(-dt / timeConstant);
    _energy.value = (_energy.value + (_target - _energy.value) * weight).clamp(
      0.0,
      1.0,
    );
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _energy);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _samplesSubscription?.close();
    _ticker.dispose();
    _energy.dispose();
    super.dispose();
  }
}
