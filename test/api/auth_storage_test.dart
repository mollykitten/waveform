import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/api/soundcloud_auth.dart';
import 'package:waveform_app/core/api/webview_login.dart';
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
      await TokenStore(directory: () async => dir).write('old-disk-token');
      final auth = container.read(authControllerProvider.notifier);
      await auth.signIn('fresh');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(container.read(authControllerProvider).userToken, 'fresh');
    });
  });
}
