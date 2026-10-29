import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../features/player/player_controller.dart';
import '../log/talker.dart';

/// macOS status-bar item mirroring the player: track title, play/pause,
/// prev/next, volume presets, like. Pure view over [playerControllerProvider];
/// no playback logic lives here. No-op on other platforms.
final trayMenuProvider = Provider<void>((ref) {
  if (!Platform.isMacOS) return;
  final tray = _TrayMenu(ref);
  ref.onDispose(tray.dispose);
});

const _volumePresets = [0.0, 0.25, 0.5, 0.75, 1.0];

class _TrayMenu with TrayListener {
  _TrayMenu(this._ref) {
    trayManager.addListener(this);
    _init();
    _ref.listen<PlayerState>(playerControllerProvider, (prev, next) {
      if (prev == null ||
          prev.track?.id != next.track?.id ||
          prev.isPlaying != next.isPlaying ||
          prev.liked != next.liked ||
          prev.volume != next.volume ||
          prev.muted != next.muted) {
        _rebuild();
      }
    });
  }

  final Ref _ref;
  bool _disposed = false;

  Future<void> _init() async {
    try {
      await trayManager.setIcon(
        'assets/tray/tray_template.png',
        isTemplate: true,
      );
      await _rebuild();
    } catch (e, st) {
      _ref.read(talkerProvider).warning('tray init failed', e, st);
    }
  }

  Future<void>? _inFlight;
  bool _dirty = false;

  /// Serialized: while a rebuild is in flight, later calls only mark the menu
  /// dirty so the final state (read fresh each pass) always wins.
  Future<void> _rebuild() {
    _dirty = true;
    return _inFlight ??= _drain().whenComplete(() => _inFlight = null);
  }

  Future<void> _drain() async {
    while (_dirty && !_disposed) {
      _dirty = false;
      await _applyMenu();
    }
  }

  Future<void> _applyMenu() async {
    final s = _ref.read(playerControllerProvider);
    final track = s.track;
    final hasTrack = track != null;
    final vol = s.muted ? 0.0 : s.volume;
    final nearest = _volumePresets.reduce(
      (a, b) => (vol - a).abs() <= (vol - b).abs() ? a : b,
    );
    try {
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(
              label: hasTrack
                  ? '${track.artist} — ${track.title}'
                  : 'Nothing playing',
              disabled: true,
            ),
            MenuItem.separator(),
            MenuItem(
              key: 'toggle',
              label: s.isPlaying ? 'Pause' : 'Play',
              disabled: !hasTrack,
            ),
            MenuItem(key: 'previous', label: 'Previous', disabled: !hasTrack),
            MenuItem(key: 'next', label: 'Next', disabled: !hasTrack),
            MenuItem.separator(),
            MenuItem.submenu(
              label: 'Volume',
              submenu: Menu(
                items: [
                  for (final v in _volumePresets)
                    MenuItem.checkbox(
                      key: 'volume:$v',
                      label: '${(v * 100).round()}%',
                      checked: v == nearest,
                    ),
                ],
              ),
            ),
            MenuItem.checkbox(
              key: 'like',
              label: 'Like',
              checked: s.liked,
              disabled: !hasTrack,
            ),
            MenuItem.separator(),
            MenuItem(key: 'show', label: 'Show Waveform'),
            MenuItem(key: 'quit', label: 'Quit Waveform'),
          ],
        ),
      );
    } catch (e, st) {
      _ref.read(talkerProvider).warning('tray menu failed', e, st);
    }
  }

  @override
  void onTrayIconMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem item) {
    final player = _ref.read(playerControllerProvider.notifier);
    final key = item.key ?? '';
    if (key.startsWith('volume:')) {
      final v = double.tryParse(key.substring(7));
      if (v != null) {
        player.setVolume(v);
      }
      return;
    }
    switch (key) {
      case 'toggle':
        player.toggle();
      case 'previous':
        player.previous();
      case 'next':
        player.next();
      case 'like':
        player.toggleLike();
      case 'show':
        windowManager.show();
        windowManager.focus();
      case 'quit':
        SystemNavigator.pop();
    }
  }

  void dispose() {
    _disposed = true;
    trayManager.removeListener(this);
    trayManager.destroy();
  }
}
