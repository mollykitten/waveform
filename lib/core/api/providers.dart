import 'dart:io' show Platform;

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talker_dio_logger/talker_dio_logger.dart';

import '../log/talker.dart';
import 'client_id_resolver.dart';
import 'http_soundcloud_api.dart';
import 'js_runner.dart';
import 'mock_soundcloud_api.dart';
import 'soundcloud_api.dart';
import 'soundcloud_auth.dart';
import 'webview_executor.dart';

final _dioProvider = Provider<Dio>((ref) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ),
  );
  // Логируем все запросы/ответы/ошибки api-v2. Заголовки НЕ печатаем —
  // чтобы не светить OAuth-токен в логах.
  dio.interceptors.add(
    TalkerDioLogger(
      talker: ref.watch(talkerProvider),
      settings: const TalkerDioLoggerSettings(
        // Тела ответов api-v2 огромны (списки треков) — НЕ логируем их целиком,
        // иначе история раздувается до мегабайт. Достаточно строки запроса +
        // статуса; для ошибок оставляем тело (оно короткое и полезно).
        printRequestHeaders: false,
        printResponseHeaders: false,
        printRequestData: false,
        printResponseData: false,
        printResponseMessage: false,
        printErrorData: true,
        printErrorMessage: true,
      ),
    ),
  );
  return dio;
});

final clientIdResolverProvider = Provider<ClientIdResolver>(
  (ref) => ClientIdResolver(ref.read(_dioProvider)),
);

/// Webview-executor для write-запросов (обход DataDome-403). Существует только
/// когда пользователь залогинен и платформа десктопная; при MOCK — null.
/// Пересоздаётся при смене auth-состояния → свежая webview-сессия на аккаунт.
final webviewApiExecutorProvider = Provider<WebviewApiExecutor?>((ref) {
  const mock = bool.fromEnvironment('MOCK');
  final authed = ref.watch(
    authControllerProvider.select((a) => a.isAuthenticated),
  );
  final supported = Platform.isMacOS || Platform.isLinux || Platform.isWindows;
  if (mock || !authed || !supported) return null;

  final ids = ref.watch(clientIdResolverProvider);
  final ex = WebviewApiExecutor(
    createRunner: () async {
      // hidden:true → окно создаётся невидимым (macOS-патч вендоренного
      // плагина: прозрачное on-screen окно). На macOS флага достаточно.
      // Windows: натив-часть флаг не читает, но реализует
      // setWebviewWindowVisibility — прячем им. Linux: этого метода НЕТ (вызов
      // бросит, перехватываем) → окно там пока остаётся видимым (Linux и так
      // деградирован, см. бэклог). На macOS метод не реализован — туда не зовём.
      final wv = await WebviewWindow.create(
        configuration: const CreateConfiguration(
          title: 'Waveform sync',
          windowWidth: 480,
          windowHeight: 360,
          hidden: true,
        ),
      );
      if (!Platform.isMacOS) {
        try {
          await wv.setWebviewWindowVisibility(false);
        } catch (_) {}
      }
      return WebviewJsRunner(wv);
    },
    tokenGetter: () async => ref.read(authControllerProvider).userToken,
    clientIdGetter: () => ids.get(),
    log: ref.watch(talkerProvider),
  );
  ref.onDispose(ex.dispose);
  // Фоновый прогрев, чтобы первый лайк не ждал загрузки soundcloud.com.
  ex.prewarm();
  return ex;
});

/// Единая точка доступа к API. По умолчанию — живой api-v2 (client_id + OAuth):
/// приложение показывает реальные данные SoundCloud, без моков.
/// Сборка с `--dart-define=MOCK=true` поднимает моки (offline-разработка);
/// тесты переопределяют провайдер напрямую через [MockSoundcloudApi].
final soundcloudApiProvider = Provider<SoundcloudApi>((ref) {
  const mock = bool.fromEnvironment('MOCK');
  if (mock) return const MockSoundcloudApi();
  return HttpSoundcloudApi(
    ref.watch(_dioProvider),
    ref.watch(clientIdResolverProvider),
    auth: ref.watch(authControllerProvider),
    executor: ref.watch(webviewApiExecutorProvider),
    talker: ref.watch(talkerProvider),
  );
});
