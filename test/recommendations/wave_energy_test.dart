import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/api/mock_soundcloud_api.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/features/player/player_controller.dart';
import 'package:waveform_app/features/recommendations/widgets/wave_energy.dart';
import 'package:waveform_app/shared/models/track.dart';
import 'package:waveform_app/shared/providers/waveform_samples.dart';
import 'package:waveform_app/shared/widgets/live_waveform.dart';
import 'package:waveform_app/shared/widgets/waveform_view.dart';

class SamplesApi extends MockSoundcloudApi {
  int calls = 0;
  final pending = <String, Completer<List<double>?>>{};
  @override
  Future<List<double>?> fetchWaveform(String url) {
    calls++;
    return (pending[url] ??= Completer<List<double>?>()).future;
  }
}

Track track(String id, {String? url = 'real'}) => Track(
  id: id,
  title: id,
  artist: 'artist',
  durationMs: 1000,
  likes: 0,
  reposts: 0,
  plays: 0,
  waveform: const [1, 1, 1],
  waveformUrl: url,
);

class TestPlayer extends PlayerController {
  @override
  PlayerState build() => PlayerState(track: track('a'), isPlaying: true);
  PlayerState get current => state;
  void publish(PlayerState value) => state = value;
}

void main() {
  test('interpolates real bins and clamps invalid amplitudes', () {
    expect(sampleWaveformEnergy([0, 1, 0], .25), .5);
    expect(sampleWaveformEnergy([1, 0, 1], .25), .5);
    expect(sampleWaveformEnergy([0, 1, 0], .5), 1);
    expect(sampleWaveformEnergy([1, 0, 1], .5), 0);
    expect(sampleWaveformEnergy([0, .2], .5), closeTo(.1, .001));
    expect(sampleWaveformEnergy([double.nan, double.infinity, -1], .5), 0);
    expect(sampleWaveformEnergy([2], .5), 1);
    expect(sampleWaveformEnergy([], .5), 0);
  });

  test(
    'URL provider deduplicates pending requests and session cache',
    () async {
      final api = SamplesApi();
      final container = ProviderContainer(
        overrides: [soundcloudApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      final a = container.read(waveformSamplesProvider('real').future);
      final b = container.read(waveformSamplesProvider('real').future);
      expect(api.calls, 1);
      api.pending['real']!.complete([.2, .8]);
      expect(await a, [.2, .8]);
      expect(await b, [.2, .8]);
      expect(await container.read(waveformSamplesProvider('real').future), [
        .2,
        .8,
      ]);
      expect(api.calls, 1);
    },
  );

  test('failed and empty responses do not trigger automatic retry', () async {
    final api = SamplesApi();
    final container = ProviderContainer(
      overrides: [soundcloudApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    final failed = container.read(waveformSamplesProvider('error').future);
    final assertion = expectLater(failed, throwsStateError);
    api.pending['error']!.completeError(StateError('offline'));
    await assertion;
    final empty = container.read(waveformSamplesProvider('empty').future);
    api.pending['empty']!.complete([]);
    expect(await empty, isNull);
    container.read(waveformSamplesProvider('error'));
    container.read(waveformSamplesProvider('empty'));
    expect(api.calls, 2);
  });

  test('failed URL retries on new demand after all listeners detach', () async {
    final api = SamplesApi();
    final container = ProviderContainer(
      overrides: [soundcloudApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    final provider = waveformSamplesProvider('retry');
    final first = container.listen(provider, (_, _) {});
    final second = container.listen(provider, (_, _) {});
    expect(api.calls, 1);
    final failure = expectLater(
      container.read(provider.future),
      throwsStateError,
    );
    api.pending['retry']!.completeError(StateError('temporary failure'));
    await failure;
    await container.pump();
    expect(first.read().hasError, isTrue);
    expect(second.read().hasError, isTrue);
    expect(api.calls, 1);
    first.close();
    await container.pump();
    expect(api.calls, 1);
    second.close();
    await container.pump();
    api.pending['retry'] = Completer<List<double>?>();
    final fresh = container.listen(provider, (_, _) {});
    final duplicate = container.listen(provider, (_, _) {});
    expect(api.calls, 2);
    api.pending['retry']!.complete([.25, .75]);
    expect(await container.read(provider.future), [.25, .75]);
    fresh.close();
    duplicate.close();
    await container.pump();
    expect(await container.read(provider.future), [.25, .75]);
    expect(api.calls, 2);
  });

  test('empty and null responses retry only after demand detaches', () async {
    for (final response in <List<double>?>[null, []]) {
      final api = SamplesApi();
      final container = ProviderContainer(
        overrides: [soundcloudApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      final provider = waveformSamplesProvider('empty');
      final demand = container.listen(provider, (_, _) {});
      api.pending['empty']!.complete(response);
      expect(await container.read(provider.future), isNull);
      await container.pump();
      expect(api.calls, 1);
      demand.close();
      await container.pump();
      api.pending['empty'] = Completer<List<double>?>();
      final fresh = container.listen(provider, (_, _) {});
      expect(api.calls, 2);
      api.pending['empty']!.complete([.5]);
      expect(await container.read(provider.future), [.5]);
      fresh.close();
    }
  });

  test('inflight URL remains deduplicated across listener gaps', () async {
    final api = SamplesApi();
    final container = ProviderContainer(
      overrides: [soundcloudApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    final provider = waveformSamplesProvider('pending');
    final first = container.listen(provider, (_, _) {});
    first.close();
    await container.pump();
    final fresh = container.listen(provider, (_, _) {});
    expect(api.calls, 1);
    api.pending['pending']!.complete([.8]);
    expect(await container.read(provider.future), [.8]);
    fresh.close();
    await container.pump();
    expect(await container.read(provider.future), [.8]);
    expect(api.calls, 1);
  });

  testWidgets('only real samples and advancing playback drive local energy', (
    tester,
  ) async {
    final api = SamplesApi();
    final player = TestPlayer();
    final container = ProviderContainer(
      overrides: [
        soundcloudApiProvider.overrideWithValue(api),
        playerControllerProvider.overrideWith(() => player),
      ],
    );
    addTearDown(container.dispose);
    late ValueListenable<double> energy;
    int builds = 0;
    Future<void> show({
      bool enabled = true,
      bool reduce = false,
      bool visible = true,
      bool forceFrames = false,
    }) => tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduce),
            child: TickerMode(
              enabled: visible,
              forceFrames: forceFrames,
              child: Column(
                children: [
                  WaveEnergy(
                    enabled: enabled,
                    builder: (context, value) {
                      energy = value;
                      builds++;
                      return const SizedBox();
                    },
                  ),
                  const LiveWaveform(waveformUrl: 'real', fallbackBars: [.5]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    void advance(int ms) => player.publish(
      player.current.copyWith(position: Duration(milliseconds: ms)),
    );
    Future<void> frame() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    await show();
    advance(100);
    await frame();
    expect(energy.value, 0);
    expect(api.calls, 1);
    api.pending['real']!.complete([0, 1, 0]);
    await tester.pump();
    expect(energy.value, 0);
    advance(250);
    await frame();
    expect(energy.value, greaterThan(0));
    final stable = energy;
    final buildCount = builds;
    advance(500);
    await frame();
    expect(identical(energy, stable), isTrue);
    expect(builds, buildCount);
    expect(energy.value, greaterThan(.5));
    await tester.pump(const Duration(milliseconds: 800));
    expect(energy.value, 0);
    advance(600);
    await frame();
    expect(energy.value, greaterThan(0));
    player.publish(player.current.copyWith(isPlaying: false));
    expect(energy.value, 0);
    player.publish(player.current.copyWith(isPlaying: true));
    advance(650);
    await frame();
    player.publish(player.current.copyWith(muted: true));
    expect(energy.value, 0);
    player.publish(player.current.copyWith(muted: false));
    advance(700);
    await frame();
    player.publish(
      player.current.copyWith(
        seekVersion: 1,
        position: const Duration(milliseconds: 200),
      ),
    );
    expect(energy.value, 0);
    advance(220);
    await frame();
    expect(energy.value, greaterThan(0));
    player.publish(player.current.copyWith(sessionVersion: 1));
    expect(energy.value, 0);
    advance(230);
    await frame();
    expect(energy.value, greaterThan(0));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(energy.value, 0);
    advance(240);
    await frame();
    expect(energy.value, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(energy.value, 0);
    await show(reduce: true);
    advance(250);
    await frame();
    expect(energy.value, 0);
    await show(visible: false, forceFrames: true);
    advance(300);
    await frame();
    expect(energy.value, 0);
    await show(enabled: false);
    advance(350);
    await frame();
    expect(energy.value, 0);
    await show();
    player.publish(
      PlayerState(track: track('b', url: 'late'), isPlaying: true),
    );
    advance(100);
    await frame();
    player.publish(PlayerState(track: track('b', url: null), isPlaying: true));
    api.pending['late']!.complete([1, 1]);
    await frame();
    advance(200);
    await frame();
    expect(energy.value, 0);
    player.publish(PlayerState(track: track('a'), isPlaying: true));
    advance(250);
    await frame();
    expect(energy.value, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
    advance(300);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'LiveWaveform keeps fallback for loading, errors and stale URLs',
    (tester) async {
      final api = SamplesApi();
      final container = ProviderContainer(
        overrides: [soundcloudApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      Future<void> show(String? url) => tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: LiveWaveform(waveformUrl: url, fallbackBars: const [.3, .4]),
          ),
        ),
      );
      List<double> bars() =>
          tester.widget<WaveformView>(find.byType(WaveformView)).bars;
      await show('old');
      expect(bars(), [.3, .4]);
      await show('current');
      api.pending['old']!.complete([1, 1]);
      await tester.pump();
      expect(bars(), [.3, .4]);
      api.pending['current']!.complete([.1, .9]);
      await tester.pump();
      expect(bars(), [.1, .9]);
      await show('error');
      api.pending['error']!.completeError(StateError('offline'));
      await tester.pump();
      expect(bars(), [.3, .4]);
      await show(null);
      expect(bars(), [.3, .4]);
      expect(tester.takeException(), isNull);
    },
  );
}
