import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/audio_output.dart';

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
    final showName = !compact && MediaQuery.sizeOf(context).width >= 1100;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      child: PopupMenuButton<String>(
        tooltip: label,
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
            PopupMenuItem<String>(
              enabled: false,
              child: Text('audio output · ${output.selectedName}'),
            ),
            CheckedPopupMenuItem<String>(
              value: 'default',
              checked: output.requestedUid == null && !output.airPlayActive,
              child: const Text('system default'),
            ),
            for (final device in output.devices)
              CheckedPopupMenuItem<String>(
                value: 'device:${device.uid}',
                checked:
                    output.requestedUid == device.uid && !output.airPlayActive,
                child: SizedBox(
                  width: 220,
                  child: Text(device.name, overflow: TextOverflow.ellipsis),
                ),
              ),
            const PopupMenuDivider(),
            const PopupMenuItem<String>(
              value: 'airplay',
              child: Text('AirPlay…'),
            ),
            if (output.preservePlayer)
              const PopupMenuItem<String>(
                enabled: false,
                child: SizedBox(
                  width: 240,
                  child: Text(
                    'Gapless and crossfade are paused for AirPlay. '
                    'Select a local output to restore them.',
                  ),
                ),
              ),
          ],
          if (output.message case final message?)
            PopupMenuItem<String>(
              enabled: false,
              child: SizedBox(width: 240, child: Text(_message(message))),
            ),
        ],
        child: Semantics(
          label: label,
          button: true,
          child: ExcludeSemantics(
            child: SizedBox(
              width: showName ? 120 : 32,
              height: 32,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    output.airPlayActive
                        ? Icons.airplay
                        : Icons.speaker_group_outlined,
                    size: 18,
                  ),
                  if (showName) ...[
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        output.supported ? output.selectedName : 'unavailable',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

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
