import 'dart:io';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

const _fontFiles = [
  'Inter-Regular',
  'JetBrainsMono-Regular',
  'JetBrainsMono-SemiBold',
];

/// Capture fixtures are copied from GoogleFonts' local runtime cache into this
/// ignored folder. Capture tests skip when the real fonts are unavailable.
bool get visualTestFontsAvailable => _fontFiles.every(
  (font) => File('build/visual-review/fonts/$font.ttf').existsSync(),
);

/// Load actual capture fonts through AppTheme's normal GoogleFonts asset path.
/// Ordinary behavioral tests use SDK Roboto if fixtures are absent; no network.
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
  final fontBytes = visualTestFontsAvailable
      ? <String, ByteData>{
          for (final font in _fontFiles)
            'fonts/$font.ttf': ByteData.sublistView(
              await File('build/visual-review/fonts/$font.ttf').readAsBytes(),
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
}
