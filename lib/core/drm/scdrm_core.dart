import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';

/// C-экспорты DRM-ядра (собирается отдельно, в публичном репо его нет):
/// `scdrm_version`, `scdrm_license_url`, `scdrm_decrypt`, `scdrm_free`.
///
/// Ядро резолвит Widevine-поток (`ctr-encrypted-hls`), получает лицензию,
/// дешифрует CENC и транскодит в MP3 (или оставляет fMP4, если AAC-декодер
/// не смог) — всё в один вызов, без временных сегментов на диске.
///
/// Dylib ищется: в переменной `SCDRM_DYLIB`, по `@rpath` (в бандле .app его
/// кладёт Xcode-фаза «Bundle optional libscdrm»), рядом с исполняемым файлом в
/// `Contents/Frameworks`, относительным путём сборки (для ручных прогонов).
class ScDrmCore {
  ScDrmCore._(this._lib);

  final ffi.DynamicLibrary _lib;

  ffi.Pointer<Utf8> Function() get _version =>
      _lib.lookupFunction<
        ffi.Pointer<Utf8> Function(),
        ffi.Pointer<Utf8> Function()
      >('scdrm_version');
  ffi.Pointer<Utf8> Function() get _licenseUrl =>
      _lib.lookupFunction<
        ffi.Pointer<Utf8> Function(),
        ffi.Pointer<Utf8> Function()
      >('scdrm_license_url');
  ffi.Pointer<Utf8> Function(
    ffi.Pointer<Utf8>,
    ffi.Pointer<Utf8>,
    ffi.Pointer<Utf8>,
    ffi.Pointer<Utf8>,
    ffi.Pointer<Utf8>,
  )
  get _decrypt =>
      _lib.lookupFunction<
        ffi.Pointer<Utf8> Function(
          ffi.Pointer<Utf8>,
          ffi.Pointer<Utf8>,
          ffi.Pointer<Utf8>,
          ffi.Pointer<Utf8>,
          ffi.Pointer<Utf8>,
        ),
        ffi.Pointer<Utf8> Function(
          ffi.Pointer<Utf8>,
          ffi.Pointer<Utf8>,
          ffi.Pointer<Utf8>,
          ffi.Pointer<Utf8>,
          ffi.Pointer<Utf8>,
        )
      >('scdrm_decrypt');

  void Function(ffi.Pointer<ffi.Char>) get _free =>
      _lib.lookupFunction<
        ffi.Void Function(ffi.Pointer<ffi.Char>),
        void Function(ffi.Pointer<ffi.Char>)
      >('scdrm_free');

  /// Зашит ли профиль устройства в dylib при сборке (тогда `wvdPath` в
  /// [decrypt] можно передать пустым). Старый dylib без символа → false.
  bool get hasEmbeddedProfile {
    try {
      return _lib.lookupFunction<ffi.Int Function(), int Function()>(
            'scdrm_has_embedded_profile',
          )() ==
          1;
    } catch (_) {
      return false;
    }
  }

  /// Загрузка ядра; null — dylib не найден (например, в `flutter test` или на
  /// чужой машине без сборки scdrm) → DRM-поддержка просто выключена.
  static ScDrmCore? tryLoad() {
    for (final path in _candidates()) {
      try {
        return ScDrmCore._(ffi.DynamicLibrary.open(path));
      } catch (_) {
        // следующий кандидат
      }
    }
    return null;
  }

  static List<String> _candidates() {
    final env = Platform.environment['SCDRM_DYLIB'];
    final names = ['libscdrm.dylib'];
    final out = <String>[];
    if (env != null && env.isNotEmpty) out.add(env);
    out.add('@rpath/${names.first}');
    final exe = File(Platform.resolvedExecutable).parent.parent;
    if (exe.basename == 'MacOS') {
      out.add('${exe.parent.path}/Frameworks/${names.first}');
    }
    out.add('macos/Runner/Frameworks/${names.first}');
    return out;
  }

  String get version {
    // Go отдаёт свежий C.CString на каждый вызов — освобождаем через scdrm_free.
    final p = _version();
    try {
      return p.toDartString();
    } finally {
      _free(p.cast());
    }
  }

  /// Прод-эндпоинт Widevine-лицензий SoundCloud (зашит в ядре).
  String get licenseUrl {
    final p = _licenseUrl();
    try {
      return p.toDartString();
    } finally {
      _free(p.cast());
    }
  }

  /// Полная дешифровка трека за один вызов. Возвращает null при успехе,
  /// иначе текст ошибки Go-ядра. [outPath] — куда положить результат
  /// (`.mp3` или `.m4a` — ядро само решает по успешности транскода).
  String? decrypt({
    required String transcodingUrl,
    required String clientId,
    required String wvdPath,
    required String outPath,
    String? licenseUrl,
  }) {
    final cTranscoding = transcodingUrl.toNativeUtf8();
    final cClient = clientId.toNativeUtf8();
    final cWvd = wvdPath.toNativeUtf8();
    final cOut = outPath.toNativeUtf8();
    final ffi.Pointer<Utf8> cLicense =
        licenseUrl?.toNativeUtf8() ?? ffi.nullptr;
    try {
      final err = _decrypt(cTranscoding, cClient, cWvd, cOut, cLicense);
      if (err == ffi.nullptr) return null;
      final message = err.toDartString();
      _free(err.cast());
      return message;
    } finally {
      calloc
        ..free(cTranscoding)
        ..free(cClient)
        ..free(cWvd)
        ..free(cOut);
      if (cLicense != ffi.nullptr) calloc.free(cLicense);
    }
  }
}

extension on Directory {
  String get basename => uri.pathSegments.last;
}
