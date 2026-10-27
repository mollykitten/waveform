import 'dart:async';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../log/talker.dart';
import '../storage/token_store.dart';

/// Состояние авторизации SoundCloud.
///
/// [clientId] — ключ приложения (нужен на каждом запросе, один на всех,
/// НЕ идентифицирует юзера). [userToken] — персональный OAuth Bearer,
/// появляется после входа (личный stream/library/likes/posting).
///
/// Вход — через настоящую страницу логина SoundCloud в embedded WebView
/// (см. webview_login.dart); сырые пароли мы не храним.
class SoundcloudAuth {
  const SoundcloudAuth({this.clientId, this.userToken});

  final String? clientId;
  final String? userToken;

  bool get hasClientId => clientId != null && clientId!.isNotEmpty;
  bool get isAuthenticated => userToken != null && userToken!.isNotEmpty;

  SoundcloudAuth copyWith({String? clientId, String? userToken}) =>
      SoundcloudAuth(
        clientId: clientId ?? this.clientId,
        userToken: userToken ?? this.userToken,
      );

  SoundcloudAuth signedOut() => SoundcloudAuth(clientId: clientId);
}

/// Хранилище пользовательского токена; тесты подменяют его на временный каталог.
final tokenStoreProvider = Provider<TokenStore>((ref) => const TokenStore());

/// Сбрасывает cookie/сторадж webview (сессия входа SoundCloud). Без этого после
/// sign out окно входа открывается с живой сессией и молча логинит обратно.
/// На macOS чистит `WKWebsiteDataStore.default()` (cookies + localStorage);
/// на Windows/Linux нативный `clearAll` закрывает все окна плагина и сносит
/// данные (Windows — ещё папку WebView2). Тесты подменяют провайдер.
final webviewSessionClearerProvider = Provider<Future<void> Function()>(
  (ref) =>
      () => WebviewWindow.clearAll(),
);

class AuthController extends Notifier<SoundcloudAuth> {
  TokenStore get _store => ref.read(tokenStoreProvider);

  /// Операции хранилища идут одной цепочкой: write/delete/restore не
  /// обгоняют друг друга.
  Future<void> _tail = Future<void>.value();

  /// Растёт при каждом signIn/signOut. `_restore` игнорирует результат чтения
  /// диска, если за время чтения состояние уже менял пользователь.
  int _generation = 0;

  @override
  SoundcloudAuth build() {
    unawaited(_restore());
    return const SoundcloudAuth();
  }

  Future<void> _enqueue(Future<void> Function() op) {
    final run = _tail.then((_) => _safe(op));
    _tail = run;
    return run;
  }

  /// Подтягиваем сохранённый токен при старте (best-effort; в тестах плагина
  /// path_provider нет — глушим).
  Future<void> _restore() async {
    final generation = _generation;
    await _enqueue(() async {
      final token = await _store.read();
      if (generation != _generation) {
        ref.read(talkerProvider).info('auth: restore skipped (state changed)');
        return;
      }
      if (token != null && token.isNotEmpty) {
        state = state.copyWith(userToken: token);
        ref.read(talkerProvider).info('auth: restored ${_describe(token)}');
      } else {
        ref.read(talkerProvider).info('auth: no stored token');
      }
    });
  }

  // В логи — только тип и длину: ни префикс, ни хвост токена не светим.
  String _describe(String t) => 'token (len ${t.length})';

  /// client_id добывается автоматически из веб-бандла (как в yt-dlp/FetchClientID).
  void setClientId(String id) => state = state.copyWith(clientId: id);

  /// Сохраняем токен после входа. Состояние ставим сразу; запись на диск —
  /// в очереди (не блокируем UI/тесты, где плагина path_provider нет).
  /// Возвращаемый Future завершается, когда токен записан.
  Future<void> signIn(String userToken) {
    _generation++;
    state = state.copyWith(userToken: userToken);
    ref.read(talkerProvider).info('auth: signIn ${_describe(userToken)}');
    return _enqueue(() => _store.write(userToken));
  }

  /// Выход: токен из состояния и с диска, затем сброс сессии webview, чтобы
  /// окно входа не залогинило обратно. Sync-webview (executor) пересоздаётся
  /// провайдером сам: он следит за `isAuthenticated`.
  Future<void> signOut() {
    _generation++;
    ref.read(talkerProvider).info('auth: signOut');
    state = state.signedOut();
    final clear = ref.read(webviewSessionClearerProvider);
    final generation = _generation;
    return _enqueue(() async {
      try {
        await _store.delete();
      } catch (e, st) {
        // Не глотаем молча: токен мог остаться на диске (TokenStore ставит
        // маркер выхода, чтобы следующий старт не залогинил обратно).
        ref.read(talkerProvider).warning('auth: token delete failed', e, st);
      }
      // Пользователь уже вошёл заново — сброс снёс бы свежую сессию.
      if (generation != _generation) {
        ref
            .read(talkerProvider)
            .info('auth: webview clear skipped (re-signed)');
        return;
      }
      await clear();
    });
  }

  Future<void> _safe(Future<void> Function() op) async {
    try {
      await op();
    } catch (e, st) {
      ref.read(talkerProvider).warning('auth: storage op failed', e, st);
    }
  }
}

final authControllerProvider = NotifierProvider<AuthController, SoundcloudAuth>(
  AuthController.new,
);
