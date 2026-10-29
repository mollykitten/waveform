import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../shared/intents.dart';

/// Чистый билдер карты шорткатов (тестируется без виджет-дерева).
/// `G`-аккорды и standalone-буквы, конфликтующие с вводом, гасит TextField
/// (он съедает символьные клавиши раньше, чем их увидит Shortcuts).
Map<ShortcutActivator, Intent> buildShortcuts({
  required bool isMac,
  required String location,
}) {
  SingleActivator cmd(LogicalKeyboardKey k, {bool shift = false}) =>
      SingleActivator(k, meta: isMac, control: !isMac, shift: shift);

  final m = <ShortcutActivator, Intent>{
    const SingleActivator(LogicalKeyboardKey.space): const PlayPauseIntent(),
    const SingleActivator(LogicalKeyboardKey.arrowRight): const SeekForwardIntent(),
    const SingleActivator(LogicalKeyboardKey.arrowLeft): const SeekBackwardIntent(),
    const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): const NextTrackIntent(),
    const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): const PrevTrackIntent(),
    const SingleActivator(LogicalKeyboardKey.arrowUp, shift: true): const VolumeUpIntent(),
    const SingleActivator(LogicalKeyboardKey.arrowDown, shift: true): const VolumeDownIntent(),
    const SingleActivator(LogicalKeyboardKey.keyM): const MuteToggleIntent(),
    const SingleActivator(LogicalKeyboardKey.keyL): const LikePlayingIntent(),
    const SingleActivator(LogicalKeyboardKey.keyL, shift: true): const RepeatToggleIntent(),
    const SingleActivator(LogicalKeyboardKey.keyR): const RepostPlayingIntent(),
    const SingleActivator(LogicalKeyboardKey.keyP): const NavigateToPlayingIntent(),
    const SingleActivator(LogicalKeyboardKey.keyS): const OpenSearchIntent(),
    const SingleActivator(LogicalKeyboardKey.keyS, shift: true): const ShuffleToggleIntent(),
    const SingleActivator(LogicalKeyboardKey.keyQ): const ToggleQueueIntent(),
    const SingleActivator(LogicalKeyboardKey.keyH): const ShowShortcutsIntent(),
    cmd(LogicalKeyboardKey.keyK): const FocusOmniboxIntent(),
    cmd(LogicalKeyboardKey.keyF): const FocusOmniboxIntent(),
    cmd(LogicalKeyboardKey.keyL): const JumpLikesIntent(),
    cmd(LogicalKeyboardKey.comma): const JumpSettingsIntent(),
    cmd(LogicalKeyboardKey.keyL, shift: true): const JumpLogsIntent(),
    cmd(LogicalKeyboardKey.keyC, shift: true): const CopyLinkIntent(),
  };

  const digits = <LogicalKeyboardKey>[
    LogicalKeyboardKey.digit0, LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3, LogicalKeyboardKey.digit4, LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6, LogicalKeyboardKey.digit7, LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  ];
  for (var i = 0; i < digits.length; i++) {
    m[SingleActivator(digits[i])] = SeekToPercentIntent(i);
  }

  if (location.startsWith('/track/')) {
    m[const SingleActivator(LogicalKeyboardKey.enter)] = const PlayPageTrackIntent();
    m[const SingleActivator(LogicalKeyboardKey.numpadEnter)] = const PlayPageTrackIntent();
  }
  return m;
}
