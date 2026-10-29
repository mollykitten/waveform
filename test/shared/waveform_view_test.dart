import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/shared/widgets/waveform_view.dart';

void main() {
  Future<List<double>> pump(WidgetTester tester) async {
    final seeks = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            child: WaveformView(bars: List.filled(40, 0.5), onSeek: seeks.add),
          ),
        ),
      ),
    );
    return seeks;
  }

  testWidgets('drag commits exactly one seek on release', (tester) async {
    final seeks = await pump(tester);
    final g = await tester.startGesture(
      tester.getTopLeft(find.byType(WaveformView)) + const Offset(40, 30),
    );
    await g.moveBy(const Offset(60, 0));
    await g.moveBy(const Offset(100, 0));
    await g.moveBy(const Offset(50, 0));
    expect(seeks, isEmpty);
    await g.up();
    await tester.pump();
    expect(seeks, hasLength(1));
    expect(seeks.single, closeTo(0.625, 0.05));
  });

  testWidgets('plain tap seeks once', (tester) async {
    final seeks = await pump(tester);
    await tester.tapAt(
      tester.getTopLeft(find.byType(WaveformView)) + const Offset(100, 30),
    );
    await tester.pump();
    expect(seeks, hasLength(1));
    expect(seeks.single, closeTo(0.25, 0.01));
  });
}
