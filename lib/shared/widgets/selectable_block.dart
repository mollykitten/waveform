import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../url_share.dart';

/// Выделяемый текст: мышью, двойным кликом, ⌘C/Ctrl+C и через right-click
/// «Copy». Свой Shortcuts на копирование — внешний Focus в AppShell глотает
/// non-character клавиши раньше, чем они доходят до DefaultTextEditingShortcuts.
class SelectableBlock extends StatelessWidget {
  const SelectableBlock({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyC, meta: true):
            CopySelectionTextIntent.copy,
        SingleActivator(LogicalKeyboardKey.keyC, control: true):
            CopySelectionTextIntent.copy,
      },
      child: SelectionArea(child: child),
    );
  }
}

/// Текст с кликабельными http(s)-ссылками (открываются в браузере).
/// Предназначен для использования внутри [SelectableBlock].
class LinkifiedText extends StatefulWidget {
  const LinkifiedText(this.text, {super.key, this.style, this.linkColor});

  final String text;
  final TextStyle? style;
  final Color? linkColor;

  @override
  State<LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<LinkifiedText> {
  static final _urlRe = RegExp(r'https?://[^\s<>()]+[^\s<>().,;:!?"\x27]');

  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _urlRe.allMatches(widget.text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: widget.text.substring(last, m.start)));
      }
      final url = m.group(0)!;
      final r = TapGestureRecognizer()..onTap = () => openExternalUrl(url);
      _recognizers.add(r);
      spans.add(
        TextSpan(
          text: url,
          recognizer: r,
          mouseCursor: SystemMouseCursors.click,
          style: TextStyle(
            color: widget.linkColor,
            decoration: TextDecoration.underline,
            decorationColor: widget.linkColor,
          ),
        ),
      );
      last = m.end;
    }
    if (last < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(last)));
    }
    return Text.rich(TextSpan(children: spans), style: widget.style);
  }
}
