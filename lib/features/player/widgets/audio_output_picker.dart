import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/audio_output.dart';
import '../../../app/theme/app_theme.dart';
import '../../../app/theme/colors.dart';

/// Keyboard and screen-reader accessible output routing menu.
class AudioOutputPicker extends ConsumerWidget {
  const AudioOutputPicker({this.compact = false, super.key});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final output = ref.watch(audioOutputProvider);
    final controller = ref.read(audioOutputProvider.notifier);
    final label = output.supported
        ? 'Audio output: ${output.selectedName}'
        : 'Audio output: unavailable on this platform';
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      child: PopupMenuButton<String>(
        tooltip: label,
        color: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        menuPadding: const EdgeInsets.symmetric(vertical: 6),
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 320),
        shape: const RoundedRectangleBorder(
          borderRadius: AppTheme.borderRadius,
          side: AppTheme.borderSideStatic,
        ),
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          fixedSize: const Size(32, 32),
          minimumSize: const Size(32, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onSelected: (value) {
          if (value == 'airplay') {
            controller.showAirPlay();
          } else {
            controller.selectDevice(
              value == 'default' ? null : value.substring(7),
            );
          }
        },
        itemBuilder: (context) => [
          if (output.supported) ...[
            const PopupMenuItem<String>(
              enabled: false,
              height: 28,
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                'audio output',
                style: TextStyle(fontSize: 10, color: AppColors.textMid),
              ),
            ),
            _outputItem(
              value: 'default',
              name: 'system default',
              icon: Icons.speaker_group_outlined,
              selected: output.requestedUid == null && !output.airPlayActive,
            ),
            for (final device in output.devices)
              _outputItem(
                value: 'device:${device.uid}',
                name: device.name,
                icon: switch (device.transport.toLowerCase()) {
                  'bluetooth' => Icons.bluetooth_audio,
                  'usb' => Icons.usb,
                  _ => Icons.speaker_outlined,
                },
                selected:
                    output.requestedUid == device.uid && !output.airPlayActive,
              ),
            const PopupMenuDivider(height: 12),
            _outputItem(
              value: 'airplay',
              name: 'AirPlay…',
              icon: Icons.airplay,
              selected: output.airPlayActive,
            ),
            if (output.preservePlayer)
              const PopupMenuItem<String>(
                enabled: false,
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: SizedBox(
                  width: 240,
                  child: Text(
                    'Gapless and crossfade are paused for AirPlay. '
                    'Select a local output to restore them.',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.textMid,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
          ],
          if (output.message case final message?)
            PopupMenuItem<String>(
              enabled: false,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: SizedBox(
                width: 240,
                child: Text(
                  _message(message),
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textMid,
                    height: 1.5,
                  ),
                ),
              ),
            ),
        ],
        child: Semantics(
          label: label,
          button: true,
          child: ExcludeSemantics(
            child: SizedBox(
              width: 32,
              height: 32,
              child: Icon(
                output.airPlayActive
                    ? Icons.airplay
                    : Icons.speaker_group_outlined,
                size: 18,
                color: output.airPlayActive
                    ? AppColors.acid
                    : AppColors.textMid,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

PopupMenuItem<String> _outputItem({
  required String value,
  required String name,
  required IconData icon,
  required bool selected,
}) => PopupMenuItem<String>(
  value: value,
  height: 36,
  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  child: Semantics(
    selected: selected,
    child: Row(
      children: [
        Icon(
          icon,
          size: 14,
          color: selected ? AppColors.acid : AppColors.textMid,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                softWrap: true,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: selected ? AppColors.acid : AppColors.textHi,
                ),
              ),
              if (selected)
                const Padding(
                  padding: EdgeInsets.only(top: 3),
                  child: Text(
                    'current output',
                    style: TextStyle(fontSize: 10, color: AppColors.textMid),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 14,
          child: selected
              ? const Icon(Icons.check, size: 14, color: AppColors.acid)
              : null,
        ),
      ],
    ),
  ),
);

String _message(String message) => switch (message) {
  'device_unavailable' =>
    'Saved output is disconnected. Using the system default until it returns.',
  'airplay_route_unverified' =>
    'AirPlay connection is not confirmed. Choose a receiver in AirPlay.',
  'no_output_device' => 'No audio output device is available.',
  'audio_output_unavailable' => 'Audio output selection is unavailable.',
  'no_active_player' || 'Play a track before opening the AirPlay picker.' =>
    'Play a track before opening the AirPlay picker.',
  'Audio output selection is unavailable in this build.' =>
    'Audio output selection is unavailable in this build.',
  'Output selection is unavailable on this platform. '
      'It is currently supported on macOS.' =>
    'Output selection is unavailable on this platform. '
        'It is currently supported on macOS.',
  'Could not change audio output. Please try again.' =>
    'Could not change audio output. Please try again.',
  _ => 'Could not change audio output. Please try again.',
};
