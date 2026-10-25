import 'dart:async';

import 'package:desktop_webview_window/desktop_webview_window.dart';

/// Вход через настоящую страницу логина SoundCloud в embedded WebView.
/// Пароль вводится на сайте SC — мы его не видим; после входа вытаскиваем
/// `oauth_token` из cookie сессии (poll).
///
/// Ключевой момент: SoundCloud ставит `oauth_token` ещё ДО логина (гостевой),
/// поэтому каждый кандидат проверяется через [validate] (запрос `/me`). Окно
/// закрываем только когда токен реально опознан как пользовательский.
abstract final class WebviewLogin {
  static Future<bool> available() => WebviewWindow.isWebviewAvailable();

  /// Открывает soundcloud.com в webview, чтобы пользователь прошёл проверку
  /// (капча/анти-абуз — часто всплывает под VPN при действиях вроде лайка).
  /// Завершается при закрытии окна. Best-effort: токеновые запросы api-v2 не
  /// делят cookie-jar webview, но проверка может снять блокировку аккаунта.
  static Future<void> openVerification() async {
    if (!await available()) return;
    final webview = await WebviewWindow.create(
      configuration: const CreateConfiguration(
        title: 'Verify on SoundCloud',
        windowWidth: 980,
        windowHeight: 760,
      ),
    );
    webview.launch('https://soundcloud.com', triggerOnUrlRequestEvent: false);
    await webview.onClose;
  }

  static Future<String?> signIn({
    required Future<bool> Function(String token) validate,
  }) async {
    final webview = await WebviewWindow.create(
      configuration: const CreateConfiguration(
        title: 'Sign in to SoundCloud',
        windowWidth: 980,
        windowHeight: 760,
      ),
    );

    final completer = Completer<String?>();
    Timer? poll;
    String? lastChecked; // не валидируем один и тот же токен повторно

    Future<void> capture() async {
      if (completer.isCompleted) return;
      try {
        final cookies = await webview.getAllCookies();
        final raw = cookies
            .where(
              (c) =>
                  c.name == 'oauth_token' &&
                  c.value.isNotEmpty &&
                  c.domain.contains('soundcloud'),
            )
            .map((c) => c.value)
            .firstOrNull;
        if (raw == null) return;

        // Cookie иногда percent-encoded — раскодируем, но без падения.
        String token = raw;
        if (raw.contains('%')) {
          try {
            token = Uri.decodeComponent(raw);
          } catch (_) {}
        }
        if (token == lastChecked) return;
        lastChecked = token;

        // Гостевой/просроченный токен не пройдёт /me — ждём настоящего входа.
        if (!await validate(token)) return;
        if (completer.isCompleted) return;
        completer.complete(token);
        poll?.cancel();
        webview.close();
      } catch (_) {
        // окно могло закрыться между проверками — игнорируем
      }
    }

    // Токен ловим только поллингом cookie. Раньше тут ещё висел
    // setOnUrlRequestCallback — на Windows он заставляет плагин отменять
    // каждую навигацию и перезапускать её после round-trip'а в Dart
    // (лаги + POST-формы уходили как GET). Навигации больше не перехватываем.
    poll = Timer.periodic(const Duration(seconds: 1), (_) => capture());
    webview.onClose.then((_) {
      poll?.cancel();
      if (!completer.isCompleted) completer.complete(null);
    });

    webview.launch(
      'https://soundcloud.com/signin',
      triggerOnUrlRequestEvent: false,
    );
    return completer.future;
  }
}
