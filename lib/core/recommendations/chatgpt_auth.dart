import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:jose/jose.dart';
import 'package:url_launcher/url_launcher.dart';

import 'models.dart';

/// A single protected record keeps rotating token sets atomic. No token is
/// exposed in Riverpod state, diagnostics, or public configuration files.
abstract interface class ChatGptCredentialStore {
  Future<String?> read();
  Future<void> write(String value);
}

class SecureChatGptCredentialStore implements ChatGptCredentialStore {
  static const _storage = FlutterSecureStorage(
    // Legacy Keychain still encrypts secrets and does not require a shared
    // keychain entitlement / machine-specific provisioning profile on macOS.
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );
  static const _key = 'waveform.chatgpt.credentials.v1';
  @override
  Future<String?> read() => _storage.read(key: _key);
  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);
}

class ChatGptAccount {
  ChatGptAccount(this.record);
  final Map<String, dynamic> record;
  String get clientId => record['client_id'] as String;
  String get subject => record['subject'] as String;
  String get label => record['email'] as String? ?? 'ChatGPT account';
  String get binding =>
      sha256.convert(utf8.encode('$clientId:$subject')).toString();
  bool get connected =>
      record['refresh_token'] is String && record['access_token'] is String;
}

abstract interface class ChatGptCallback {
  Uri get redirectUri;
  Future<Uri> get result;
  Future<void> close();
}

/// Listening on IPv4 loopback only; unrelated requests cannot consume an
/// authorization attempt. The callback itself is never reflected into HTML.
class LoopbackChatGptCallback implements ChatGptCallback {
  LoopbackChatGptCallback._(this._server, String state) {
    _subscription = _server.listen((request) async {
      final valid =
          request.method == 'GET' &&
          request.uri.path == '/auth/callback' &&
          request.uri.queryParametersAll['state']?.length == 1 &&
          request.uri.queryParameters['state'] == state &&
          request.headers.host == '127.0.0.1' &&
          request.headers.port == _server.port;
      request.response.headers.set('Cache-Control', 'no-store');
      request.response.headers.set(
        'Content-Security-Policy',
        "default-src 'none'",
      );
      request.response.statusCode = valid ? 200 : 400;
      request.response.write(
        valid ? 'You can return to waveform.' : 'Invalid sign-in callback.',
      );
      await request.response.close();
      if (valid && !_result.isCompleted) _result.complete(request.uri);
    });
  }
  final HttpServer _server;
  final _result = Completer<Uri>();
  late final StreamSubscription<HttpRequest> _subscription;
  static Future<ChatGptCallback> start(String state) async =>
      LoopbackChatGptCallback._(
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        state,
      );
  @override
  Uri get redirectUri =>
      Uri.parse('http://127.0.0.1:${_server.port}/auth/callback');
  @override
  Future<Uri> get result => _result.future;
  @override
  Future<void> close() async {
    if (!_result.isCompleted) _result.completeError(AiFailure.cancelled);
    await _subscription.cancel();
    await _server.close(force: true);
  }
}

/// Official open-source Sign in with ChatGPT public-client flow.
/// https://developers.openai.com/siwc/token-sharing-open-source/sign-in
class ChatGptAuth {
  ChatGptAuth({
    ChatGptCredentialStore? store,
    Dio? dio,
    Future<bool> Function(Uri)? openBrowser,
    Future<ChatGptCallback> Function(String)? callback,
    DateTime Function()? now,
  }) : _store = store ?? SecureChatGptCredentialStore(),
       _dio = dio ?? Dio(),
       _openBrowser =
           openBrowser ??
           ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication)),
       _callback = callback ?? LoopbackChatGptCallback.start,
       _now = now ?? DateTime.now {
    _dio.options = BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      followRedirects: false,
      maxRedirects: 0,
      validateStatus: (_) => true,
    );
  }
  final ChatGptCredentialStore _store;
  final Dio _dio;
  final Future<bool> Function(Uri) _openBrowser;
  final Future<ChatGptCallback> Function(String) _callback;
  final DateTime Function() _now;
  Map<String, dynamic> _vault = {};
  Future<void>? _restore;
  Future<String>? _refresh;
  Future<void> _writes = Future.value();
  ChatGptCallback? _pending;
  int _epoch = 0;
  int _attempt = 0;
  bool _signingIn = false;
  bool _loggingOut = false;
  bool _needsPersistence = false;
  ChatGptAccount? get account {
    final accounts = _vault['accounts'];
    if (accounts is! List) return null;
    for (final item in accounts) {
      if (item is Map<String, dynamic> &&
          item['client_id'] == _vault['active']) {
        return ChatGptAccount(item);
      }
    }
    return null;
  }

  String _random() => base64Url
      .encode(List<int>.generate(32, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');
  Future<void> restore() async {
    final operation = _restore ??= _load();
    try {
      await operation;
    } catch (_) {
      if (identical(_restore, operation)) _restore = null;
      rethrow;
    }
  }

  Future<void> _load() async {
    try {
      final raw = await _store.read();
      if (raw != null) {
        if (raw.length > 256 * 1024) throw AiFailure.storage;
        _vault = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      } else {
        _vault = {};
      }
      if (_vault['host'] is! String) {
        _vault['host'] = 'urn:waveform:${_random()}';
        await _save();
      }
    } catch (_) {
      throw AiFailure.storage;
    }
  }

  Future<void> _save() {
    final encoded = jsonEncode(_vault);
    final next = _writes.then((_) => _store.write(encoded));
    _writes = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next.catchError((Object _) => throw AiFailure.storage);
  }

  Uri _trusted(String value) {
    final uri = Uri.parse(value);
    if (uri.scheme != 'https' ||
        uri.host != 'auth.openai.com' ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443) {
      throw AiFailure.signIn;
    }
    return uri;
  }

  Future<Map<String, dynamic>> _json(
    Uri uri, {
    Map<String, String>? form,
  }) async {
    final response = await _dio.request<String>(
      uri.toString(),
      data: form,
      options: Options(
        method: form == null ? 'GET' : 'POST',
        responseType: ResponseType.plain,
        contentType: form == null ? null : Headers.formUrlEncodedContentType,
      ),
    );
    if (response.statusCode != 200) throw AiFailure.credentials;
    if ((response.data?.length ?? 0) > 256 * 1024) throw AiFailure.malformed;
    return Map<String, dynamic>.from(jsonDecode(response.data!) as Map);
  }

  Future<Map<String, dynamic>> _discovery() async {
    final data = await _json(
      Uri.parse('https://auth.openai.com/.well-known/openid-configuration'),
    );
    if (data['issuer'] != 'https://auth.openai.com') throw AiFailure.signIn;
    for (final key in [
      'authorization_endpoint',
      'token_endpoint',
      'jwks_uri',
      'revocation_endpoint',
    ]) {
      _trusted(data[key] as String);
    }
    return data;
  }

  Future<Map<String, dynamic>> validateIdentity(
    String raw, {
    required String clientId,
    String? nonce,
    required Map<String, dynamic> discovery,
  }) async {
    if (raw.length > 32768) throw AiFailure.signIn;
    final header = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(raw.split('.').first))),
    );
    if (header is! Map ||
        !const ['RS256', 'ES256'].contains(header['alg']) ||
        header['kid'] is! String) {
      throw AiFailure.signIn;
    }
    final keys = await _json(_trusted(discovery['jwks_uri'] as String));
    final store = JsonWebKeyStore();
    for (final key in keys['keys'] as List) {
      if (key['kid'] == header['kid'] &&
          const ['RSA', 'EC'].contains(key['kty'])) {
        store.addKey(
          JsonWebKey.fromJson(Map<String, dynamic>.from(key as Map)),
        );
      }
    }
    final jwt = JsonWebToken.unverified(raw);
    if (!await jwt.verify(store, allowedArguments: [header['alg'] as String])) {
      throw AiFailure.signIn;
    }
    final claims = jwt.claims.toJson();
    final seconds = _now().millisecondsSinceEpoch ~/ 1000;
    final audience = claims['aud'];
    if (claims['iss'] != discovery['issuer'] ||
        !(audience == clientId ||
            audience is List && audience.contains(clientId)) ||
        (audience is List &&
            audience.length > 1 &&
            claims['azp'] != clientId) ||
        claims['exp'] is! num ||
        (claims['exp'] as num) <= seconds - 5 ||
        claims['iat'] is! num ||
        (claims['iat'] as num) > seconds + 5 ||
        claims['nbf'] is num && (claims['nbf'] as num) > seconds + 5 ||
        claims['sub'] is! String ||
        (claims['sub'] as String).isEmpty ||
        nonce != null && claims['nonce'] != nonce) {
      throw AiFailure.signIn;
    }
    return claims;
  }

  Map<String, dynamic> _tokens(Map<String, dynamic> response) {
    for (final key in ['access_token', 'refresh_token']) {
      if (response[key] is! String ||
          (response[key] as String).isEmpty ||
          (response[key] as String).length > 32768 ||
          RegExp(r'[\r\n]').hasMatch(response[key] as String)) {
        throw AiFailure.signIn;
      }
    }
    if ((response['token_type'] as String?)?.toLowerCase() != 'bearer' ||
        response['expires_in'] is! num) {
      throw AiFailure.signIn;
    }
    final scopes = (response['scope'] as String? ?? '').split(' ');
    if (!scopes.contains('chatgpt.tokens.use.direct') ||
        !scopes.contains('resource.invoke')) {
      throw AiFailure.permission;
    }
    return {
      ...response,
      'expires_at': _now()
          .add(Duration(seconds: (response['expires_in'] as num).toInt()))
          .millisecondsSinceEpoch,
    };
  }

  Future<void> signIn({bool newAccount = false}) async {
    if (_signingIn || _loggingOut) throw AiFailure.signIn;
    _signingIn = true;
    final attempt = ++_attempt;
    void checkAttempt() {
      if (attempt != _attempt || _loggingOut) throw AiFailure.cancelled;
    }

    ChatGptCallback? callback;
    try {
      await restore();
      checkAttempt();
      final previous = newAccount ? null : account;
      final discovery = await _discovery();
      checkAttempt();
      final state = _random(), nonce = _random(), verifier = _random();
      callback = _pending = await _callback(state);
      // Ensure cancellation is always observed even if browser launch fails.
      final result = callback.result;
      unawaited(
        result.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
      checkAttempt();
      final redirect = callback.redirectUri;
      if (redirect.scheme != 'http' ||
          redirect.host != '127.0.0.1' ||
          redirect.path != '/auth/callback' ||
          redirect.hasQuery ||
          redirect.hasFragment) {
        throw AiFailure.signIn;
      }
      final authorization =
          _trusted(discovery['authorization_endpoint'] as String).replace(
            queryParameters: {
              'client_id': previous?.clientId ?? 'dynamic_agent_client',
              if (previous == null) 'agent_name_hint': 'waveform',
              'ext_agent_host_id': _vault['host'] as String,
              if (previous?.record['id_token'] is String)
                'id_token_hint': previous!.record['id_token'] as String,
              'response_type': 'code',
              'redirect_uri': redirect.toString(),
              'scope':
                  'openid profile email offline_access resource.invoke chatgpt.tokens.use.direct',
              'resource': 'https://api.openai.com/v1',
              'state': state,
              'nonce': nonce,
              'code_challenge_method': 'S256',
              'code_challenge': base64Url
                  .encode(sha256.convert(ascii.encode(verifier)).bytes)
                  .replaceAll('=', ''),
            },
          );
      checkAttempt();
      if (!await _openBrowser(authorization)) throw AiFailure.signIn;
      checkAttempt();
      final returned = await result.timeout(const Duration(minutes: 3));
      final query = returned.queryParameters;
      if (returned.queryParametersAll.values.any(
            (values) => values.length != 1,
          ) ||
          query['state'] != state ||
          attempt != _attempt) {
        throw AiFailure.signIn;
      }
      if (query.containsKey('error')) throw AiFailure.permission;
      final clientId = query['client_id'] ?? previous?.clientId;
      if (clientId == null ||
          !RegExp(r'^oaiapp_[A-Za-z0-9_-]+$').hasMatch(clientId) ||
          previous != null && previous.clientId != clientId ||
          (query['code']?.isEmpty ?? true)) {
        throw AiFailure.signIn;
      }
      final tokenResponse = await _json(
        _trusted(discovery['token_endpoint'] as String),
        form: {
          'grant_type': 'authorization_code',
          'client_id': clientId,
          'code': query['code']!,
          'code_verifier': verifier,
          'redirect_uri': redirect.toString(),
          'resource': 'https://api.openai.com/v1',
        },
      );
      final tokens = _tokens(tokenResponse);
      final identity = await validateIdentity(
        tokens['id_token'] as String,
        clientId: clientId,
        nonce: nonce,
        discovery: discovery,
      );
      if (previous != null && previous.subject != identity['sub'] ||
          attempt != _attempt) {
        throw AiFailure.signIn;
      }
      // A pending authorization has no effect on the active registration.
      // Preserve any rotating refresh before activating a validated account.
      try {
        await _refresh;
      } catch (_) {}
      if (attempt != _attempt) throw AiFailure.cancelled;
      ++_epoch;
      final record = <String, dynamic>{
        ...tokens,
        'client_id': clientId,
        'subject': identity['sub'],
        'email': identity['email'],
      };
      final accounts = List<dynamic>.from(_vault['accounts'] as List? ?? []);
      accounts.removeWhere((dynamic value) => value['client_id'] == clientId);
      accounts.add(record);
      final oldVault = _vault;
      _vault = {..._vault, 'accounts': accounts, 'active': clientId};
      try {
        await _save();
      } catch (_) {
        // Logout may already be revoking/clearing the newly staged record.
        // Never resurrect the previous account after its attempt was cancelled.
        if (attempt == _attempt) _vault = oldVault;
        rethrow;
      }
    } on AiFailure {
      rethrow;
    } catch (_) {
      throw AiFailure.signIn;
    } finally {
      await callback?.close();
      if (identical(_pending, callback)) _pending = null;
      _signingIn = false;
    }
  }

  Future<String> accessToken() async {
    await restore();
    if (_loggingOut) throw AiFailure.cancelled;
    if (_needsPersistence) {
      await _save();
      _needsPersistence = false;
    }
    final current = account;
    if (current == null || !current.connected) throw AiFailure.credentials;
    if ((current.record['expires_at'] as num? ?? 0) >
        _now().add(const Duration(minutes: 1)).millisecondsSinceEpoch) {
      return current.record['access_token'] as String;
    }
    if (_refresh != null) return _refresh!;
    final future = _refreshTokens(current, _epoch);
    _refresh = future;
    try {
      return await future;
    } finally {
      if (identical(_refresh, future)) _refresh = null;
    }
  }

  Future<String> _refreshTokens(ChatGptAccount current, int epoch) async {
    try {
      final discovery = await _discovery();
      final response = await _json(
        _trusted(discovery['token_endpoint'] as String),
        form: {
          'grant_type': 'refresh_token',
          'client_id': current.clientId,
          'refresh_token': current.record['refresh_token'] as String,
          'resource': 'https://api.openai.com/v1',
        },
      );
      final tokens = _tokens(response);
      if (tokens['id_token'] != null) {
        final claims = await validateIdentity(
          tokens['id_token'] as String,
          clientId: current.clientId,
          discovery: discovery,
        );
        if (claims['sub'] != current.subject) throw AiFailure.signIn;
      }
      if (epoch != _epoch) throw AiFailure.cancelled;
      current.record.addAll(tokens);
      _needsPersistence = true;
      await _save();
      _needsPersistence = false;
      return tokens['access_token'] as String;
    } on AiFailure {
      rethrow;
    } catch (_) {
      throw AiFailure.credentials;
    }
  }

  /// Returns false if remote revocation was not confirmed; tokens are always
  /// cleared locally, while the host and validated registration are retained.
  Future<bool> signOut() async {
    ++_attempt;
    _loggingOut = true;
    try {
      await _pending?.close();
      await restore();
      // Finish a rotating refresh before revoking its latest replacement.
      try {
        await _refresh;
      } catch (_) {}
      ++_epoch;
      final current = account;
      var revoked = current?.connected != true;
      if (current?.connected == true) {
        try {
          final discovery = await _discovery();
          for (var attempt = 0; attempt < 2 && !revoked; attempt++) {
            if (attempt > 0) {
              await Future<void>.delayed(const Duration(milliseconds: 250));
            }
            try {
              final response = await _dio.post<String>(
                _trusted(discovery['revocation_endpoint'] as String).toString(),
                data: {
                  'token': current!.record['refresh_token'],
                  'token_type_hint': 'refresh_token',
                  'client_id': current.clientId,
                },
                options: Options(
                  contentType: Headers.formUrlEncodedContentType,
                  responseType: ResponseType.plain,
                ),
              );
              revoked = response.statusCode == 200;
            } catch (_) {
              // Retry transient transport failures once before clearing locally.
            }
          }
        } catch (_) {
          revoked = false;
        }
      }
      if (current != null) {
        for (final key in [
          'access_token',
          'refresh_token',
          'id_token',
          'expires_at',
          'scope',
        ]) {
          current.record.remove(key);
        }
        await _save();
        _needsPersistence = false;
      }
      return revoked;
    } finally {
      _loggingOut = false;
    }
  }

  void close() {
    ++_attempt;
    ++_epoch;
    unawaited(_pending?.close());
    _dio.close(force: true);
  }
}
