import 'dart:io';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:waveform_app/app/theme/app_theme.dart';

const _fontFiles = {
  'Inter-Regular': 'Inter-Regular.ttf',
  'Inter-Medium': 'Inter-Medium.ttf',
  'Inter-SemiBold': 'Inter-SemiBold.ttf',
  'Inter-Bold': 'Inter-Bold.ttf',
  'JetBrainsMono-Regular': 'JetBrainsMono-Regular.ttf',
  'JetBrainsMono-Medium': 'JetBrainsMono-Medium.ttf',
  'JetBrainsMono-SemiBold': 'JetBrainsMono-SemiBold.ttf',
  'JetBrainsMono-Bold': 'JetBrainsMono-Bold.ttf',
};

/// Shared real-font fixtures; capture tests skip when these are unavailable.
bool get visualTestFontsAvailable => _fontFiles.values.every(
  (font) => File('build/visual-review/fonts/$font').existsSync(),
);

/// Explicit local opt-in; ordinary test runs never produce visual evidence.
/// Create this ignored marker to regenerate the six wave/consent captures.
bool get waveVisualCaptureEnabled =>
    visualTestFontsAvailable &&
    File('build/visual-review/.capture-wave').existsSync();

/// Load actual capture fonts through AppTheme's normal GoogleFonts asset path.
/// GoogleFonts resolves these assets to Inter_regular / JetBrainsMono_regular
/// and registers those exact families with FontLoader, just as in production.
/// Ordinary behavioral tests always use SDK Roboto; no network is permitted.
Future<void> installVisualTestFonts() async {
  GoogleFonts.config.allowRuntimeFetching = false;
  final config =
      jsonDecode(await File('.dart_tool/package_config.json').readAsString())
          as Map<String, dynamic>;
  final flutterRoot = Uri.parse(config['flutterRoot'] as String);
  final bytes = await File.fromUri(
    Uri.parse(
      '$flutterRoot/',
    ).resolve('bin/cache/artifacts/material_fonts/Roboto-Regular.ttf'),
  ).readAsBytes();
  final icons = await File.fromUri(
    Uri.parse(
      '$flutterRoot/',
    ).resolve('bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf'),
  ).readAsBytes();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(Future.value(ByteData.sublistView(icons)))).load();
  final fontBytes = waveVisualCaptureEnabled
      ? <String, ByteData>{
          for (final font in _fontFiles.entries)
            'fonts/${font.key}.ttf': ByteData.sublistView(
              await File(
                'build/visual-review/fonts/${font.value}',
              ).readAsBytes(),
            ),
        }
      : <String, ByteData>{
          for (final family in ['Inter', 'JetBrainsMono'])
            for (final variant in [
              'Thin',
              'ExtraLight',
              'Light',
              'Regular',
              'Medium',
              'SemiBold',
              'Bold',
              'ExtraBold',
              'Black',
            ])
              'fonts/$family-$variant.ttf': ByteData.sublistView(bytes),
        };
  final assets = <String, Object>{
    for (final path in fontBytes.keys)
      path: [
        {'asset': path},
      ],
  };
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler('flutter/assets', (message) async {
        final key = const StringCodec().decodeMessage(message);
        if (key == 'AssetManifest.bin') {
          return const StandardMessageCodec().encodeMessage(assets);
        }
        if (fontBytes.containsKey(key)) return fontBytes[key];
        return null;
      });
  AppTheme.dark;
  AppTheme.mono();
  await GoogleFonts.pendingFonts();
}
