import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/app/app.dart';
import 'package:waveform_app/main.dart' as app;

void main() {
  test('entrypoint accepts native engine arguments', () {
    expect(app.main, isA<Future<void> Function(List<String>)>());
  });

  testWidgets('WebView titlebar does not initialize the primary application', (
    tester,
  ) async {
    const channel = MethodChannel('window_manager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      fail('Secondary engine initialized the main window: ${call.method}');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await app.main(['web_view_title_bar', '42', '7']);
    await tester.pump();

    expect(find.byType(TitleBarWebViewState), findsOneWidget);
    expect(find.byType(WaveformApp), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
