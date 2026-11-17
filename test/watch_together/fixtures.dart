import 'package:PiliPlus/models/watch_together.dart';
import 'package:PiliPlus/services/watch_together/client.dart';

const sampleVideo = WatchVideo(
  bvid: 'BV1xx411c7mD',
  cid: 12345,
  title: '周末的旅行 · 一起走过山间和海边',
  durationMs: 120000,
);

Map<String, dynamic> roomJson({
  int revision = 1,
  int epoch = 1,
  bool playing = false,
}) => {
  'roomCode': 'ABCDEFGH',
  'revision': revision,
  'mediaEpoch': epoch,
  'video': sampleVideo.toJson(),
  'positionMs': 30000,
  'updatedAtMs': 100000,
  'serverTimeMs': 100000,
  'rate': 1.0,
  'playing': playing,
  'desiredPlaying': playing,
  'hostId': 'a',
  'lastAction': 'status',
  'updatedBy': 'a',
  'members': [
    {
      'id': 'a',
      'name': '小明',
      'connected': true,
      'ready': true,
      'buffering': false,
      'suspended': false,
    },
    {
      'id': 'b',
      'name': '小雨',
      'connected': true,
      'ready': true,
      'buffering': false,
      'suspended': false,
    },
  ],
  'messages': <Map<String, dynamic>>[],
};

class PreviewWatchClient extends WatchTogetherClient {
  PreviewWatchClient({
    this.previewRoom,
    this.phase = WatchConnection.connected,
    String server = 'https://watch.example.com',
  }) : super(serverUrl: server, nickname: '小明');

  WatchRoom? previewRoom;
  WatchConnection phase;
  @override
  WatchRoom? get room => previewRoom;
  @override
  bool get joined => previewRoom != null;
  @override
  bool get connected => joined && phase == WatchConnection.connected;
  @override
  WatchConnection get connection => phase;
  @override
  WatchSession? get session => joined
      ? const WatchSession(
          roomCode: 'ABCDEFGH',
          memberId: 'a',
          resumeToken: 'preview',
        )
      : null;
}
