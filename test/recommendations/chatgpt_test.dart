import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jose/jose.dart';
import 'package:waveform_app/core/recommendations/ai_client.dart';
import 'package:waveform_app/core/recommendations/ai_config.dart';
import 'package:waveform_app/core/recommendations/chatgpt_auth.dart';
import 'package:waveform_app/core/recommendations/chatgpt_client.dart';
import 'package:waveform_app/core/recommendations/models.dart';

class MemoryCredentials implements ChatGptCredentialStore {
  String? value;
  final writes = <String>[];
  bool fail = false;
  bool failRead = false;
  Future<void> Function(String)? beforeWrite;
  @override
  Future<String?> read() async {
    if (failRead) throw StateError('synthetic locked keychain');
    return value;
  }

  @override
  Future<void> write(String next) async {
    await beforeWrite?.call(next);
    if (fail) throw StateError('SECRET');
    value = next;
    writes.add(next);
  }
}

class FakeCallback implements ChatGptCallback {
  final completion = Completer<Uri>();
  bool closed = false;
  @override
  Uri get redirectUri => Uri.parse('http://127.0.0.1:23456/auth/callback');
  @override
  Future<Uri> get result => completion.future;
  @override
  Future<void> close() async {
    closed = true;
  }
}

class AuthAdapter implements HttpClientAdapter {
  AuthAdapter() {
    key = JsonWebKey.fromJson({
      ...JsonWebKey.generate('ES256').toJson(),
      'kid': 'test-key',
    });
  }
  late final JsonWebKey key;
  String nonce = '';
  String subject = 'subject-one';
  String tokenAudience = 'oaiapp_test';
  String issuer = 'https://auth.openai.com';
  int expiry = 4102444800;
  String scopes =
      'openid profile email offline_access resource.invoke chatgpt.tokens.use.direct';
  final requests = <RequestOptions>[];
  int refreshes = 0;
  Completer<void>? discoveryGate, refreshGate, revokeGate;
  final discoveryStarted = Completer<void>();
  final refreshStarted = Completer<void>();
  final revokeStarted = Completer<void>();
  int revokeFailures = 0;
  String get idToken {
    final builder = JsonWebSignatureBuilder()
      ..jsonContent = {
        'iss': issuer,
        'aud': tokenAudience,
        'sub': subject,
        'email': 'person@example.com',
        'nonce': nonce,
        'exp': expiry,
        'iat': 1700000000,
      }
      ..addRecipient(key, algorithm: 'ES256');
    return builder.build().toCompactSerialization();
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final path = options.uri.path;
    Object body;
    if (path.endsWith('openid-configuration')) {
      if (!discoveryStarted.isCompleted) discoveryStarted.complete();
      await discoveryGate?.future;
      body = {
        'issuer': 'https://auth.openai.com',
        'authorization_endpoint':
            'https://auth.openai.com/api/accounts/authorize',
        'token_endpoint': 'https://auth.openai.com/api/accounts/oauth/token',
        'jwks_uri': 'https://auth.openai.com/.well-known/jwks.json',
        'revocation_endpoint':
            'https://auth.openai.com/api/accounts/oauth/revoke',
      };
    } else if (path.endsWith('jwks.json')) {
      body = {
        'keys': [Map<String, dynamic>.from(key.toJson())..remove('d')],
      };
    } else if (path.endsWith('/token')) {
      if (options.data.toString().contains('refresh_token')) {
        refreshes++;
        if (!refreshStarted.isCompleted) refreshStarted.complete();
        await refreshGate?.future;
      }
      body = {
        'access_token': 'ACCESS_SECRET_$refreshes',
        'refresh_token': 'REFRESH_SECRET_$refreshes',
        'id_token': idToken,
        'token_type': 'Bearer',
        'expires_in': 3600,
        'scope': scopes,
      };
    } else if (path.endsWith('/revoke')) {
      if (!revokeStarted.isCompleted) revokeStarted.complete();
      await revokeGate?.future;
      if (revokeFailures-- > 0) {
        throw const SocketException('synthetic transport failure');
      }
      return ResponseBody.fromString('', 200);
    } else if (path.endsWith('/models')) {
      body = {
        'models': [
          {'visibility': 'hidden', 'slug': 'hidden'},
          {'visibility': 'list', 'slug': 'first-visible'},
          {'visibility': 'list', 'slug': 'second-visible'},
        ],
      };
    } else if (path.endsWith('/responses')) {
      return ResponseBody.fromString(
        'data: {"type":"response.output_text.delta","delta":"{\\"queries\\":[\\"ambient\\"]}"}\n\n'
        'data: {"type":"response.completed"}\n\n',
        200,
        headers: {
          'content-type': ['text/event-stream'],
        },
      );
    } else {
      throw StateError('unexpected path $path');
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late MemoryCredentials store;
  late AuthAdapter adapter;
  late ChatGptAuth auth;
  late FakeCallback callback;
  late Uri authorization;
  bool deny = false;
  bool wrongState = false, missingClient = false, wrongNonce = false;
  DateTime now = DateTime.utc(2026, 10, 25);
  setUp(() {
    store = MemoryCredentials();
    adapter = AuthAdapter();
    callback = FakeCallback();
    now = DateTime.utc(2026, 10, 25);
    deny = false;
    wrongState = false;
    missingClient = false;
    wrongNonce = false;
    auth = ChatGptAuth(
      store: store,
      dio: Dio()..httpClientAdapter = adapter,
      callback: (_) async => callback,
      now: () => now,
      openBrowser: (uri) async {
        authorization = uri;
        adapter.nonce = wrongNonce
            ? 'wrong-nonce'
            : uri.queryParameters['nonce']!;
        callback.completion.complete(
          Uri(
            path: '/auth/callback',
            queryParameters: {
              'state': wrongState
                  ? 'wrong-state'
                  : uri.queryParameters['state']!,
              if (deny) 'error': 'access_denied' else 'code': 'CODE_SECRET',
              if (!missingClient) 'client_id': 'oaiapp_test',
            },
          ),
        );
        return true;
      },
    );
  });
  tearDown(() => auth.close());

  test(
    'callback state, issued client and ID-token nonce fail closed',
    () async {
      for (final mutate in [
        () => wrongState = true,
        () => missingClient = true,
        () => wrongNonce = true,
      ]) {
        wrongState = false;
        missingClient = false;
        wrongNonce = false;
        callback = FakeCallback();
        mutate();
        await expectLater(auth.signIn(), throwsA(AiFailure.signIn));
        expect(auth.account, isNull);
        expect(callback.closed, isTrue);
      }
    },
  );

  test('tampered signature cannot authenticate identity', () async {
    final parts = adapter.idToken.split('.');
    final signature = base64Url.decode(base64Url.normalize(parts[2]));
    signature[0] ^= 1;
    parts[2] = base64Url.encode(signature).replaceAll('=', '');
    await expectLater(
      auth.validateIdentity(
        parts.join('.'),
        clientId: 'oaiapp_test',
        nonce: '',
        discovery: {
          'issuer': 'https://auth.openai.com',
          'jwks_uri': 'https://auth.openai.com/.well-known/jwks.json',
        },
      ),
      throwsA(AiFailure.signIn),
    );
  });

  test(
    'denied pending sign-in preserves a concurrent rotating refresh',
    () async {
      await auth.signIn();
      now = now.add(const Duration(hours: 2));
      adapter.refreshGate = Completer<void>();
      final refresh = auth.accessToken();
      await adapter.refreshStarted.future;
      deny = true;
      callback = FakeCallback();
      await expectLater(auth.signIn(), throwsA(AiFailure.permission));
      adapter.refreshGate!.complete();
      expect(await refresh, 'ACCESS_SECRET_1');
      expect(auth.account!.record['refresh_token'], 'REFRESH_SECRET_1');
      expect(store.value, contains('REFRESH_SECRET_1'));
    },
  );

  test(
    'logout during delayed discovery starts neither callback nor browser',
    () async {
      auth.close();
      adapter.discoveryGate = Completer<void>();
      var callbacks = 0, browsers = 0;
      auth = ChatGptAuth(
        store: store,
        dio: Dio()..httpClientAdapter = adapter,
        callback: (_) async {
          callbacks++;
          return callback;
        },
        openBrowser: (_) async {
          browsers++;
          return true;
        },
      );
      final signIn = auth.signIn();
      final assertion = expectLater(signIn, throwsA(AiFailure.cancelled));
      await adapter.discoveryStarted.future;
      await auth.signOut();
      adapter.discoveryGate!.complete();
      await assertion;
      expect(callbacks, 0);
      expect(browsers, 0);
      expect(auth.account, isNull);
    },
  );

  test(
    'failed staged sign-in write cannot resurrect old account after logout',
    () async {
      await auth.signIn();
      // The second issued registration is a distinct account, with a staged save.
      final staged = Completer<void>(), releaseWrite = Completer<void>();
      store.beforeWrite = (_) async {
        store.beforeWrite = null;
        staged.complete();
        await releaseWrite.future;
        throw StateError('synthetic storage failure');
      };
      adapter.revokeGate = Completer<void>();
      callback = FakeCallback();
      final signIn = auth.signIn(newAccount: true);
      final assertion = expectLater(signIn, throwsA(AiFailure.storage));
      await staged.future;
      final logout = auth.signOut();
      await adapter.revokeStarted.future;
      releaseWrite.complete();
      await assertion;
      adapter.revokeGate!.complete();
      expect(await logout, isTrue);
      expect(auth.account!.connected, isFalse);
      expect(
        (jsonDecode(store.value!)['accounts'] as List)
            .where(
              (dynamic account) =>
                  account['client_id'] == jsonDecode(store.value!)['active'],
            )
            .single['refresh_token'],
        isNull,
      );
    },
  );

  test(
    'remote logout retries a transient network failure before clearing locally',
    () async {
      await auth.signIn();
      adapter.revokeFailures = 1;
      expect(await auth.signOut(), isTrue);
      expect(
        adapter.requests
            .where((request) => request.uri.path.endsWith('/revoke'))
            .length,
        2,
      );
      expect(auth.account!.connected, isFalse);
    },
  );

  test(
    'latest rotated tokens are persisted on retry after transient storage failure',
    () async {
      await auth.signIn();
      now = now.add(const Duration(hours: 2));
      store.fail = true;
      await expectLater(auth.accessToken(), throwsA(AiFailure.storage));
      expect(auth.account!.record['refresh_token'], 'REFRESH_SECRET_1');
      store.fail = false;
      expect(await auth.accessToken(), 'ACCESS_SECRET_1');
      expect(adapter.refreshes, 1);
      final restored = ChatGptAuth(
        store: store,
        dio: Dio()..httpClientAdapter = adapter,
        now: () => now,
      );
      addTearDown(restored.close);
      await restored.restore();
      expect(restored.account!.record['refresh_token'], 'REFRESH_SECRET_1');
    },
  );

  test(
    'unlocking secure storage recovers after a failed concurrent restore',
    () async {
      store.failRead = true;
      await Future.wait([
        expectLater(auth.restore(), throwsA(AiFailure.storage)),
        expectLater(auth.restore(), throwsA(AiFailure.storage)),
      ]);
      store.failRead = false;
      await auth.signIn();
      expect(auth.account!.connected, isTrue);
      expect(store.value, contains('REFRESH_SECRET_0'));
    },
  );

  test('signed test identity verifies', () async {
    expect(
      (await auth.validateIdentity(
        adapter.idToken,
        clientId: 'oaiapp_test',
        nonce: '',
        discovery: {
          'issuer': 'https://auth.openai.com',
          'jwks_uri': 'https://auth.openai.com/.well-known/jwks.json',
        },
      ))['sub'],
      'subject-one',
    );
  });

  test(
    'official dynamic flow validates signed identity and exact PKCE exchange',
    () async {
      await auth.signIn();
      expect(auth.account!.connected, isTrue);
      expect(auth.account!.label, 'person@example.com');
      expect(callback.closed, isTrue);
      expect(authorization.host, 'auth.openai.com');
      expect(
        authorization.queryParameters['client_id'],
        'dynamic_agent_client',
      );
      expect(authorization.queryParameters['agent_name_hint'], 'waveform');
      final exchange = adapter.requests.firstWhere(
        (request) => request.uri.path.endsWith('/token'),
      );
      final form = Map<String, dynamic>.from(exchange.data as Map);
      expect(form['client_id'], 'oaiapp_test');
      expect(form['redirect_uri'], callback.redirectUri.toString());
      expect(
        authorization.queryParameters['code_challenge'],
        base64Url
            .encode(
              sha256
                  .convert(ascii.encode(form['code_verifier'] as String))
                  .bytes,
            )
            .replaceAll('=', ''),
      );
      expect(exchange.followRedirects, isFalse);
      expect(exchange.maxRedirects, 0);
      expect(form.containsKey('client_secret'), isFalse);
      expect(store.value, contains('REFRESH_SECRET'));
    },
  );

  test(
    'identity issuer, audience, nonce, expiry, subject and permission fail closed',
    () async {
      for (final mutation in [
        () => adapter.issuer = 'https://evil.invalid',
        () => adapter.tokenAudience = 'oaiapp_other',
        () => adapter.expiry = 1,
        () => adapter.subject = '',
        () => adapter.scopes = 'openid',
      ]) {
        adapter.issuer = 'https://auth.openai.com';
        adapter.tokenAudience = 'oaiapp_test';
        adapter.expiry = 4102444800;
        adapter.subject = 'subject-one';
        adapter.scopes = 'openid resource.invoke chatgpt.tokens.use.direct';
        callback = FakeCallback();
        mutation();
        await expectLater(auth.signIn(), throwsA(isA<AiFailure>()));
        expect(auth.account, isNull);
      }
    },
  );

  test('secure write failure leaves no active in-memory connection', () async {
    await auth.restore();
    store.fail = true;
    await expectLater(auth.signIn(), throwsA(AiFailure.storage));
    expect(auth.account, isNull);
  });

  test(
    'refresh is serialized and rotates atomically; logout retains registration and host',
    () async {
      await auth.signIn();
      final host = jsonDecode(store.value!)['host'];
      now = now.add(const Duration(hours: 2));
      expect(await Future.wait([auth.accessToken(), auth.accessToken()]), [
        'ACCESS_SECRET_1',
        'ACCESS_SECRET_1',
      ]);
      expect(adapter.refreshes, 1);
      expect(await auth.signOut(), isTrue);
      final vault = jsonDecode(store.value!);
      expect(vault['host'], host);
      expect(auth.account!.clientId, 'oaiapp_test');
      expect(auth.account!.connected, isFalse);
      expect(store.value, isNot(contains('SECRET')));
      callback = FakeCallback();
      await auth.signIn();
      expect(authorization.queryParameters['client_id'], 'oaiapp_test');
      expect(
        authorization.queryParameters.containsKey('agent_name_hint'),
        isFalse,
      );
      expect(authorization.queryParameters['ext_agent_host_id'], host);
    },
  );

  test(
    'Responses uses first visible account model and permitted fields only',
    () async {
      await auth.signIn();
      final client = ChatGptAiClient(
        auth: auth,
        dio: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(client.close);
      const config = AiConfig(backend: AiBackend.chatGpt);
      expect(
        await client.complete(
          config: config,
          consent: AiConsent(destination: config.destination, listening: false),
          apiKey: 'NEVER_USE_CUSTOM_KEY',
          system: 'JSON only',
          data: '{}',
          cancelToken: CancelToken(),
        ),
        contains('ambient'),
      );
      final request = adapter.requests.last;
      expect(request.uri.toString(), 'https://api.openai.com/v1/responses');
      expect(request.headers['Authorization'], 'Bearer ACCESS_SECRET_0');
      final body = request.data as Map;
      expect(
        body.keys,
        unorderedEquals(['model', 'instructions', 'input', 'store', 'stream']),
      );
      expect(body['model'], 'first-visible');
      expect(body['store'], isFalse);
      expect(body['stream'], isTrue);
      expect(request.followRedirects, isFalse);
    },
  );

  test(
    'SSE rejects text followed by usage failure or incomplete/interrupted terminal',
    () async {
      const text =
          'data: {"type":"response.output_text.delta","delta":"{}"}\n\n';
      for (final (terminal, failure) in [
        (
          'data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}\n\n',
          AiFailure.rateLimit,
        ),
        (
          'data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_unavailable"}}}\n\n',
          AiFailure.permission,
        ),
        ('data: {"type":"response.incomplete"}\n\n', AiFailure.malformed),
        ('', AiFailure.malformed),
      ]) {
        await expectLater(
          parseChatGptEvents(
            Stream.value(utf8.encode('$text$terminal')),
            CancelToken(),
          ),
          throwsA(failure),
        );
      }
    },
  );

  test(
    'SSE handles split multibyte chunks and cancellation during stalled body',
    () async {
      final bytes = utf8.encode(
        'data: {"type":"response.output_text.delta","delta":"ночь"}\r\n\r\n'
        'data: {"type":"response.completed"}\n\n',
      );
      expect(
        await parseChatGptEvents(
          Stream.fromIterable(bytes.map((byte) => [byte])),
          CancelToken(),
        ),
        'ночь',
      );
      final stream = StreamController<List<int>>();
      final token = CancelToken();
      final pending = parseChatGptEvents(stream.stream, token);
      token.cancel();
      await expectLater(pending, throwsA(AiFailure.cancelled));
      await stream.close();
    },
  );

  test(
    'loopback listener rejects wrong state and non-callback paths before accepting valid return',
    () async {
      final listener = await LoopbackChatGptCallback.start('expected');
      final client = HttpClient();
      addTearDown(() {
        client.close(force: true);
      });
      addTearDown(listener.close);
      final result = listener.result;
      for (final uri in [
        listener.redirectUri.replace(queryParameters: {'state': 'wrong'}),
        listener.redirectUri.replace(
          path: '/other',
          queryParameters: {'state': 'expected'},
        ),
      ]) {
        final response = await (await client.getUrl(uri)).close();
        expect(response.statusCode, 400);
        await response.drain<void>();
      }
      final uri = listener.redirectUri.replace(
        queryParameters: {'state': 'expected', 'code': 'test'},
      );
      final response = await (await client.getUrl(uri)).close();
      expect(response.statusCode, 200);
      await response.drain<void>();
      expect((await result).queryParameters['code'], 'test');
    },
  );
}
