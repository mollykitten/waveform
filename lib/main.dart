import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:talker_riverpod_logger/talker_riverpod_logger.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';
import 'core/audio/waveform_audio_handler.dart';
import 'core/log/talker.dart';
import 'core/update/update_controller.dart';
import 'features/onboarding/onboarding_gate.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // WebView titlebars run this entrypoint in a secondary Flutter engine
  // without the primary window/audio plugins. Do not bootstrap the app there.
  if (runWebViewTitleBarWidget(args)) return;

  // Window manager — для динамического title и базового sizing на desktop.
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    await windowManager.ensureInitialized();
    const opts = WindowOptions(
      title: 'Waveform',
      minimumSize: Size(960, 640),
      titleBarStyle: TitleBarStyle.hidden,
    );
    // waitUntilReadyToShow гарантирует, что окно создано до setTitle.
    await windowManager.waitUntilReadyToShow(opts, () async {
      await windowManager.setTitle('Waveform');
      await windowManager.show();
      await windowManager.focus();
    });
  }

  // Единый Talker: им же логируются Dio-запросы и Riverpod-события.
  final talker = TalkerFlutter.init(
    settings: TalkerSettings(maxHistoryItems: 1000),
  );

  // 1) Поднимаем audio_service. Handler создаётся ДО ProviderContainer'а —
  //    у него ещё нет ссылки на container; назначим её ниже. Методы handler'а
  //    (play/pause/...) дёргаются только когда пользователь жмёт media-keys —
  //    к тому моменту container уже привязан.
  final handler = await AudioService.init(
    builder: () => WaveformAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.waveform.player',
      androidNotificationChannelName: 'Waveform',
      androidNotificationOngoing: true,
    ),
  );
  setAudioHandlerSingleton(handler);

  // 2) Создаём ProviderContainer с overrides — отсюда же его поднимет
  //    UncontrolledProviderScope.
  final container = ProviderContainer(
    observers: [
      TalkerRiverpodObserver(
        talker: talker,
        settings: const TalkerRiverpodLoggerSettings(
          printProviderAdded: true,
          printProviderUpdated: false, // плеер тикает позицией — был бы флуд
          printProviderDisposed: false,
          printProviderFailed: true,
        ),
      ),
    ],
    overrides: [talkerProvider.overrideWithValue(talker)],
  );
  handler.container = container;

  // Флаг онбординга читаем до первого кадра, чтобы роутер сразу знал стартовый
  // экран (первый запуск → /welcome).
  await onboardingGate.restore();

  runApp(
    UncontrolledProviderScope(container: container, child: const WaveformApp()),
  );

  // Раз в сутки, не дожидаясь онбординга и AppShell; в тестах и под MOCK —
  // no-op.
  unawaited(container.read(updateControllerProvider.notifier).autoCheck());
}
