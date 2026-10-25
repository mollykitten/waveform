import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/shared/widgets/selectable_block.dart';

void main() {
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
