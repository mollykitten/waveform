import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/api/client_id_resolver.dart';
import 'package:waveform_app/core/api/liked_tracks.dart';
import 'package:waveform_app/core/api/mock_soundcloud_api.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/audio/audio_engine.dart';
import 'package:waveform_app/core/drm/drm_stream_service.dart';
import 'package:waveform_app/features/player/player_controller.dart';
import 'package:waveform_app/shared/models/track.dart';

import '../support/fake_audio_engine.dart';
import '../support/stub_liked_tracks.dart';

/// DRM-сервис, который не дешифрует, а сразу отдаёт [uri] (или null —
/// «DRM недоступен»).
class _FakeDrm extends DrmStreamService {
  _FakeDrm(this.uri) : super(ids: ClientIdResolver(Dio()));

  final String? uri;
  Track? prepared;

  @override
  Future<String?> prepare(Track track) async {
    prepared = track;
    return uri;
  }
}

Track _goPlus({String id = 'g1', String title = 'G'}) => Track(
  id: id,
  title: title,
  artist: 'A',
  durationMs: 100000,
  likes: 0,
  reposts: 0,
  plays: 0,
  waveform: const <double>[],
  // GO+: незашифрованных кандидатов нет вообще, только ctr-поток.
  drmStreamCandidates: const ['https://x/stream/ctr-encrypted-hls'],
);

ProviderContainer harness(
  FakeAudioEngine engine,
  DrmStreamService drm, {
  bool mockApi = false,
}) => ProviderContainer(
  overrides: [
    audioEngineProvider.overrideWithValue(engine),
    likedTracksProvider.overrideWith(StubLikedTracks.new),
    drmStreamServiceProvider.overrideWithValue(drm),
    if (mockApi)
      soundcloudApiProvider.overrideWith((ref) => const MockSoundcloudApi()),
  ],
);

void main() {
  test(
    'GO+ без plaintext-кандидатов — играет дешифрованный файл из сервиса',
    () async {
      final engine = FakeAudioEngine();
      final drm = _FakeDrm('file:///tmp/g1.mp3');
      final c = harness(engine, drm);
      addTearDown(c.dispose);

      c.read(playerControllerProvider.notifier).play(_goPlus());
      await pumpEventQueue();

      expect(drm.prepared?.id, 'g1');
      expect(engine.lastLoadedUrl, 'file:///tmp/g1.mp3');
      expect(c.read(playerControllerProvider).unplayable, isNull);
    },
  );

  test('DRM недоступен (null) — трек помечен непроигрываемым', () async {
    final engine = FakeAudioEngine();
    final c = harness(engine, _FakeDrm(null));
    addTearDown(c.dispose);

    c.read(playerControllerProvider.notifier).play(_goPlus());
    await pumpEventQueue();

    expect(engine.lastLoadedUrl, isNull);
    expect(c.read(playerControllerProvider).unplayable?.title, 'G');
  });

  test('plaintext-кандидаты исчерпаны — фолбэк в DRM', () async {
    final engine = FakeAudioEngine();
    final drm = _FakeDrm('file:///tmp/x.mp3');
    // Мок-апи: резолв кандидата мгновенно даёт null («протух») — очередь на
    // DRM-фолбэк детерминирована, без живых сетевых await'ов.
    final c = harness(engine, drm, mockApi: true);
    addTearDown(c.dispose);

    final t = Track(
      id: 'p1',
      title: 'P',
      artist: 'A',
      durationMs: 1000,
      likes: 0,
      reposts: 0,
      plays: 0,
      waveform: const <double>[],
      streamCandidates: const ['https://x/hls'],
      drmStreamCandidates: const ['https://x/ctr'],
    );
    c.read(playerControllerProvider.notifier).play(t);
    await pumpEventQueue();

    expect(drm.prepared?.id, 'p1');
    expect(engine.lastLoadedUrl, 'file:///tmp/x.mp3');
    expect(c.read(playerControllerProvider).unplayable, isNull);
  });
}
