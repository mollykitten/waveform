import 'dart:io';
import 'dart:ui' as ui;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:waveform_app/app/theme/app_theme.dart';
import 'package:waveform_app/core/recommendations/ai_config.dart';
import 'package:waveform_app/core/recommendations/chatgpt_auth.dart';
import 'package:waveform_app/core/recommendations/providers.dart';
import 'package:waveform_app/core/recommendations/models.dart';
import 'visual_test_fonts.dart';
import 'package:waveform_app/features/settings/settings_screen.dart';
import 'package:waveform_app/core/api/mock_soundcloud_api.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/api/soundcloud_auth.dart';
import 'package:waveform_app/core/deeplinks/clipboard_watcher.dart';
import 'package:waveform_app/core/audio/playback_prefs.dart';
import 'package:waveform_app/core/lastfm/lastfm_session.dart';
import 'package:waveform_app/shared/view_mode.dart';
import 'package:waveform_app/features/recommendations/ai_settings_section.dart';
import 'package:waveform_app/shared/widgets/pressable.dart';
import 'package:waveform_app/shared/widgets/form_controls.dart';

class _NoChatGpt extends ChatGptAuth {
  @override
  Future<void> restore() async {}
}

class _Store extends AiConfigStore {
  Completer<void>? pending;
  AiConfig config = const AiConfig(
    endpoint: 'http://localhost:11434',
    model: 'local-model',
  );

  @override
  Future<AiConfig> load() async => config;

  @override
  Future<void> save(AiConfig value) async {
    await pending?.future;
    config = value;
  }
}

// Opt in with build/visual-review/.capture-controls; no permanent goldens.
final _captureEnabled = File(
  'build/visual-review/.capture-controls',
).existsSync();

void main() {
  for (final size in [const Size(1280, 800), const Size(960, 640)]) {
    for (final scale in [1.0, 1.5]) {
      for (final state in [
        const AiSettingsState(ready: true),
        const AiSettingsState(ready: true, connecting: true),
        const AiSettingsState(
          ready: true,
          chatGptConnected: true,
          chatGptAccountLabel: 'a.long.account.address.for.layout@example.com',
        ),
        const AiSettingsState(ready: true, error: AiFailure.credentials),
      ]) {
        final status = state.connecting
            ? 'connecting'
            : state.error != null
            ? 'error'
            : state.chatGptConnected
            ? 'connected'
            : 'disconnected';
        testWidgets('settings ${size.width} scale $scale $status', (
          tester,
        ) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          const capture = ValueKey('settings-capture');
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                aiSettingsProvider.overrideWithBuild((ref, notifier) => state),
              ],
              child: MaterialApp(
                theme: AppTheme.dark,
                debugShowCheckedModeBanner: false,
                home: MediaQuery(
                  data: MediaQueryData(
                    size: size,
                    textScaler: TextScaler.linear(scale),
                    disableAnimations: true,
                  ),
                  child: Scaffold(
                    body: RepaintBoundary(
                      key: capture,
                      child: Center(
                        child: SizedBox(
                          width: 640,
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(AppTheme.pagePad),
                            child: const AiSettingsSection(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
          if (state.chatGptConnected) {
            final identity = tester.getRect(
              find.text(state.chatGptAccountLabel!),
            );
            final ready = tester.getRect(find.text('ready for your next wave'));
            final disconnect = tester.getRect(
              find.ancestor(
                of: find.text('disconnect ChatGPT'),
                matching: find.byType(FormAction),
              ),
            );
            expect(
              identity.top,
              greaterThan(tester.getRect(find.text('ChatGPT')).bottom),
            );
            expect(ready.top, greaterThan(identity.bottom));
            if (disconnect.top < ready.bottom) {
              expect(disconnect.left, greaterThan(identity.right));
            } else {
              expect(disconnect.top, greaterThanOrEqualTo(ready.bottom + 8));
            }
            expect(
              find.descendant(
                of: find.byKey(const ValueKey('wave-connection-card')),
                matching: find.byType(Divider),
              ),
              findsOneWidget,
            );
          }

          if (_captureEnabled && scale == 1 && status == 'connected') {
            await _capture(
              tester,
              capture,
              'after-settings-disconnect-icon-${size.width.toInt()}.png',
            );
          }
          if (_captureEnabled && scale == 1 && status == 'disconnected') {
            await _capture(
              tester,
              capture,
              'after-settings-collapsed-${size.width.toInt()}.png',
            );
          }
          await tester.tap(find.text('advanced settings'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.ensureVisible(find.byKey(const ValueKey('ai-endpoint')));
          await tester.pump();
          final field = tester.getRect(
            find.byKey(const ValueKey('ai-endpoint')),
          );
          final label = tester.getRect(find.text('endpoint base URL'));
          expect(label.bottom, lessThanOrEqualTo(field.top));
          expect(field.height, greaterThanOrEqualTo(40));
          final accountAction = find.ancestor(
            of: find.text('use another ChatGPT account'),
            matching: find.byType(FormAction),
          );
          final accountIcon = find.descendant(
            of: accountAction,
            matching: find.byType(Icon),
          );
          final iconRect = tester.getRect(accountIcon);
          expect(
            iconRect.left,
            closeTo(field.left, .01),
            reason:
                'inline account action starts at the same edge as the form fields',
          );
          expect(
            tester.getRect(find.text('use another ChatGPT account')).left -
                iconRect.right,
            closeTo(8, .01),
          );
          expect(
            tester.getSize(accountAction).height,
            greaterThanOrEqualTo(36),
          );

          expect(tester.takeException(), isNull);
          if (_captureEnabled && scale == 1 && status == 'disconnected') {
            await _capture(
              tester,
              capture,
              'after-settings-expanded-${size.width.toInt()}.png',
            );
          }
          if (_captureEnabled && scale == 1 && status == 'connected') {
            await _capture(
              tester,
              capture,
              'after-settings-account-icons-${size.width.toInt()}.png',
            );
          }
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  }

  testWidgets(
    'full Settings ordinary sections wrap at 960 and text scale 1.5',
    (tester) async {
      tester.view.physicalSize = const Size(960, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            aiSettingsProvider.overrideWithBuild(
              (ref, notifier) => const AiSettingsState(ready: true),
            ),
            authControllerProvider.overrideWithBuild(
              (ref, notifier) => const SoundcloudAuth(clientId: 'test'),
            ),
            soundcloudApiProvider.overrideWithValue(MockSoundcloudApi()),
            clipboardWatchEnabledProvider.overrideWithBuild(
              (ref, notifier) => true,
            ),
            playbackPrefsProvider.overrideWithBuild(
              (ref, notifier) => const PlaybackPrefs(),
            ),
            lastfmSessionProvider.overrideWithBuild((ref, notifier) => null),
            viewModeProvider.overrideWithBuild(
              (ref, notifier) => ViewMode.tiles,
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.dark,
            home: const MediaQuery(
              data: MediaQueryData(
                size: Size(960, 640),
                textScaler: TextScaler.linear(1.5),
                disableAnimations: true,
              ),
              child: Scaffold(body: SettingsScreen()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final text in [
        'open SoundCloud links from clipboard',
        'Last.fm scrobbling is not configured.',
        'clear downloaded cover art',
        'source code',
      ]) {
        final target = find.textContaining(text, findRichText: true);
        await tester.scrollUntilVisible(target, 300);
        await tester.pump();
        expect(target.hitTestable(), findsOneWidget);
        final rect = tester.getRect(target);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(960));
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  setUpAll(installVisualTestFonts);

  testWidgets(
    'compact configuration keeps editing and protocol locked on save',
    (tester) async {
      final store = _Store();
      final container = ProviderContainer(
        overrides: [
          aiConfigStoreProvider.overrideWithValue(store),
          chatGptAuthProvider.overrideWithValue(_NoChatGpt()),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.dark,
            debugShowCheckedModeBanner: false,
            home: const Scaffold(
              body: SingleChildScrollView(child: AiSettingsSection()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('advanced settings'));
      await tester.pumpAndSettle();
      expect(find.byType(DropdownButtonFormField<AiBackend>), findsNothing);
      for (final field in tester.widgetList<TextField>(
        find.byType(TextField),
      )) {
        expect(field.decoration!.enabledBorder, isA<OutlineInputBorder>());
        expect(field.decoration!.counterText, '');
      }
      await tester.tap(find.text('Ollama (native)'));
      await tester.enterText(
        find.byKey(const ValueKey<String>('ai-session-key')),
        'session-test-key',
      );
      store.pending = Completer<void>();
      await tester.ensureVisible(find.text('save custom provider'));
      await tester.tap(find.text('save custom provider'));
      await tester.pump();
      expect(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .every((field) => field.enabled == false),
        isTrue,
      );
      expect(
        tester
            .widgetList<Pressable>(find.byType(Pressable))
            .where((button) => button.enabled)
            .length,
        0,
        reason: 'all custom-provider controls remain locked while saving',
      );
      store.pending!.complete();
      await tester.pumpAndSettle();
      expect(store.config.backend, AiBackend.ollama);
      expect(container.read(aiSettingsProvider).hasSessionKey, isTrue);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey<String>('ai-session-key')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _capture(WidgetTester tester, Key key, String filename) async {
  await tester.runAsync(() => GoogleFonts.pendingFonts());
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('build/visual-review');
    await directory.create(recursive: true);
    await File(
      '${directory.path}/$filename',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
