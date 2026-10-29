import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/prefs_store.dart';

/// Настройки воспроизведения, персистятся в `prefs.json`.
/// `crossfade == 0` → чистый gapless (preload + мгновенный swap).
/// `crossfade > 0` → плавный fade-out/in между треками (1–6 сек).
class PlaybackPrefs {
  const PlaybackPrefs({
    this.crossfadeMs = 0,
    this.volume = defaultVolume,
    this.muted = false,
  });

  /// Громкость первого запуска: умеренная, не 1.0.
  static const defaultVolume = 0.5;

  final int crossfadeMs;

  /// Позиция ползунка громкости 0..1 (линейная, как в `PlayerState.volume`).
  final double volume;
  final bool muted;
  Duration get crossfade => Duration(milliseconds: crossfadeMs);

  PlaybackPrefs copyWith({int? crossfadeMs, double? volume, bool? muted}) =>
      PlaybackPrefs(
        crossfadeMs: crossfadeMs ?? this.crossfadeMs,
        volume: volume ?? this.volume,
        muted: muted ?? this.muted,
      );
}

/// Подменяется в тестах (path_provider там не отвечает).
final playbackPrefsStoreProvider = Provider<PrefsStore>(
  (_) => const PrefsStore(),
);

class PlaybackPrefsController extends Notifier<PlaybackPrefs>
    with WidgetsBindingObserver {
  static const _keyCrossfade = 'playback_crossfade_ms';
  static const _keyVolume = 'playback_volume';
  static const _keyMuted = 'playback_muted';
  static const _volumeDebounce = Duration(milliseconds: 400);

  late final PrefsStore _store = ref.read(playbackPrefsStoreProvider);
  Timer? _volumeTimer;

  /// Завершается, когда сохранённые значения прочитаны (или чтение не удалось).
  Future<void> restored = Future<void>.value();

  @override
  PlaybackPrefs build() {
    _store; // resolve now: ref can't be used inside onDispose
    // Контейнер при выходе из десктоп-приложения не диспозится: сбрасываем
    // отложенную запись, как только окно теряет фокус/скрывается/закрывается.
    WidgetsFlutterBinding.ensureInitialized().addObserver(this);
    ref.onDispose(() {
      WidgetsBinding.instance.removeObserver(this);
      if (_volumeTimer?.isActive ?? false) _flushVolume();
      _volumeTimer?.cancel();
    });
    restored = _restore();
    return const PlaybackPrefs();
  }

  Future<void> _restore() async {
    try {
      final raw = await _store.readString(_keyCrossfade);
      final v = raw == null ? null : int.tryParse(raw);
      if (v != null) state = state.copyWith(crossfadeMs: v.clamp(0, 6000));
      final vol = double.tryParse(await _store.readString(_keyVolume) ?? '');
      final muted = await _store.readBool(_keyMuted);
      // Пользователь уже тронул громкость до окончания чтения — не затираем.
      if (_volumeTouched) return;
      if (vol != null && vol.isFinite) {
        state = state.copyWith(volume: vol.clamp(0.0, 1.0));
      }
      if (muted != null) state = state.copyWith(muted: muted);
    } catch (_) {}
  }

  bool _volumeTouched = false;
  double _pendingVolume = PlaybackPrefs.defaultVolume;
  bool _pendingMuted = false;

  /// Запоминает громкость/mute; запись на диск — с debounce, чтобы скролл
  /// колесом и стрелки не писали файл на каждый шаг.
  void setVolume(double volume, {required bool muted}) {
    _volumeTouched = true;
    final v = volume.clamp(0.0, 1.0);
    state = state.copyWith(volume: v, muted: muted);
    _pendingVolume = v;
    _pendingMuted = muted;
    _volumeTimer?.cancel();
    _volumeTimer = Timer(_volumeDebounce, _flushVolume);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed &&
        (_volumeTimer?.isActive ?? false)) {
      _volumeTimer!.cancel();
      _flushVolume();
    }
  }

  void _flushVolume() {
    final volume = _pendingVolume;
    final muted = _pendingMuted;
    unawaited(
      _safe(() async {
        await _store.writeString(_keyVolume, '$volume');
        await _store.writeBool(_keyMuted, muted);
      }),
    );
  }

  void setCrossfadeMs(int ms) {
    final v = ms.clamp(0, 6000);
    state = state.copyWith(crossfadeMs: v);
    unawaited(_safe(() => _store.writeString(_keyCrossfade, '$v')));
  }

  Future<void> _safe(Future<void> Function() op) async {
    try {
      await op();
    } catch (_) {}
  }
}

final playbackPrefsProvider =
    NotifierProvider<PlaybackPrefsController, PlaybackPrefs>(
      PlaybackPrefsController.new,
    );
