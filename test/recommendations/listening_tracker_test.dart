import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/recommendations/listening_event.dart';
import 'package:waveform_app/core/recommendations/listening_tracker.dart';

void main() {
  late int now;
  late List<ListeningEvent> events;
  late ListeningTracker tracker;
  setUp(() {
    now = 0;
    events = [];
    tracker = ListeningTracker(monotonicMs: () => now, onEvent: events.add);
    tracker.setIdentity('123');
    tracker.start(trackId: '1', durationMs: 100000);
    tracker.setPlaying(true);
  });
  void hear(int seconds, {int start = 0}) {
    for (var i = 1; i <= seconds; i++) {
      now += 1000;
      tracker.sample(positionMs: start + i * 1000, playing: true);
    }
  }

  test('30 seconds of advancing audio produces 30 seconds heard', () {
    hear(30);
    tracker.finish(ListeningTransitionCause.manualNext);
    expect(events.single.heardMs, 30000);
    expect(events.single.evidence, ListeningEvidence.neutral);
  });
  test('forward/backward seek jumps and stalled audio do not count', () {
    hear(5);
    tracker.seek(80000);
    now += 1000;
    tracker.sample(positionMs: 80000, playing: true);
    tracker.seek(10000);
    hear(5, start: 10000);
    tracker.finish(ListeningTransitionCause.manualNext);
    expect(events.single.heardMs, 10000);
    expect(events.single.seekCount, 2);
    expect(events.single.evidence, ListeningEvidence.neutral);
  });
  test('pause, buffering and unsampled large jumps are excluded', () {
    hear(5);
    tracker.setPlaying(false);
    now += 10000;
    tracker.sample(positionMs: 15000, playing: false);
    tracker.setPlaying(true);
    now += 1000;
    tracker.sample(positionMs: 15000, playing: true);
    now += 10000;
    tracker.sample(positionMs: 80000, playing: true);
    tracker.finish(ListeningTransitionCause.stopped);
    expect(events.single.heardMs, 5000);
  });
  test('only credible manual early next is negative evidence', () {
    hear(6);
    tracker.finish(ListeningTransitionCause.manualNext);
    expect(events.single.evidence, ListeningEvidence.negative);
    tracker.start(trackId: '2', durationMs: 100000);
    tracker.setPlaying(true);
    hear(6);
    tracker.finish(ListeningTransitionCause.unplayable);
    expect(events.last.evidence, ListeningEvidence.neutral);
  });
  test('crossfade completion keeps actual heard duration', () {
    hear(90);
    tracker.finish(ListeningTransitionCause.crossfadeCompletion);
    expect(events.single.heardMs, 90000);
    expect(events.single.durationMs, 100000);
    expect(events.single.evidence, ListeningEvidence.positive);
  });
  test('long actual hearing remains positive when the app closes', () {
    hear(90);
    tracker.finish(ListeningTransitionCause.disposal);
    expect(events.single.evidence, ListeningEvidence.positive);
  });
  test('same track replay creates a new session', () {
    hear(6);
    tracker.finish(ListeningTransitionCause.manualRestart);
    tracker.start(trackId: '1', durationMs: 100000);
    tracker.finish(ListeningTransitionCause.disposal);
    expect(events[0].sessionId, isNot(events[1].sessionId));
    expect(events[0].evidence, ListeningEvidence.neutral);
    expect(events[1].heardMs, 0);
  });
  test('identity loading and account switches never reattribute hearing', () {
    hear(6);
    tracker.setIdentity(null);
    hear(4, start: 6000);
    tracker.setIdentity('456');
    tracker.setPlaying(true);
    hear(6, start: 10000);
    tracker.finish(ListeningTransitionCause.manualNext);
    expect(events.map((e) => e.identity), ['123', '456']);
    expect(events.map((e) => e.heardMs), [6000, 6000]);
    expect(events.first.cause, ListeningTransitionCause.accountChange);
  });
}
