import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A real output reported by CoreAudio. UIDs survive device reordering.
class AudioOutputDevice {
  const AudioOutputDevice({
    required this.uid,
    required this.name,
    required this.transport,
  });

  final String uid;
  final String name;
  final String transport;
}

/// Requested output is retained when a device disconnects.
class AudioOutputState {
  const AudioOutputState({
    this.supported = false,
    this.devices = const [],
    this.requestedUid,
    this.effectiveUid,
    this.airPlayActive = false,
    this.preservePlayer = false,
    this.message,
  });

  factory AudioOutputState.fromMap(Map<Object?, Object?> map) {
    final devices = <AudioOutputDevice>[];
    final rawDevices = map['devices'];
    if (rawDevices is List) {
      for (final raw in rawDevices) {
        if (raw is! Map || raw['uid'] is! String || raw['name'] is! String) {
          continue;
        }
        devices.add(
          AudioOutputDevice(
            uid: raw['uid'] as String,
            name: raw['name'] as String,
            transport: raw['transport'] is String
                ? raw['transport'] as String
                : 'unknown',
          ),
        );
      }
    }
    return AudioOutputState(
      supported: map['supported'] == true,
      devices: List.unmodifiable(devices),
      requestedUid: map['requestedUid'] is String
          ? map['requestedUid'] as String
          : null,
      effectiveUid: map['effectiveUid'] is String
          ? map['effectiveUid'] as String
          : null,
      airPlayActive: map['airPlayActive'] == true,
      preservePlayer: map['preservePlayer'] == true,
      message: map['message'] is String ? map['message'] as String : null,
    );
  }

  final bool supported;
  final List<AudioOutputDevice> devices;
  final String? requestedUid;
  final String? effectiveUid;
  final bool airPlayActive;
  final bool preservePlayer;
  final String? message;

  String get selectedName {
    if (airPlayActive) return 'AirPlay';
    if (preservePlayer && effectiveUid == null) return 'route unconfirmed';
    if (requestedUid == null) return 'system default';
    for (final device in devices) {
      if (device.uid == requestedUid) return device.name;
    }
    return 'saved device unavailable · system default';
  }

  AudioOutputState withStatus({String? message, bool? preservePlayer}) =>
      AudioOutputState(
        supported: supported,
        devices: devices,
        requestedUid: requestedUid,
        effectiveUid: effectiveUid,
        airPlayActive: airPlayActive,
        preservePlayer: preservePlayer ?? this.preservePlayer,
        message: message,
      );
}

/// Platform bridge, injectable to test asynchronous routing races.
abstract interface class AudioOutputPlatform {
  bool get supported;
  Stream<Object?> get events;
  Future<Object?> getState();
  Future<Object?> setDevice(String? uid);
  Future<Object?> showAirPlay();
}

class MethodChannelAudioOutput implements AudioOutputPlatform {
  const MethodChannelAudioOutput();

  static const _methods = MethodChannel('waveform/audio_output');
  static const _events = EventChannel('waveform/audio_output_events');

  @override
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
  @override
  Stream<Object?> get events => _events.receiveBroadcastStream();
  @override
  Future<Object?> getState() => _methods.invokeMethod<Object?>('getState');
  @override
  Future<Object?> setDevice(String? uid) =>
      _methods.invokeMethod<Object?>('setDevice', {'uid': uid});
  @override
  Future<Object?> showAirPlay() =>
      _methods.invokeMethod<Object?>('showAirPlay');
}

abstract interface class AudioOutputPreferences {
  Future<String?> read();
  Future<void> write(String? uid);
}

/// The native routing API persists its dedicated NSUserDefaults key before
/// completing mutations and restores it in getState and lazy player creation.
/// No second Dart store may overwrite that authoritative snapshot on startup.
class NativeAudioOutputPreferences implements AudioOutputPreferences {
  const NativeAudioOutputPreferences();

  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String? uid) async {}
}

final audioOutputPlatformProvider = Provider<AudioOutputPlatform>(
  (ref) => const MethodChannelAudioOutput(),
);
final audioOutputPreferencesProvider = Provider<AudioOutputPreferences>(
  (ref) => const NativeAudioOutputPreferences(),
);

class AudioOutputController extends Notifier<AudioOutputState> {
  late AudioOutputPlatform _platform;
  late AudioOutputPreferences _preferences;
  bool _disposed = false;
  bool _airPlayLatch = false;
  bool _confirmedAirPlayLatch = false;
  bool _nativePreservePlayer = false;
  int _intent = 0;
  int _snapshotRevision = 0;
  Future<void> _operations = Future.value();
  Future<void> _routingOperations = Future.value();

  bool get preservePlayer => _airPlayLatch || state.preservePlayer;

  /// Serializes native player binding and output routing as one transaction.
  /// A failed transaction is reported to its caller without poisoning the gate.
  Future<T> routingTransaction<T>(Future<T> Function() operation) {
    final next = _routingOperations.then((_) {
      if (_disposed) throw StateError('Audio output controller is disposed');
      return operation();
    });
    _routingOperations = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return next;
  }

  @override
  AudioOutputState build() {
    _platform = ref.read(audioOutputPlatformProvider);
    _preferences = ref.read(audioOutputPreferencesProvider);
    ref.onDispose(() => _disposed = true);
    if (!_platform.supported) {
      return const AudioOutputState(
        message:
            'Output selection is unavailable on this platform. '
            'It is currently supported on macOS.',
      );
    }
    final subscription = _platform.events.listen(
      _accept,
      onError: (Object error) => _error(error),
    );
    ref.onDispose(subscription.cancel);
    unawaited(_initialize());
    return const AudioOutputState(supported: true);
  }

  Future<void> _initialize() async {
    final intent = _intent;
    final revision = _snapshotRevision;
    try {
      final snapshot = await _platform.getState();
      if (!_disposed && intent == _intent && revision == _snapshotRevision) {
        _accept(snapshot);
      }
      final uid = await _preferences.read();
      if (_disposed || intent != _intent || uid == null) return;
      await selectDevice(uid);
    } catch (error) {
      if (intent == _intent) _error(error);
    }
  }

  void _accept(Object? raw) {
    if (_disposed || raw is! Map) return;
    _snapshotRevision++;
    final snapshot = AudioOutputState.fromMap(Map<Object?, Object?>.from(raw));
    _nativePreservePlayer = snapshot.preservePlayer;
    state = snapshot.withStatus(
      message: snapshot.message,
      preservePlayer: snapshot.preservePlayer || _airPlayLatch,
    );
  }

  void _error(Object error) {
    if (!_disposed) {
      final message = switch (error) {
        PlatformException(code: 'no_active_player') =>
          'Play a track before opening the AirPlay picker.',
        MissingPluginException() =>
          'Audio output selection is unavailable in this build.',
        _ => 'Could not change audio output. Please try again.',
      };
      state = state.withStatus(message: message);
    }
  }

  Future<void> selectDevice(String? uid) {
    if (_disposed || !_platform.supported) return Future.value();
    final intent = ++_intent;
    // Serialize mutations so a slow older selection cannot win natively.
    final operation = _operations.then((_) async {
      if (_disposed || intent != _intent) return;
      try {
        await routingTransaction(() async {
          if (_disposed || intent != _intent) return;
          final revision = _snapshotRevision;
          final snapshot = await _platform.setDevice(uid);
          if (_disposed) return;
          _confirmedAirPlayLatch = false;
          if (_disposed || intent != _intent) return;
          _airPlayLatch = false;
          if (revision == _snapshotRevision) {
            _accept(snapshot);
          } else {
            state = state.withStatus(
              message: state.message,
              preservePlayer: _nativePreservePlayer,
            );
          }
        });
        if (_disposed || intent != _intent) return;
        await _preferences.write(uid);
      } catch (error) {
        if (intent == _intent) _error(error);
      }
    });
    _operations = operation;
    return operation;
  }

  Future<void> showAirPlay() {
    if (_disposed || !_platform.supported) return Future.value();
    // Set before invoking native code: next-track must retain this player.
    _airPlayLatch = true;
    state = state.withStatus(preservePlayer: true);
    final intent = ++_intent;
    final operation = _operations.then((_) async {
      if (_disposed || intent != _intent) return;
      var attempted = false;
      try {
        await routingTransaction(() async {
          if (_disposed || intent != _intent) return;
          final revision = _snapshotRevision;
          attempted = true;
          final snapshot = await _platform.showAirPlay();
          if (!_disposed) _confirmedAirPlayLatch = true;
          if (!_disposed &&
              intent == _intent &&
              revision == _snapshotRevision) {
            _accept(snapshot);
          }
        });
        if (!_disposed && intent == _intent) {
          await _preferences.write(null);
        }
      } catch (error) {
        // These failures guarantee that no native route picker was opened.
        final unopened =
            error is MissingPluginException ||
            error is PlatformException &&
                const {
                  'no_active_player',
                  'unsupported',
                  'unsupported_platform',
                }.contains(error.code);
        if (!_disposed && attempted && !unopened) {
          _confirmedAirPlayLatch = true;
        }
        if (!_disposed && intent == _intent) {
          if (unopened) {
            // Superseded optimistic clicks are not a confirmed routing state.
            _airPlayLatch = _confirmedAirPlayLatch;
            state = state.withStatus(
              preservePlayer: _confirmedAirPlayLatch || _nativePreservePlayer,
            );
          }
          // Ambiguous failures may have happened after showing the picker.
          _error(error);
        }
      }
    });
    _operations = operation;
    return operation;
  }
}

final audioOutputProvider =
    NotifierProvider<AudioOutputController, AudioOutputState>(
      AudioOutputController.new,
    );
