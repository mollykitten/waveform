import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:waveform_app/app/shortcut_bindings.dart';
import 'package:waveform_app/shared/intents.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/shared/widgets/selectable_block.dart';

const _title = 'Музыка — Café 🎧';
const _description =
    'Первая строка 🎵\n'
    'https://example.com/путь?q=café&x=1\n'
    'Последняя строка — e\u0301, 日本語.';

void main() {
  String? clipboard;
  var clipboardWrites = 0;

  setUp(() {
    clipboard = null;
    clipboardWrites = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          switch (call.method) {
            case 'Clipboard.setData':
              clipboard = (call.arguments as Map)['text'] as String;
              clipboardWrites++;
              return null;
            case 'Clipboard.getData':
              return <String, String?>{'text': clipboard};
            case 'Clipboard.hasStrings':
              return <String, bool>{'value': clipboard != null};
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  final desktopPlatforms = TargetPlatformVariant({
    TargetPlatform.macOS,
    TargetPlatform.windows,
  });

  testWidgets(
    'mouse drag copies exact Unicode title through shell shortcut guard',
    (tester) async {
      final effects = <String>[];
      await _pumpSelection(tester, const Text(_title), effects);
      final paragraph = _paragraph(tester);
      await _selectAllByMouse(tester, paragraph);
      await _copy(tester);
      expect(clipboard, _title);
      expect(clipboardWrites, 1);
      expect(effects, isEmpty);
    },
    variant: desktopPlatforms,
  );

  testWidgets('double click selects a word, not the entire title', (
    tester,
  ) async {
    final effects = <String>[];
    await _pumpSelection(tester, const Text(_title), effects);
    final paragraph = _paragraph(tester);
    final box = paragraph
        .getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 6),
        )
        .first;
    final word = paragraph.localToGlobal(box.toRect().center);
    await tester.tapAt(word, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(word, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    await _copy(tester);
    expect(clipboard, 'Музыка');
    expect(effects, isEmpty);
  }, variant: desktopPlatforms);

  testWidgets(
    'mouse drag preserves multiline description and link in clipboard',
    (tester) async {
      final effects = <String>[];
      await _pumpSelection(tester, const LinkifiedText(_description), effects);
      await _selectAllByMouse(tester, _paragraph(tester));
      await _copy(tester);
      expect(clipboard, _description);
      expect(clipboardWrites, 1);
      expect(effects, isEmpty);
    },
    variant: desktopPlatforms,
  );

  testWidgets('context Copy preserves selected multiline text', (tester) async {
    final effects = <String>[];
    await _pumpSelection(tester, const LinkifiedText(_description), effects);
    final paragraph = _paragraph(tester);
    await _selectAllByMouse(tester, paragraph);
    final mouse = await tester.startGesture(
      paragraph.localToGlobal(const Offset(15, 5)),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await mouse.up();
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(clipboard, _description);
    expect(clipboardWrites, 1);
    expect(effects, isEmpty);
  }, variant: desktopPlatforms);

  testWidgets(
    'copy without selection does not overwrite clipboard or trigger actions',
    (tester) async {
      final effects = <String>[];
      await _pumpSelection(tester, const Text(_title), effects);
      clipboard = 'keep previous clipboard';
      await tester.tapAt(
        _paragraph(tester).localToGlobal(const Offset(5, 5)),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      await _copy(tester);
      expect(clipboard, 'keep previous clipboard');
      expect(clipboardWrites, 0);
      expect(effects, isEmpty);
    },
    variant: desktopPlatforms,
  );
  testWidgets('clearing a selection never copies stale text', (tester) async {
    final effects = <String>[];
    await _pumpSelection(tester, const Text(_title), effects);
    final paragraph = _paragraph(tester);
    await _selectAllByMouse(tester, paragraph);
    await _copy(tester);
    expect(clipboard, _title);
    clipboard = 'new clipboard from another app';
    clipboardWrites = 0;
    await tester.pump(const Duration(seconds: 1));
    await tester.tapAt(
      paragraph.localToGlobal(const Offset(5, 5)),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    await _copy(tester);
    expect(clipboard, 'new clipboard from another app');
    expect(clipboardWrites, 0);
    expect(effects, isEmpty);
  }, variant: desktopPlatforms);

  testWidgets(
    'shell playback shortcut still works after selecting text',
    (tester) async {
      final effects = <String>[];
      await _pumpSelection(tester, const Text(_title), effects);
      await _selectAllByMouse(tester, _paragraph(tester));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(effects, ['play/pause']);
    },
    variant: desktopPlatforms,
  );

  testWidgets('copy preserves a whitespace-only selection', (tester) async {
    final effects = <String>[];
    await _pumpSelection(tester, const Text('a  b'), effects);
    final paragraph = _paragraph(tester);
    final mouse = await tester.startGesture(
      paragraph.localToGlobal(
        paragraph.getOffsetForCaret(const TextPosition(offset: 1), Rect.zero) +
            const Offset(0, 5),
      ),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveTo(
      paragraph.localToGlobal(
        paragraph.getOffsetForCaret(const TextPosition(offset: 3), Rect.zero) +
            const Offset(0, 5),
      ),
    );
    await mouse.up();
    await tester.pumpAndSettle();
    await _copy(tester);
    expect(clipboard, '  ');
    expect(clipboardWrites, 1);
    expect(effects, isEmpty);
  }, variant: desktopPlatforms);

  testWidgets(
    'modified shell copy-link shortcut is not intercepted',
    (tester) async {
      final effects = <String>[];
      await _pumpSelection(tester, const Text(_title), effects);
      await _selectAllByMouse(tester, _paragraph(tester));
      final modifier =
          debugDefaultTargetPlatformOverride == TargetPlatform.macOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(modifier);
      await tester.pump();
      expect(effects, ['copy link']);
      expect(clipboardWrites, 0);
    },
    variant: desktopPlatforms,
  );

  testWidgets('LinkifiedText splits urls into tappable spans', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SelectableBlock(
            child: LinkifiedText(
              'buy: https://example.com/x, free dl https://a.b/c.',
            ),
          ),
        ),
      ),
    );

    final rich = tester.widget<RichText>(
      find.descendant(
        of: find.byType(LinkifiedText),
        matching: find.byType(RichText),
      ),
    );
    final links = <String>[];
    rich.text.visitChildren((span) {
      if (span is TextSpan && span.recognizer is TapGestureRecognizer) {
        links.add(span.text!);
      }
      return true;
    });
    expect(links, ['https://example.com/x', 'https://a.b/c']);
    expect(
      rich.text.toPlainText(),
      'buy: https://example.com/x, free dl https://a.b/c.',
    );
    expect(find.byType(SelectionArea), findsOneWidget);
  });
}

Future<void> _pumpSelection(
  WidgetTester tester,
  Widget child,
  List<String> effects,
) async {
  // Reproduce AppShell's swallowing outer Focus and real shortcut map without
  // starting audio, network, storage or the native window manager in a widget test.
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Focus(
          canRequestFocus: false,
          onKeyEvent: (_, event) => event.character?.isNotEmpty ?? false
              ? KeyEventResult.ignored
              : KeyEventResult.handled,
          child: Shortcuts(
            shortcuts: buildShortcuts(
              isMac: debugDefaultTargetPlatformOverride == TargetPlatform.macOS,
              location: '/track/qa',
            ),
            child: Actions(
              actions: <Type, Action<Intent>>{
                CopyLinkIntent: CallbackAction<CopyLinkIntent>(
                  onInvoke: (_) => effects.add('copy link'),
                ),
                PlayPauseIntent: CallbackAction<PlayPauseIntent>(
                  onInvoke: (_) => effects.add('play/pause'),
                ),
                NavigateToPlayingIntent:
                    CallbackAction<NavigateToPlayingIntent>(
                      onInvoke: (_) => effects.add('navigate'),
                    ),
                PlayPageTrackIntent: CallbackAction<PlayPageTrackIntent>(
                  onInvoke: (_) => effects.add('play page'),
                ),
              },
              child: Focus(
                autofocus: true,
                child: Center(
                  child: SizedBox(
                    width: 600,
                    child: SelectableBlock(child: child),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

RenderParagraph _paragraph(WidgetTester tester) =>
    tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.byType(SelectableBlock),
        matching: find.byType(RichText),
      ),
    );

Future<void> _selectAllByMouse(
  WidgetTester tester,
  RenderParagraph paragraph,
) async {
  final mouse = await tester.startGesture(
    paragraph.localToGlobal(const Offset(0, 1)),
    kind: PointerDeviceKind.mouse,
  );
  await mouse.moveTo(
    paragraph.localToGlobal(
      Offset(paragraph.size.width, paragraph.size.height - 1),
    ),
  );
  await mouse.up();
  await tester.pumpAndSettle();
}

Future<void> _copy(WidgetTester tester) async {
  final modifier = debugDefaultTargetPlatformOverride == TargetPlatform.macOS
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
  await tester.sendKeyUpEvent(modifier);
  await tester.pumpAndSettle();
}
