// Manual widget rendering. Public Google Fonts may load; no model/SC requests.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:waveform_app/app/theme/app_theme.dart';
import 'package:waveform_app/core/api/liked_tracks.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/api/soundcloud_auth.dart';
import 'package:waveform_app/core/audio/audio_engine.dart';
import 'package:waveform_app/core/log/talker.dart';
import 'package:waveform_app/core/recommendations/providers.dart';
import 'package:waveform_app/core/recommendations/ai_config.dart';
import 'package:waveform_app/features/recommendations/ai_settings_section.dart';
import 'package:waveform_app/features/recommendations/recommendations_screen.dart';

import '../support/fake_audio_engine.dart';
import '../support/stub_liked_tracks.dart';
import 'ui_test_support.dart';
import 'support.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => '/tmp/waveform-wave-ui/fonts',
  );
  final previousHttp = HttpOverrides.current;
  // Only this manual screenshot runner allows the theme's public font fetches.
  // All application data providers below remain offline test doubles.
  HttpOverrides.global = null;
  tearDownAll(() => HttpOverrides.global = previousHttp);
  const phase = 'after';
  for (final settings in [false, true]) {
    testWidgets('$phase ${settings ? 'settings' : 'screen'} snapshot', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(960, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final theme = await tester.runAsync(() async {
        await Directory('/tmp/waveform-wave-ui/fonts').create(recursive: true);
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
        final value = AppTheme.dark;
        for (final weight in [
          FontWeight.w400,
          FontWeight.w500,
          FontWeight.w600,
          FontWeight.w700,
        ]) {
          GoogleFonts.inter(fontWeight: weight);
          GoogleFonts.jetBrainsMono(fontWeight: weight);
        }
        await GoogleFonts.pendingFonts();
        return value;
      });
      final engine = FakeAudioEngine();
      final container = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWithBuild(
            (ref, notifier) => const SoundcloudAuth(clientId: 'test'),
          ),
          aiSettingsProvider.overrideWith(
            () => WaveTestSettings(
              initial: const AiSettingsState(
                ready: true,
                chatGptConnected: true,
                chatGptAccountLabel: 'listener@example.test',
                config: AiConfig(backend: AiBackend.chatGpt),
              ),
            ),
          ),
          aiClientProvider.overrideWithValue(ScriptedAi()),
          soundcloudApiProvider.overrideWithValue(TestSoundcloud()),
          audioEngineProvider.overrideWithValue(engine),
          likedTracksProvider.overrideWith(StubLikedTracks.new),
          talkerProvider.overrideWithValue(Talker()),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(engine.dispose);
      container.listen(aiSettingsProvider, (_, _) {});
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: theme, home: const SizedBox.shrink()),
        ),
      );
      await tester.pump();
      final key = GlobalKey();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: theme,
            home: RepaintBoundary(
              key: key,
              child: Scaffold(
                body: settings
                    ? const SingleChildScrollView(
                        padding: EdgeInsets.all(28),
                        child: Center(
                          child: SizedBox(
                            width: 640,
                            child: AiSettingsSection(),
                          ),
                        ),
                      )
                    : const RecommendationsScreen(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() => GoogleFonts.pendingFonts());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final rendered = await boundary.toImage();
        final bytes = await rendered.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory('/tmp/waveform-wave-ui');
        await directory.create(recursive: true);
        final path =
            '${directory.path}/$phase-${settings ? 'settings' : 'screen'}-960x640.png';
        await File(path).writeAsBytes(bytes!.buffer.asUint8List());
        rendered.dispose();
      });
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
