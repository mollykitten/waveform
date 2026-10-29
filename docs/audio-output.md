# audio output on macos

waveform vendors just_audio 0.10.6 in `third_party/just_audio`. its original
license is retained. the local patch adds a macos output coordinator and an
explicit connection between the dart player and its native AVQueuePlayer.
the platform interface dependency remains upstream.

the output menu lists devices returned by core audio with live output channels.
selecting a device sets `AVPlayer.audioOutputDeviceUniqueID` on waveform's
players. selecting system default clears that property. waveform does not
write the system's default output device. disconnected selections fall back
to the system default and remain distinguishable from the effective output.
the native coordinator persists the requested UID in its dedicated
`waveform.requestedAudioOutputUid` preference key before lazy player creation.
it is the production source of truth; `prefs.json` is not involved.

airplay uses a visible native `AVRoutePickerView` bound to the actual active
AVQueuePlayer. opening the picker conservatively preserves that player for
following tracks, disabling crossfade and swaps between players. selecting a
local output explicitly exits this conservative mode. opening the picker alone
does not establish that a receiver is connected.
opening or dismissing the picker preserves the previous local output and its
saved preference. presentation callbacks do not confirm a route change.

native binding, active-player changes and picker presentation share a routing
transaction queue. this keeps the picker attached to the player retained by the
engine even when the user opens it during a pending track transition. hotplug
events take precedence over older method replies.

## contracts

- [per-player output device](https://developer.apple.com/documentation/avfoundation/avplayer/audiooutputdeviceuniqueid)
- [route picker player binding](https://developer.apple.com/documentation/avkit/avroutepickerview/player)
- [core audio device enumeration](https://developer.apple.com/documentation/coreaudio/kaudiohardwarepropertydevices)

the installed macos sdk confirms these APIs are available below waveform's
macos 12 deployment target. core audio device UIDs identify devices locally;
they should not be included in analytics or diagnostic reports.

## integration verification

for interactive verification, the runtime owner launches the dev-only target
`tool/driver_main.dart`, then uses Dart MCP's `flutter_driver` against that app.
the bootstrap enables the extension and delegates to the real `app.main(args)`,
including normal network and audio paths. production and release launches
continue to use `lib/main.dart` by default.

unit tests and native compilation cannot establish that sound reaches a physical
receiver. the runtime owner must check the following on hardware:

- select built-in, usb, and bluetooth outputs while a track plays; verify that
  another app's output and the system default remain unchanged;
- disconnect the selected output and confirm the fallback message and effective
  output, then reconnect it;
- open the native airplay picker, select a real receiver, and advance through
  several tracks; verify that playback stays on the receiver;
- switch back to a local output and verify regular gapless/crossfade behavior;
- check keyboard and voiceover access in full and collapsed player layouts and
  capture screenshots at the minimum window width.

other operating systems display their actual unsupported state. no network
receiver list is fabricated, and system settings are not used as an output
selector.
