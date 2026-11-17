import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models/watch_together.dart';
import 'package:PiliPlus/services/watch_together/client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

void main() {
  test('Dart transport handshakes, sends intent once and restores the latest snapshot', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    final received = <Map<String, dynamic>>[];
    var revision = 1;
    final subscription = server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((dynamic raw) {
        final message = jsonDecode(raw as String) as Map<String, dynamic>;
        received.add(message);
        switch (message['type']) {
          case 'create':
          case 'resume':
            socket.add(
              jsonEncode({
                'type': 'welcome',
                'requestId': message['requestId'],
                'session': {
                  'roomCode': 'ABCDEFGH',
                  'memberId': 'a',
                  'resumeToken': 'test-session',
                },
                'state': roomJson(revision: ++revision),
              }),
            );
          case 'command':
            socket.add(
              jsonEncode({
                'type': 'ack',
                'requestId': message['requestId'],
                'state': roomJson(revision: ++revision),
              }),
            );
          case 'ping':
            socket.add(
              jsonEncode({
                'type': 'pong',
                'clientTimeMs': message['clientTimeMs'],
                'serverTimeMs': 100000,
              }),
            );
          case 'leave':
            socket.add(
              jsonEncode({'type': 'left', 'requestId': message['requestId']}),
            );
        }
      });
    });
    WatchSession? saved;
    final client = WatchTogetherClient(
      serverUrl: 'http://127.0.0.1:${server.port}',
      nickname: '测试',
      onSaveSession: (value) async {
        saved = value;
      },
    );
    addTearDown(() async {
      client.dispose();
      for (final socket in sockets) {
        await socket.close();
      }
      await subscription.cancel();
      await server.close(force: true);
    });
    await client.create();
    expect(client.connected, isTrue);
    expect(saved!.memberId, 'a');
    await client.command('seek', {'positionMs': 42000});
    expect(received.where((m) => m['type'] == 'command').length, 1);
    expect(received.firstWhere((m) => m['type'] == 'command')['mediaEpoch'], 1);
    sockets.last.add(
      jsonEncode({
        'type': 'state',
        'state': roomJson(revision: 20, playing: true),
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(client.room!.revision, 20);
    expect(
      received.where((m) => m['type'] == 'command').length,
      1,
      reason: 'Applying state must not echo user intent',
    );
    final disconnected = Completer<void>();
    client.addListener(() {
      if (client.connection == WatchConnection.reconnecting &&
          !disconnected.isCompleted) {
        disconnected.complete();
      }
    });
    await sockets.last.close();
    await disconnected.future.timeout(const Duration(seconds: 2));
    await client.retry();
    expect(client.connected, isTrue);
    expect(
      received.lastWhere((m) => m['type'] == 'resume')['resumeToken'],
      'test-session',
    );
    await client.leave();
    expect(client.joined, isFalse);
    expect(saved, isNull);
  });
}
