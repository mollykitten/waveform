import 'package:desktop_webview_window/desktop_webview_window.dart';

/// Узкая абстракция над webview, через которую работает [WebviewApiExecutor].
/// Реальная реализация оборачивает плагин; в тестах подменяется фейком.
abstract class JsRunner {
  Future<void> launch(String url);

  /// Выполнить JS; вернуть значение выражения (или null). Для инъекции fetch
  /// возвращаемое значение не важно; для poll — читаем глобалку результата.
  Future<String?> eval(String javaScript);

  Future<void> close();
}

/// Адаптер поверх плагина desktop_webview_window.
class WebviewJsRunner implements JsRunner {
  WebviewJsRunner(this._wv);
  final Webview _wv;

  @override
  Future<void> launch(String url) async =>
      _wv.launch(url, triggerOnUrlRequestEvent: false);

  @override
  Future<String?> eval(String javaScript) => _wv.evaluateJavaScript(javaScript);

  @override
  Future<void> close() async => _wv.close();
}
