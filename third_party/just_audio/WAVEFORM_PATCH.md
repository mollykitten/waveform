# waveform macos output routing

vendored from `just_audio` 0.10.6; the upstream license is retained in `LICENSE`.

local changes:

- `AudioPlayer.setAsAudioOutputPlayer()` awaits the platform instance and binds
  its actual per-player native channel. call after loading and after a swap.
- `WaveformAudioOutput` owns the live CoreAudio output inventory, per-player UID
  routing, requested selection, event channel and visible native AirPlay picker.
  `JustAudioPlugin` owns its lifecycle; `AudioPlayer` reports creation,
  activation and disposal explicitly.
- `waveform/audio_output`: `getState`, `setDevice({uid})`, `showAirPlay` return
  snapshots. `waveform/audio_output_events` publishes the same snapshots.
- opening AirPlay latches `preservePlayer` until explicit `setDevice`. audio-only
  AirPlay routing is not reliably represented by `externalPlaybackActive`;
  `airPlayActive` reports observed routing and does not imply the latch confirmed
  a receiver. unknown `effectiveUid` is null.
- opening or dismissing the native picker preserves the requested local UID,
  all player output UIDs and the native preference. the last local choice also
  remains persisted during receiver playback. presentation delegate callbacks
  do not imply route selection; late KVO observations publish actual state.
- a missing requested UID is retained, while every local player follows the
  system output through a nil UID. reconnect restores the requested output.
  the system default itself is never changed.
- podspec and Swift package link AVKit/CoreAudio on macOS. analyzer options
  exclude upstream example/test projects with separate development packages and
  preserve upstream constructor style.

the standalone `darwin/Tests/audio_output_probe.m` loads the native coordinator
with a fake Flutter messenger and real CoreAudio inventory. it does not launch
Flutter, create a window, play media or change system defaults. it checks all
player selection, lazy creation, missing UID fallback, simulated inventory
disconnect/reconnect policy, event snapshots, route uncertainty, invalid input
and disposal. a rendering-only subclass exercises the real AirPlay method and
delegate paths headlessly, checking unchanged AVQueuePlayer outputs, actual
NSUserDefaults persistence and restoration by a new coordinator after dismissal.
compile the probe and `WaveformAudioOutput.m` with ARC, blocks and
the FlutterMacOS, Cocoa, AVFoundation, AVKit and CoreAudio frameworks; use the
installed FlutterMacOS xcframework path for `-F` and runtime rpath.

coreaudio property listeners must not use the main queue. hal delivers device
teardown notifications with a `dispatch_sync` onto the listener queue while
holding its lock, and `AudioObjectRemovePropertyListenerBlock` waits for that
lock, so a main-queue listener that removes listeners (refresh) deadlocks the
app when a device disappears, for example on screen lock. listeners live on a
private serial queue and only `dispatch_async` the refresh to main.

physical hotplug, receiver connection and audible playback still require a
manual hardware test in the owning app runtime.
