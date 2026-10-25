import 'dart:io';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Use the SDK's local Roboto in widget captures; no font network requests.
/// Production still uses Inter and JetBrains Mono through AppTheme.
Future<void> installVisualTestFonts() async {
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
  final assets = <String, Object>{
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
        'fonts/$family-$variant.ttf': [
          {'asset': 'fonts/$family-$variant.ttf'},
        ],
  };
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler('flutter/assets', (message) async {
        final key = const StringCodec().decodeMessage(message);
        if (key == 'AssetManifest.bin') {
          return const StandardMessageCodec().encodeMessage(assets);
        }
        if (assets.containsKey(key)) return ByteData.sublistView(bytes);
        return null;
      });
}
