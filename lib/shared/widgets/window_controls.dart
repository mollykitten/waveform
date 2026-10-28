import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// Нужны ли свои кнопки окна: `titleBarStyle: hidden` на Windows/Linux
/// убирает системные, на macOS «светофор» остаётся нативным.
bool get needsWindowControls => Platform.isWindows || Platform.isLinux;

/// Ширина блока кнопок (3 × 46).
const windowControlsWidth = 138.0;

/// Свернуть / развернуть / закрыть для окна без системной рамки.
class WindowControls extends StatefulWidget {
  const WindowControls({super.key});

  @override
  State<WindowControls> createState() => _WindowControlsState();
}

class _WindowControlsState extends State<WindowControls> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then(_setMaximized);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  void _setMaximized(bool value) {
    if (mounted && value != _maximized) setState(() => _maximized = value);
  }

  @override
  void onWindowMaximize() => _setMaximized(true);

  @override
  void onWindowUnmaximize() => _setMaximized(false);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        WindowCaptionButton.minimize(
          brightness: Brightness.dark,
          onPressed: windowManager.minimize,
        ),
        if (_maximized)
          WindowCaptionButton.unmaximize(
            brightness: Brightness.dark,
            onPressed: windowManager.unmaximize,
          )
        else
          WindowCaptionButton.maximize(
            brightness: Brightness.dark,
            onPressed: windowManager.maximize,
          ),
        WindowCaptionButton.close(
          brightness: Brightness.dark,
          onPressed: windowManager.close,
        ),
      ],
    );
  }
}
