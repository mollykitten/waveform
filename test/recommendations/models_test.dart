import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/recommendations/models.dart';

void main() {
  test('boundedText strips links and control characters', () {
    expect(
      boundedText('see https://private.invalid/x now\n\u0007ok', 100),
      'see  now  ok',
    );
  });

  test('boundedText limits by code points', () {
    expect(boundedText('a' * 100, 10), 'a' * 10);
    expect(boundedText('🎵' * 5, 3), '🎵🎵🎵');
  });

  test('failures carry safe fixed messages', () {
    for (final failure in WaveFailure.values) {
      expect(failure.toString(), failure.message);
      expect(failure.message, isNot(contains('Exception')));
    }
  });
}
