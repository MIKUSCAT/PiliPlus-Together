import 'dart:math' as math;

class WatchVideo {
  const WatchVideo({
    required this.bvid,
    required this.cid,
    required this.title,
    this.kind = 'ugc',
    this.cover = '',
    this.durationMs = 0,
    this.epId,
    this.seasonId,
    this.pgcType,
  });

  final String kind;
  final String bvid;
  final int cid;
  final String title;
  final String cover;
  final int durationMs;
  final int? epId;
  final int? seasonId;
  final int? pgcType;

  String get key => '$kind:$bvid:$cid:${epId ?? 0}';

  factory WatchVideo.fromJson(Map<String, dynamic> json) => WatchVideo(
    kind: json['kind'] as String,
    bvid: json['bvid'] as String,
    cid: (json['cid'] as num).toInt(),
    title: json['title'] as String,
    cover: json['cover'] as String? ?? '',
    durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
    epId: (json['epId'] as num?)?.toInt(),
    seasonId: (json['seasonId'] as num?)?.toInt(),
    pgcType: (json['pgcType'] as num?)?.toInt(),
  );

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'bvid': bvid,
    'cid': cid,
    'title': title,
    'cover': cover,
    'durationMs': durationMs,
    'epId': ?epId,
    'seasonId': ?seasonId,
    'pgcType': ?pgcType,
  };
}

class WatchMember {
  const WatchMember({
    required this.id,
    required this.name,
    this.connected = true,
    this.ready = false,
    this.buffering = false,
    this.suspended = false,
    this.error,
  });

  final String id;
  final String name;
  final bool connected;
  final bool ready;
  final bool buffering;
  final bool suspended;
  final String? error;

  String get status => !connected
      ? '正在重连'
      : error != null
      ? '暂时无法播放'
      : suspended
      ? '暂时离开'
      : buffering
      ? '正在缓冲'
      : !ready
      ? '正在准备'
      : '已准备好';

  factory WatchMember.fromJson(Map<String, dynamic> json) => WatchMember(
    id: json['id'] as String,
    name: json['name'] as String,
    connected: json['connected'] == true,
    ready: json['ready'] == true,
    buffering: json['buffering'] == true,
    suspended: json['suspended'] == true,
    error: json['error'] as String?,
  );
}

class WatchMessage {
  const WatchMessage({
    required this.id,
    required this.memberId,
    required this.name,
    required this.text,
    required this.sentAtMs,
  });

  final String id;
  final String memberId;
  final String name;
  final String text;
  final int sentAtMs;

  factory WatchMessage.fromJson(Map<String, dynamic> json) => WatchMessage(
    id: json['id'] as String,
    memberId: json['memberId'] as String,
    name: json['name'] as String,
    text: json['text'] as String,
    sentAtMs: (json['sentAtMs'] as num).toInt(),
  );
}

class WatchRoom {
  const WatchRoom({
    required this.code,
    required this.revision,
    required this.mediaEpoch,
    required this.updatedAtMs,
    required this.serverTimeMs,
    required this.hostId,
    this.video,
    this.positionMs = 0,
    this.rate = 1,
    this.playing = false,
    this.desiredPlaying = false,
    this.lastAction = '',
    this.updatedBy,
    this.members = const [],
    this.messages = const [],
  });

  final String code;
  final int revision;
  final int mediaEpoch;
  final WatchVideo? video;
  final int positionMs;
  final int updatedAtMs;
  final int serverTimeMs;
  final double rate;
  final bool playing;
  final bool desiredPlaying;
  final String hostId;
  final String lastAction;
  final String? updatedBy;
  final List<WatchMember> members;
  final List<WatchMessage> messages;

  String get displayCode =>
      code.length == 8 ? '${code.substring(0, 4)} ${code.substring(4)}' : code;

  int positionAt(int serverNowMs) {
    final elapsed = playing ? math.max(0, serverNowMs - updatedAtMs) * rate : 0;
    final position = math.max(0, (positionMs + elapsed).round());
    final duration = video?.durationMs ?? 0;
    return duration > 0 ? math.min(duration, position) : position;
  }

  String get status {
    final alone = members.length < 2;
    if (members.any((m) => !m.connected)) {
      return alone ? '正在重新连接' : '等待对方重新连接';
    }
    if (video == null) return alone ? '选一个视频，可以先看' : '选一个视频，一起看吧';
    if (members.any((m) => m.error != null)) return '等待视频准备就绪';
    if (members.any((m) => m.suspended)) {
      return alone ? '等你回来继续' : '等你回来，一起继续';
    }
    if (members.any((m) => m.buffering)) {
      return alone ? '正在缓冲' : '等待缓冲，一起继续';
    }
    if (members.any((m) => !m.ready)) {
      return alone ? '正在准备视频' : '正在准备同一个画面';
    }
    if (alone && playing) return '正在播放，等对方加入';
    return playing ? '正在一起看' : '已暂停，等你继续';
  }

  factory WatchRoom.fromJson(Map<String, dynamic> json) => WatchRoom(
    code: json['roomCode'] as String,
    revision: (json['revision'] as num).toInt(),
    mediaEpoch: (json['mediaEpoch'] as num).toInt(),
    video: json['video'] == null
        ? null
        : WatchVideo.fromJson(json['video'] as Map<String, dynamic>),
    positionMs: (json['positionMs'] as num).round(),
    updatedAtMs: (json['updatedAtMs'] as num).toInt(),
    serverTimeMs: (json['serverTimeMs'] as num).toInt(),
    rate: (json['rate'] as num).toDouble(),
    playing: json['playing'] == true,
    desiredPlaying: json['desiredPlaying'] == true,
    hostId: json['hostId'] as String,
    lastAction: json['lastAction'] as String? ?? '',
    updatedBy: json['updatedBy'] as String?,
    members: (json['members'] as List)
        .map((m) => WatchMember.fromJson(m as Map<String, dynamic>))
        .toList(growable: false),
    messages: (json['messages'] as List? ?? const [])
        .map((m) => WatchMessage.fromJson(m as Map<String, dynamic>))
        .toList(growable: false),
  );
}

class WatchSession {
  const WatchSession({
    required this.roomCode,
    required this.memberId,
    required this.resumeToken,
  });

  final String roomCode;
  final String memberId;
  final String resumeToken;

  factory WatchSession.fromJson(Map<String, dynamic> json) => WatchSession(
    roomCode: json['roomCode'] as String,
    memberId: json['memberId'] as String,
    resumeToken: json['resumeToken'] as String,
  );

  Map<String, dynamic> toJson() => {
    'roomCode': roomCode,
    'memberId': memberId,
    'resumeToken': resumeToken,
  };
}
