import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/recommendations/models.dart';

void main() {
  test('failures carry safe fixed messages', () {
    for (final failure in WaveFailure.values) {
      expect(failure.toString(), failure.message);
      expect(failure.message, isNot(contains('Exception')));
    }
  });
}
