import 'dart:async';
import 'dart:convert' show Utf8Encoder;
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart' show sha1;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:talker_flutter/talker_flutter.dart';

import '../../shared/models/track.dart';
import '../api/client_id_resolver.dart';
import '../api/providers.dart';
import '../log/talker.dart';
import 'scdrm_core.dart';

/// Go-ядро дешифровки GO+; null — dylib не собран/не найден (тогда DRM
/// просто выключен, приложение живёт как раньше).
final scDrmCoreProvider = Provider<ScDrmCore?>((ref) => ScDrmCore.tryLoad());

/// Сервис дешифровки Widevine-треков SoundCloud GO+ (`ctr-encrypted-hls`).
///
/// Путь: транскодинг → api-v2 резолв (плейлист + licenseAuthToken) →
/// Go-ядро scdrm тянет сегменты, берёт Widevine-лицензию (wvd-профиль
/// устройства из ассета) и пишет дешифрованный файл в кэш каталога
/// Application Support → плеер играет локальный файл как обычный трек.
class DrmStreamService {
  DrmStreamService({required this.ids, this.core, this.log});

  final ClientIdResolver ids;
  final ScDrmCore? core;
  final Talker? log;

  /// Кэшированный результат = файл в [cacheSubdir]; держим последние
  /// [_keepFiles] треков, остальное подчищаем.
  static const String cacheSubdir = 'scdrm';
  static const int _keepFiles = 20;

  final Map<String, Future<String?>> _inFlight = {};
  Future<String?>? _wvdPath;

  /// Готовит локальный источник для DRM-трека: `file://…/track.mp3` (или
  /// `.m4a`). null — DRM недоступен (нет ядра/wvd/лицензии) или дешифровка
  /// не удалась ни для одного кандидата. Повторные вызовы для одного трека
  /// не дублируют работу.
  Future<String?> prepare(Track track) {
    final core = this.core;
    if (core == null || track.drmStreamCandidates.isEmpty) {
      return Future.value(null);
    }
    final key = '${track.id}|${track.drmStreamCandidates.first}';
    return _inFlight.putIfAbsent(key, () async {
      try {
        return await _prepare(track, core);
      } finally {
        _inFlight.remove(key);
      }
    });
  }

  Future<String?> _prepare(Track track, ScDrmCore core) async {
    try {
      final wvd = await _ensureWvd();
      if (wvd == null) {
        log?.warning(
          'scdrm: нет ассета assets/widevine/device.wvd — GO+ выключен',
        );
        return null;
      }
      final dir = await _cacheDir();
      final clientId = await ids.get();

      for (final candidate in track.drmStreamCandidates) {
        final base = '${track.id}-${_hash(candidate)}';
        // Уже декодировано ранее — переиспользуем (переустановка приложения
        // не чистит Application Support).
        for (final ext in const ['mp3', 'm4a']) {
          final cached = File('${dir.path}/$base.$ext');
          if (cached.existsSync() && cached.lengthSync() > 0) {
            return cached.uri.toString();
          }
        }
        final tmp = '${dir.path}/$base.part';
        // Декодируем в isolate: Go-ядро блокирует поток до конца (сеть +
        // транскод всего трека), гонять его по UI- isolate нельзя.
        final err = await Isolate.run(() {
          final core = ScDrmCore.tryLoad();
          if (core == null) return 'scdrm: ядро не загрузилось в isolate';
          return core.decrypt(
            transcodingUrl: candidate,
            clientId: clientId,
            wvdPath: wvd,
            outPath: tmp,
            licenseUrl: null,
          );
        });
        final tmpFile = File(tmp);
        if (err == null && tmpFile.existsSync() && tmpFile.lengthSync() > 0) {
          final ext = await _isMp4(tmpFile) ? 'm4a' : 'mp3';
          final out = File('${dir.path}/$base.$ext');
          await tmpFile.rename(out.path);
          unawaited(_evict(dir));
          log?.info('scdrm: ${track.title} → ${out.path}');
          return out.uri.toString();
        }
        try {
          tmpFile.deleteSync();
        } catch (_) {}
        log?.warning('scdrm: ${track.title} — ${err ?? 'пустой результат'}');
      }
    } catch (e) {
      log?.warning('scdrm: ${track.title} — $e');
    }
    return null;
  }

  /// Путь к wvd: выгружаем ассет в Application Support один раз (ядро читает
  /// с диска). null — ассета нет (устройство Widevine ещё не добавлено).
  Future<String?> _ensureWvd() => _wvdPath ??= () async {
    try {
      final support = await getApplicationSupportDirectory();
      final f = File('${support.path}/device.wvd');
      if (f.existsSync() && f.lengthSync() > 0) return f.path;
      final data = await rootBundle.load('assets/widevine/device.wvd');
      await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
      return f.path;
    } catch (_) {
      return null;
    }
  }();

  Future<Directory> _cacheDir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/$cacheSubdir');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// MP4-контейнер (fMP4, если транскод в MP3 не удался ядру): magic `ftyp`
  /// в байтах 4..8. Иначе — MP3 (ID3/синхро-фрейм).
  Future<bool> _isMp4(File f) async {
    try {
      final bytes = await f.openRead(4, 8).first;
      return bytes.length == 4 &&
          bytes[0] == 0x66 && // f
          bytes[1] == 0x74 && // t
          bytes[2] == 0x79 && // y
          bytes[3] == 0x70; // p
    } catch (_) {
      return false;
    }
  }

  Future<void> _evict(Directory dir) async {
    try {
      final files =
          dir
              .listSync()
              .whereType<File>()
              .where((f) => !f.path.endsWith('.part'))
              .toList()
            ..sort(
              (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
            );
      for (final f in files.skip(_keepFiles)) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }

  static String _hash(String s) {
    // Стабильный между запусками/SDK sha1 — кэш переживает апдейты приложения.
    final digest = sha1.convert(const Utf8Encoder().convert(s));
    return digest.toString().substring(0, 16);
  }
}

final drmStreamServiceProvider = Provider<DrmStreamService>(
  (ref) => DrmStreamService(
    ids: ref.watch(clientIdResolverProvider),
    core: ref.watch(scDrmCoreProvider),
    log: ref.watch(talkerProvider),
  ),
);
