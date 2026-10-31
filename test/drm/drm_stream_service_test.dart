import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/api/client_id_resolver.dart';
import 'package:waveform_app/core/drm/drm_stream_service.dart';
import 'package:waveform_app/core/drm/scdrm_core.dart';
import 'package:waveform_app/shared/models/track.dart';

Track _track({List<String> drm = const ['https://x/ctr-160']}) => Track(
  id: '1',
  title: 'T',
  artist: 'A',
  durationMs: 1000,
  likes: 0,
  reposts: 0,
  plays: 0,
  waveform: const <double>[],
  drmStreamCandidates: drm,
);

void main() {
  group('ScDrmCore', () {
    test('dylib из дерева сборки отвечает version/license (или skip)', () {
      final core = ScDrmCore.tryLoad();
      if (core == null) {
        // Dylib не собран (публичная сборка) — не фаил, а отсутствие
        // нативной части в этой среде (CI без Go и т.п.).
        return;
      }
      expect(core.version, startsWith('scdrm'));
      expect(core.licenseUrl, contains('widevine'));
    });

    test('decrypt на пустых путях возвращает ошибку ядра, не падает', () {
      final core = ScDrmCore.tryLoad();
      if (core == null) return;
      final err = core.decrypt(
        transcodingUrl: 'https://x/ctr',
        clientId: 'cid',
        wvdPath: '/nonexistent/device.wvd',
        outPath: '/tmp/scdrm_test_out.mp3',
      );
      expect(err, isNotNull);
      expect(err, contains('wvd'));
    });
  });

  group('embedded profile', () {
    test('hasEmbeddedProfile не падает; пустой путь без профиля — ошибка', () {
      final core = ScDrmCore.tryLoad();
      if (core == null) return;
      final err = core.decrypt(
        transcodingUrl: 'https://x/ctr',
        clientId: 'cid',
        wvdPath: '',
        outPath: '/tmp/scdrm_test_out.mp3',
      );
      if (!core.hasEmbeddedProfile) {
        expect(err, contains('no embedded profile'));
      }
    });
  });

  group('DrmStreamService', () {
    test('ядро нет (null) — DRM выключен, prepare = null', () async {
      final svc = DrmStreamService(ids: ClientIdResolver(Dio()), core: null);
      expect(await svc.prepare(_track()), isNull);
    });

    test('не-DRM трек (пустые кандидаты) — null даже с ядром', () async {
      final svc = DrmStreamService(
        ids: ClientIdResolver(Dio()),
        core: ScDrmCore.tryLoad(),
      );
      expect(await svc.prepare(_track(drm: const [])), isNull);
    });
  });
}
