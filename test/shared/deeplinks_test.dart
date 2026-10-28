import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:waveform_app/core/deeplinks/clipboard_watcher.dart';
import 'package:waveform_app/core/deeplinks/scheme_registrar.dart';

void main() {
  group('scLinkLabel', () {
    test('drops domain and query', () {
      expect(
        scLinkLabel('https://soundcloud.com/artist/track?si=abc'),
        'artist/track',
      );
    });

    test('keeps unparseable input as is', () {
      expect(scLinkLabel(' soundcloud.com '), 'soundcloud.com');
    });
  });

  group('SchemeRegistrar', () {
    final registrar = SchemeRegistrar(
      executable: '/opt/Wave form/waveform_app',
      talker: Talker(),
    );

    test('windows command quotes executable and link', () {
      expect(registrar.windowsCommand, '"/opt/Wave form/waveform_app" "%1"');
    });

    test('desktop entry declares the scheme handler', () {
      expect(registrar.desktopEntry, contains('Exec="/opt/Wave form/'));
      expect(registrar.desktopEntry, contains('%u'));
      expect(
        registrar.desktopEntry,
        contains('MimeType=x-scheme-handler/waveform;'),
      );
    });
  });
}
