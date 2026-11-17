import 'package:PiliPlus/models/watch_together.dart';
import 'package:PiliPlus/services/watch_together/client.dart';
import 'package:PiliPlus/services/watch_together/sync_clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

void main() {
  test('timeline accounts for rate, server time and end-of-video bounds', () {
    final json = roomJson(playing: true)..['rate'] = 2;
    final room = WatchRoom.fromJson(json);
    expect(room.positionAt(103000), 36000);
    expect(room.positionAt(99900), 30000);
    expect(room.positionAt(500000), 120000);
    expect(WatchRoom.fromJson(roomJson()).positionAt(110000), 30000);
  });

  test(
    'clock prefers low-latency samples and compensates half a round trip',
    () {
      final clock = WatchSyncClock();
      clock.record(sentAtMs: 1000, receivedAtMs: 1100, serverTimeMs: 5050);
      expect(clock.serverNow(1200), 5200);
      expect(clock.latencyMs, 50);
      clock.record(sentAtMs: 2000, receivedAtMs: 2900, serverTimeMs: 6600);
      expect(clock.serverNow(3000), 7000);
      clock.record(sentAtMs: 4000, receivedAtMs: 3999, serverTimeMs: 8000);
      expect(clock.serverNow(5000), 9000);
    },
  );

  test(
    'natural decoder jitter does not repeatedly seek, explicit seeks do',
    () {
      bool correct(
        int actual, {
        bool force = false,
        bool playing = true,
        int elapsed = 5000,
      }) => shouldCorrectWatchPosition(
        targetMs: 30000,
        actualMs: actual,
        playing: playing,
        force: force,
        millisecondsSinceSeek: elapsed,
      );
      expect(correct(29800), isFalse);
      expect(correct(28500, elapsed: 500), isFalse);
      expect(correct(28500, elapsed: 2500), isTrue);
      expect(correct(29500, playing: false), isTrue);
      expect(correct(29000, force: true, elapsed: 0), isTrue);
    },
  );

  test(
    'connection settings support HTTPS and preserve reverse-proxy prefixes',
    () {
      expect(
        WatchTogetherClient.socketUri('https://watch.example.com').toString(),
        'wss://watch.example.com/ws',
      );
      expect(
        WatchTogetherClient.socketUri('https://example.com/together/')
            .toString(),
        'wss://example.com/together/ws',
      );
      expect(
        WatchTogetherClient.socketUri('ws://127.0.0.1:3000/ws').toString(),
        'ws://127.0.0.1:3000/ws',
      );
      for (final invalid in [
        'watch.example.com',
        'file:///tmp/server',
        'https://user:secret@example.com',
        'https://example.com?token=x',
      ]) {
        expect(
          () => WatchTogetherClient.socketUri(invalid),
          throwsA(isA<WatchTogetherException>()),
        );
      }
    },
  );

  test(
    'room code accepts a pasted invitation and rejects ambiguous/invalid codes',
    () {
      expect(WatchTogetherClient.parseRoomCode('abcd efgh'), 'ABCDEFGH');
      expect(
        WatchTogetherClient.parseRoomCode(
          '一起来看\n房间码：ABCD EFGH\n服务地址：https://example.com',
        ),
        'ABCDEFGH',
      );
      expect(
        () => WatchTogetherClient.parseRoomCode('123'),
        throwsA(isA<WatchTogetherException>()),
      );
      expect(
        () => WatchTogetherClient.parseRoomCode('I0O1ABCD'),
        throwsA(isA<WatchTogetherException>()),
      );
    },
  );

  test('an out-of-order snapshot cannot rewind the room revision or media', () {
    final client = WatchTogetherClient(serverUrl: '', nickname: '测试');
    addTearDown(client.dispose);
    client.acceptState(roomJson(revision: 10, epoch: 3));
    client.acceptState(roomJson(revision: 8, epoch: 2));
    expect(client.room!.revision, 10);
    expect(client.room!.mediaEpoch, 3);
  });

  test('paused decoder buffer recovery waits for real cache, including fast playback and EOF', () {
    bool buffered(int end, {int position = 1000, double rate = 1}) =>
        hasWatchBufferForResume(
          positionMs: position,
          bufferedMs: end,
          durationMs: 100000,
          rate: rate,
        );
    expect(buffered(0), isFalse);
    expect(buffered(1250), isFalse);
    expect(buffered(16000), isTrue);
    expect(buffered(5000, rate: 3), isFalse);
    expect(buffered(8000, rate: 3), isTrue);
    expect(buffered(99950, position: 99500), isTrue);
    expect(buffered(100000, position: 100000), isTrue);
  });
}
