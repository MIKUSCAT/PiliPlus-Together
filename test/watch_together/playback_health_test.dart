import 'package:PiliPlus/services/watch_together/playback_health.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a decoder diagnostic does not stop recovered buffered playback', () {
    final health = WatchPlaybackHealth()..recordError(1000);
    expect(health.update(nowMs: 1500, usable: false), isFalse);
    expect(health.failed, isFalse);
    expect(health.update(nowMs: 2500, usable: true), isFalse);
    expect(health.hasError, isFalse);
    expect(health.failed, isFalse);
  });

  test('a sustained failure is reported once even during an error burst', () {
    final health = WatchPlaybackHealth()..recordError(1000);
    for (var now = 1200; now < 4000; now += 200) {
      health.recordError(now);
      expect(health.update(nowMs: now, usable: false), isFalse);
    }
    expect(health.update(nowMs: 4000, usable: false), isTrue);
    expect(health.failed, isTrue);
    health.recordError(5000);
    expect(health.update(nowMs: 5000, usable: false), isFalse);
  });

  test(
    'native playback recovery clears a failure without rejoining the room',
    () {
      final health = WatchPlaybackHealth()
        ..recordError(1000)
        ..update(nowMs: 4000, usable: false);
      expect(health.update(nowMs: 4500, usable: true), isTrue);
      expect(health.failed, isFalse);
      expect(health.hasError, isFalse);
      expect(health.update(nowMs: 5000, usable: true), isFalse);
      health.recordError(6000);
      expect(health.update(nowMs: 6500, usable: false), isFalse);
    },
  );
}
