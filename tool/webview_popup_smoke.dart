// Account-free integration probe of the actual vendored desktop plugin.
// Launch with Dart MCP launch_app(target: 'tool/webview_popup_smoke.dart').
// This is NOT evidence of Google login support. Uses loopback pages only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/material.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (runWebViewTitleBarWidget(args)) return;
  runApp(const MaterialApp(home: Scaffold(body: Text('Local popup probe'))));
  try {
    await probe();
    debugPrint('POPUP_SMOKE_RESULT PASS');
  } catch (error, stack) {
    debugPrint('POPUP_SMOKE_RESULT FAIL $error\n$stack');
  }
}

Future<void> probe() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final origin = 'http://127.0.0.1:${server.port}';
  final windows = <Webview>[];
  unawaited(
    server.forEach((request) async {
      request.response.headers.contentType = ContentType.html;
      request.response.write('''
<!doctype html><title>Local popup probe</title><h1>No account or secrets</h1>
<script>
window.replies=[];
addEventListener('message',e=>replies.push(e.data));
</script>
''');
      await request.response.close();
    }),
  );

  Future<bool> evaluate(Webview view, String script) async {
    final raw = await view.evaluateJavaScript('JSON.stringify($script)');
    if (raw == null) return false;
    dynamic decoded = jsonDecode(raw);
    // The plugin wraps the JS result once more on some platforms.
    if (decoded is String) decoded = jsonDecode(decoded);
    return decoded == true;
  }

  Future<void> waitFor(Webview view, String script, String name) async {
    for (var attempt = 0; attempt < 60; attempt++) {
      if (await evaluate(view, script)) {
        debugPrint('POPUP_SMOKE PASS $name');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError(name);
  }

  Future<Webview> create({bool hidden = false}) async {
    final view = await WebviewWindow.create(
      configuration: CreateConfiguration(
        title: 'Local popup probe (no account)',
        windowWidth: 640,
        windowHeight: 520,
        hidden: hidden,
      ),
    );
    windows.add(view);
    view.launch('$origin/parent');
    await waitFor(view, 'Array.isArray(window.replies)', 'page ready');
    return view;
  }

  try {
    final parent = await create();
    await parent.evaluateJavaScript(
      "window.child=window.open('$origin/child','child');true",
    );
    await waitFor(
      parent,
      'child!==null && child.document.title==="Local popup probe"'
          ' && child.opener===window',
      'real child with opener; parent page survives',
    );
    await parent.evaluateJavaScript(
      "child.eval(\"opener.postMessage('reply','*');"
      "document.cookie='waveform_popup_probe=shared;path=/'\");true",
    );
    await waitFor(parent, 'replies.includes("reply")', 'postMessage delivered');
    final cookies = await parent.getAllCookies();
    if (!cookies.any(
      (cookie) =>
          cookie.name == 'waveform_popup_probe' && cookie.value == 'shared',
    )) {
      throw StateError('child cookie absent from parent native store');
    }
    debugPrint('POPUP_SMOKE PASS shared native cookie store');
    await parent.evaluateJavaScript(
      "document.cookie='waveform_popup_probe=;Max-Age=0;path=/';true",
    );
    await parent.evaluateJavaScript('child.close();true');
    await waitFor(parent, 'child.closed', 'child closes itself');

    // Leave a descendant alive, then close the actual Flutter-hosted parent.
    await parent.evaluateJavaScript(
      "window.child=window.open('$origin/child','close-with-parent');true",
    );
    await waitFor(parent, 'child!==null', 'second child created');
    parent.close();
    await parent.onClose.timeout(const Duration(seconds: 10));
    windows.remove(parent);
    debugPrint('POPUP_SMOKE PASS parent close callback');
    // Native child window absence must still be inspected independently.

    final hidden = await create(hidden: true);
    await hidden.evaluateJavaScript(
      "window.open('$origin/hidden-target','hidden');true",
    );
    await waitFor(
      hidden,
      'location.pathname==="/hidden-target"',
      'hidden sync retains same-view navigation (no returned child)',
    );
    debugPrint('POPUP_SMOKE NOTE visually verify no visible hidden popup');
  } finally {
    for (final view in windows) {
      view.close();
      await view.onClose.timeout(const Duration(seconds: 10));
    }
    await server.close(force: true);
  }
}
