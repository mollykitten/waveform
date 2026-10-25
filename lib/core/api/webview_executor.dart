import 'dart:async';
import 'dart:convert';

import 'package:talker_flutter/talker_flutter.dart';

import 'js_runner.dart';

/// Выполняет write-запросы api-v2 изнутри настоящего браузера (webview), чтобы
/// пройти DataDome (TLS/JA3 как у браузера + живая datadome-cookie). Подробности
/// — в spec 2026-06-10-account-reliability-webview-writes.
class WebviewApiExecutor {
  WebviewApiExecutor({
    required Future<JsRunner> Function() createRunner,
    required Future<String?> Function() tokenGetter,
    required Future<String> Function() clientIdGetter,
    required Talker log,
    Duration pollInterval = const Duration(milliseconds: 150),
    int maxPolls = 60,
    int warmAttempts = 12,
    Duration warmSettle = const Duration(seconds: 3),
    Duration warmRetryDelay = const Duration(milliseconds: 1500),
    String warmUrl = 'https://soundcloud.com',
  }) : _createRunner = createRunner,
       _tokenGetter = tokenGetter,
       _clientIdGetter = clientIdGetter,
       _log = log,
       _pollInterval = pollInterval,
       _maxPolls = maxPolls,
       _warmAttempts = warmAttempts,
       _warmSettle = warmSettle,
       _warmRetryDelay = warmRetryDelay,
       _warmUrl = warmUrl;

  final Future<JsRunner> Function() _createRunner;
  final Future<String?> Function() _tokenGetter;
  final Future<String> Function() _clientIdGetter;
  final Talker _log;
  final Duration _pollInterval;
  final int _maxPolls;
  final int _warmAttempts;
  final Duration _warmSettle;
  final Duration _warmRetryDelay;
  final String _warmUrl;

  static const _readExpr = 'window.__wfRes';

  JsRunner? _runner;
  bool _warm = false;
  bool _disposed = false;
  Future<void> _tail = Future<void>.value();

  /// Выполнить write; вернуть HTTP-статус. Запросы сериализуются.
  Future<int> send({required String method, required String path}) =>
      _serialize(() => _sendInner(method, path));

  Future<int> _sendInner(String method, String path) async {
    if (_disposed) throw StateError('executor disposed');
    await _ensureWarm();
    var status = await _execFetch(method, path);
    if (status == 403) {
      _log.info('[executor] 403 → re-warm + retry');
      _warm = false;
      await _ensureWarm();
      status = await _execFetch(method, path);
    }
    return status;
  }

  Future<void> _ensureRunner() async {
    // Видимостью окна управляет фабрика runner'а (флаг hidden при создании);
    // здесь только лениво создаём его один раз.
    _runner ??= await _createRunner();
  }

  Future<void> _ensureWarm() async {
    if (_warm) return;
    await _ensureRunner();
    // (re-)navigate to warmUrl so DataDome issues/refreshes a cookie for this
    // browser session (also used on re-warm after a 403).
    await _runner!.launch(_warmUrl);
    // Дать странице загрузиться и DataDome-challenge поставить cookie — без этой
    // паузы пробы летят раньше, чем сессия готова (спайк ждал ~7с).
    await Future<void>.delayed(_warmSettle);
    for (var i = 0; i < _warmAttempts; i++) {
      var s = -1; // -1 = проба бросила (окно/сеть не готовы)
      Object? err;
      try {
        s = await _execFetch('GET', '/me');
        // status 0 = JS fetch threw (network/CORS/about:blank) — not warm yet.
        // 403 = DataDome ещё не пропускает. Всё прочее (200/401/…) = сессия жива.
        if (s != 403 && s != 0) {
          _log.info('[executor] warm ok after ${i + 1} probe(s) (status $s)');
          _warm = true;
          return;
        }
      } catch (e) {
        err = e; // окно ещё грузится — повторим, но залогируем причину
      }
      _log.info(
        '[executor] warm probe ${i + 1}/$_warmAttempts → $s'
        '${err != null ? ' ($err)' : ''}',
      );
      await Future<void>.delayed(_warmRetryDelay);
    }
    throw StateError('webview warm-up failed (DataDome)');
  }

  Future<int> _execFetch(String method, String path) async {
    final token = await _tokenGetter();
    if (token == null || token.isEmpty) {
      throw StateError('executor: no oauth token');
    }
    final cid = await _clientIdGetter();
    await _runner!.eval(_script(method, path, token, cid));
    for (var i = 0; i < _maxPolls; i++) {
      await Future<void>.delayed(_pollInterval);
      final r = await _runner!.eval(_readExpr);
      if (r != null && r != 'null' && r.isNotEmpty) {
        // Часть движков (WebView2) отдаёт строковый JS-результат как
        // JSON-строку (`"\"{...}\""`) → jsonDecode даёт String; декодируем ещё
        // раз, чтобы получить Map.
        dynamic decoded = jsonDecode(r);
        if (decoded is String) decoded = jsonDecode(decoded);
        final m = decoded as Map<String, dynamic>;
        return (m['status'] as num).toInt();
      }
    }
    throw TimeoutException('webview fetch timed out: $method $path');
  }

  /// Строим JS-инъекцию fetch. Все интерполируемые значения проходят через
  /// jsonEncode → корректное экранирование в JS-строковых литералах.
  ///
  /// ВАЖНО: последний оператор — примитив (`0;`), а не выражение-IIFE. Иначе
  /// результатом eval становится Promise, который WKWebView/WebView2 не умеют
  /// сериализовать → evaluateJavaScript бросает ошибку. Async-IIFE всё равно
  /// исполняется в фоне и кладёт результат в window.__wfRes, который мы поллим.
  String _script(String method, String path, String token, String cid) {
    final sep = path.contains('?') ? '&' : '?';
    final url = 'https://api-v2.soundcloud.com$path${sep}client_id=$cid';
    final urlJs = jsonEncode(url);
    final methodJs = jsonEncode(method);
    final authJs = jsonEncode('OAuth $token');
    return '''
window.__wfRes = null;
(async () => {
  try {
    const r = await fetch($urlJs, { method: $methodJs, headers: { Authorization: $authJs }, credentials: "include" });
    window.__wfRes = JSON.stringify({ status: r.status });
  } catch (e) { window.__wfRes = JSON.stringify({ status: 0, err: String(e) }); }
})();
0;
''';
  }

  Future<T> _serialize<T>(Future<T> Function() op) {
    final run = _tail.then((_) => op());
    _tail = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Best-effort фоновый прогрев (после signIn), чтобы первый лайк не ждал.
  Future<void> prewarm() async {
    if (_disposed) return;
    _log.info('[executor] prewarm started');
    try {
      await _serialize(_ensureWarm);
      _log.info('[executor] prewarm done');
    } catch (e, st) {
      _log.warning('[executor] prewarm failed', e, st);
    }
  }

  Future<void> dispose() {
    _disposed = true;
    return _serialize(() async {
      try {
        await _runner?.close();
      } catch (_) {}
      _runner = null;
      _warm = false;
    });
  }
}
