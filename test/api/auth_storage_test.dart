import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/api/soundcloud_auth.dart';
import 'package:waveform_app/core/api/webview_login.dart';
import 'package:waveform_app/core/storage/atomic_file.dart';
import 'package:waveform_app/core/storage/prefs_store.dart';
import 'package:waveform_app/core/storage/token_store.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('wf_store_'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('TokenStore', () {
    test('writes atomically with owner-only permissions', () async {
      final store = TokenStore(directory: () async => dir);
      await store.write('secret-token');

      expect(await store.read(), 'secret-token');
      expect(File('${dir.path}/sc_oauth_token.tmp').existsSync(), isFalse);
      if (!Platform.isWindows) {
        final mode = File('${dir.path}/sc_oauth_token').statSync().mode;
        expect(mode & 0x1ff, 0x180); // 0600
      }
    });

    test('a failing chmod only warns: the token is still written', () async {
      final store = TokenStore(
        directory: () async => dir,
        chmod: (_) async => throw const ProcessException('chmod', []),
      );
      await store.write('secret');
      expect(await store.read(), 'secret');
    });

    test('delete removes the token and a leftover temp file', () async {
      final store = TokenStore(directory: () async => dir);
      await store.write('secret');
      File('${dir.path}/sc_oauth_token.tmp').writeAsStringSync('half');

      await store.delete();

      expect(File('${dir.path}/sc_oauth_token').existsSync(), isFalse);
      expect(File('${dir.path}/sc_oauth_token.tmp').existsSync(), isFalse);
    });

    test(
      'a signed-out marker keeps a stale token from logging back in',
      () async {
        final store = TokenStore(directory: () async => dir);
        await store.write('secret');
        File('${dir.path}/sc_oauth_token.signed_out').writeAsStringSync('1');

        expect(await store.read(), isNull);
        expect(File('${dir.path}/sc_oauth_token').existsSync(), isFalse);
        await store.write('next');
        expect(await store.read(), 'next');
      },
    );

    test('a failed rename leaves no temp file behind', () async {
      // Target is a directory: rename over it fails.
      Directory('${dir.path}/blocked').createSync();
      await expectLater(
        writeFileAtomic(File('${dir.path}/blocked'), 'x'),
        throwsA(isA<FileSystemException>()),
      );
      expect(File('${dir.path}/blocked.tmp').existsSync(), isFalse);
    });

    test('overwrite replaces the previous token; delete removes it', () async {
      final store = TokenStore(directory: () async => dir);
      await store.write('one');
      await store.write('two');
      expect(await store.read(), 'two');
      await store.delete();
      expect(await store.read(), isNull);
    });
  });

  group('PrefsStore', () {
    test('concurrent writes are serialized and none is lost', () async {
      final store = PrefsStore(directory: () async => dir);
      await Future.wait([
        for (var i = 0; i < 20; i++) store.writeString('k$i', 'v$i'),
      ]);
      for (var i = 0; i < 20; i++) {
        expect(await store.readString('k$i'), 'v$i');
      }
    });

    test(
      'a valid existing .bak is not overwritten by a new corruption',
      () async {
        File('${dir.path}/prefs.json.bak').writeAsStringSync('{"keep":"me"}');
        File('${dir.path}/prefs.json').writeAsStringSync('{oops');
        final store = PrefsStore(directory: () async => dir);

        await store.writeString('a', 'b');

        expect(
          File('${dir.path}/prefs.json.bak').readAsStringSync(),
          '{"keep":"me"}',
        );
      },
    );

    test(
      'a filesystem error does not overwrite prefs with one key',
      () async {
        final f = File('${dir.path}/prefs.json')
          ..writeAsStringSync('{"x":"1","y":"2"}');
        Process.runSync('chmod', ['000', f.path]);
        final store = PrefsStore(directory: () async => dir);
        try {
          await expectLater(
            store.writeString('z', '3'),
            throwsA(isA<FileSystemException>()),
          );
        } finally {
          Process.runSync('chmod', ['600', f.path]);
        }
        expect(jsonDecode(f.readAsStringSync()), {'x': '1', 'y': '2'});
      },
      skip: Platform.isWindows || Platform.environment['USER'] == 'root',
    );

    test('corrupt JSON is kept as .bak, not silently lost', () async {
      final f = File('${dir.path}/prefs.json')..writeAsStringSync('{oops');
      final store = PrefsStore(directory: () async => dir);

      expect(await store.readString('a'), isNull);
      await store.writeString('a', 'b');

      expect(File('${f.path}.bak').readAsStringSync(), '{oops');
      expect(jsonDecode(f.readAsStringSync()), {'a': 'b'});
    });
  });

  group('isSoundcloudDomain', () {
    test('accepts soundcloud.com and subdomains, with or without dot', () {
      expect(isSoundcloudDomain('soundcloud.com'), isTrue);
      expect(isSoundcloudDomain('.soundcloud.com'), isTrue);
      expect(isSoundcloudDomain('api-v2.SoundCloud.com'), isTrue);
    });

    test('rejects look-alike hosts', () {
      expect(isSoundcloudDomain('soundcloud.evil.com'), isFalse);
      expect(isSoundcloudDomain('evilsoundcloud.com'), isFalse);
      expect(isSoundcloudDomain('soundcloud.com.evil.io'), isFalse);
    });
  });

  group('AuthController', () {
    late int clears;
    late ProviderContainer container;
    setUp(() {
      clears = 0;
      container = ProviderContainer(
        overrides: [
          tokenStoreProvider.overrideWithValue(
            TokenStore(directory: () async => dir),
          ),
          webviewSessionClearerProvider.overrideWithValue(() async {
            clears++;
          }),
        ],
      );
      addTearDown(container.dispose);
    });

    test('signOut deletes the token and clears the webview session', () async {
      final auth = container.read(authControllerProvider.notifier);
      await auth.signIn('tok');
      expect(await TokenStore(directory: () async => dir).read(), 'tok');

      await auth.signOut();

      expect(container.read(authControllerProvider).isAuthenticated, isFalse);
      expect(await TokenStore(directory: () async => dir).read(), isNull);
      expect(clears, 1);
    });

    test('a stale restore does not override a newer signIn', () async {
      final gate = Completer<String?>();
      final store = _GateStore(dir, gate.future);
      final c = ProviderContainer(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          webviewSessionClearerProvider.overrideWithValue(() async {}),
        ],
      );
      addTearDown(c.dispose);
      final auth = c.read(authControllerProvider.notifier);
      await store.readStarted.future;

      final signedIn = auth.signIn('fresh');
      gate.complete('old-disk-token');
      await signedIn;
      await pumpEventQueue();

      expect(c.read(authControllerProvider).userToken, 'fresh');
    });

    test(
      'a quick re-signIn is not wiped by the pending webview clear',
      () async {
        final auth = container.read(authControllerProvider.notifier);
        await auth.signIn('first');

        final out = auth.signOut();
        final back = auth.signIn('second');
        await Future.wait([out, back]);

        expect(clears, 0);
        expect(container.read(authControllerProvider).userToken, 'second');
        expect(await TokenStore(directory: () async => dir).read(), 'second');
      },
    );
  });
}

class _GateStore extends TokenStore {
  _GateStore(Directory dir, this._gate) : super(directory: () async => dir);
  final Future<String?> _gate;
  final readStarted = Completer<void>();

  @override
  Future<String?> read() async {
    readStarted.complete();
    return _gate;
  }
}
