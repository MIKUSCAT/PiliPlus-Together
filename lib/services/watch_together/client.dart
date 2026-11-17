import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:PiliPlus/models/watch_together.dart';
import 'package:PiliPlus/services/watch_together/sync_clock.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

enum WatchConnection { disconnected, connecting, connected, reconnecting }

class WatchTogetherException implements Exception {
  const WatchTogetherException(this.message, [this.code = 'connection_failed']);
  final String message;
  final String code;
  @override
  String toString() => message;
}

class WatchTogetherClient extends ChangeNotifier {
  WatchTogetherClient({
    required this._serverUrl,
    required this._nickname,
    this.savedSession,
    this.onSaveSession,
  });

  String _serverUrl;
  String _nickname;
  final Future<void> Function(WatchSession? session)? onSaveSession;
  WatchSession? savedSession;
  WatchSession? _session;
  WatchRoom? _room;
  WatchConnection _connection = WatchConnection.disconnected;
  String? _error;
  final WatchSyncClock clock = WatchSyncClock();
  final _elapsed = Stopwatch()..start();
  final int _origin = DateTime.now().millisecondsSinceEpoch;
  final Random _random = Random.secure();
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeat;
  Timer? _reconnect;
  int _attempt = 0;
  int _generation = 0;
  int _lastReceived = 0;
  int _serial = 0;
  bool _intentionalClose = false;
  bool _disposed = false;
  final Map<String, Completer<void>> _pending = {};

  String get serverUrl => _serverUrl;
  String get nickname => _nickname;
  WatchSession? get session => _session;
  WatchRoom? get room => _room;
  WatchConnection get connection => _connection;
  String? get error => _error;
  bool get joined => _session != null;
  bool get connected => _connection == WatchConnection.connected;
  bool get busy => _connection == WatchConnection.connecting;
  int get localNowMs => _origin + _elapsed.elapsedMilliseconds;
  int get serverNowMs => clock.serverNow(localNowMs);
  bool get isHost => _session != null && _room?.hostId == _session!.memberId;

  static Uri socketUri(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        !['https', 'http', 'wss', 'ws'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const WatchTogetherException(
        '请输入完整的服务地址，例如 https://watch.example.com',
        'invalid_url',
      );
    }
    final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    return uri.replace(
      scheme: uri.scheme == 'https' || uri.scheme == 'wss' ? 'wss' : 'ws',
      path: path.endsWith('/ws') ? path : '$path/ws',
    );
  }

  static String parseRoomCode(String input) {
    final match = RegExp(
      r'房间码[：:]\s*([A-Z2-9\s-]+)',
      caseSensitive: false,
    ).firstMatch(input);
    final code = (match?.group(1) ?? input)
        .replaceAll(RegExp(r'[\s-]'), '')
        .toUpperCase();
    if (!RegExp(r'^[A-HJ-NP-Z2-9]{8}$').hasMatch(code)) {
      throw const WatchTogetherException('请输入 8 位房间码', 'invalid_room_code');
    }
    return code;
  }

  void configure({required String serverUrl, required String nickname}) {
    if (joined || busy) throw const WatchTogetherException('退出房间后可以修改连接设置');
    socketUri(serverUrl);
    final name = nickname.trim();
    if (name.isEmpty || name.length > 24) {
      throw const WatchTogetherException('昵称需要 1～24 个字符');
    }
    if (_serverUrl != serverUrl.trim()) {
      savedSession = null;
      unawaited(onSaveSession?.call(null));
    }
    _serverUrl = serverUrl.trim();
    _nickname = name;
    _error = null;
    notifyListeners();
  }

  Future<void> create() => _open({'type': 'create', 'name': _nickname});

  Future<void> join(String code) => _open({
    'type': 'join',
    'roomCode': parseRoomCode(code),
    'name': _nickname,
  });

  Future<void> resume() async {
    final previous = savedSession;
    if (previous == null) return;
    _session = previous;
    await _open({'type': 'resume', ...previous.toJson()}, reconnecting: true);
  }

  Future<void> _open(
    Map<String, dynamic> hello, {
    bool reconnecting = false,
  }) async {
    if (_disposed) return;
    final uri = socketUri(_serverUrl);
    if (!reconnecting && (joined || busy)) {
      throw const WatchTogetherException('已经加入房间');
    }
    _intentionalClose = false;
    _reconnect?.cancel();
    await _closeTransport();
    final generation = ++_generation;
    _connection = reconnecting
        ? WatchConnection.reconnecting
        : WatchConnection.connecting;
    _error = null;
    notifyListeners();
    try {
      final channel = _channel = WebSocketChannel.connect(uri);
      await channel.ready.timeout(const Duration(seconds: 10));
      if (_disposed || generation != _generation) return;
      _lastReceived = localNowMs;
      _subscription = channel.stream.listen(
        (dynamic data) {
          if (generation == _generation) _receive(data);
        },
        onError: (Object _) {
          if (generation == _generation) _lostConnection();
        },
        onDone: () {
          if (generation == _generation) _lostConnection();
        },
        cancelOnError: true,
      );
      await _request({...hello, 'protocol': 1});
      if (generation != _generation || _disposed) return;
      _attempt = 0;
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
        if (localNowMs - _lastReceived > 16000) {
          _lostConnection();
        } else {
          _sendPing();
        }
      });
      _sendPing();
    } catch (error) {
      if (generation != _generation || _disposed) return;
      final message = error is WatchTogetherException
          ? error.message
          : '暂时连不上一起看服务，请检查地址和网络';
      _error = message;
      _lostConnection();
      throw WatchTogetherException(message);
    }
  }

  void _receive(dynamic raw) {
    _lastReceived = localNowMs;
    try {
      if (raw is! String) throw const FormatException();
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final type = data['type'];
      final requestId = data['requestId'] as String?;
      if (type == 'pong') {
        clock.record(
          sentAtMs: (data['clientTimeMs'] as num).toInt(),
          receivedAtMs: localNowMs,
          serverTimeMs: (data['serverTimeMs'] as num).toInt(),
        );
        return;
      }
      if (type == 'welcome') {
        _session = savedSession = WatchSession.fromJson(
          data['session'] as Map<String, dynamic>,
        );
        _room = null;
        _connection = WatchConnection.connected;
        _error = null;
        unawaited(onSaveSession?.call(savedSession));
      }
      if (data['state'] case final Map<String, dynamic> state) {
        acceptState(state);
      }
      if (type == 'error') {
        final failure = WatchTogetherException(
          data['message'] as String,
          data['code'] as String,
        );
        _error = failure.message;
        _pending.remove(requestId)?.completeError(failure);
        if (const {
          'room_not_found',
          'invalid_session',
          'version_mismatch',
        }.contains(failure.code)) {
          _session = savedSession = null;
          _room = null;
          _intentionalClose = true;
          _connection = WatchConnection.disconnected;
          _reconnect?.cancel();
          _heartbeat?.cancel();
          unawaited(onSaveSession?.call(null));
          unawaited(_closeTransport());
        }
      } else if (type == 'welcome' || type == 'ack' || type == 'left') {
        _error = null;
        _pending.remove(requestId)?.complete();
      }
      notifyListeners();
    } catch (_) {
      _error = '服务返回了无法识别的数据，请确认服务版本';
      _lostConnection();
    }
  }

  @visibleForTesting
  void acceptState(Map<String, dynamic> json) {
    final incoming = WatchRoom.fromJson(json);
    if (_session != null && incoming.code != _session!.roomCode) return;
    final previous = _room;
    if (previous != null &&
        incoming.code == previous.code &&
        incoming.revision < previous.revision) {
      return;
    }
    clock.initialize(localNowMs, incoming.serverTimeMs);
    _room = incoming;
  }

  Future<void> _request(Map<String, dynamic> message) async {
    if (_channel == null) throw const WatchTogetherException('正在重新连接，请稍等');
    final id = '${_origin}_${++_serial}_${_random.nextInt(1 << 30)}';
    final completer = Completer<void>();
    _pending[id] = completer;
    try {
      _channel!.sink.add(jsonEncode({...message, 'requestId': id}));
      await completer.future.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      _lostConnection();
      throw const WatchTogetherException('连接有些慢，正在重新同步');
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> command(
    String action, [
    Map<String, dynamic> values = const {},
  ]) {
    if (!connected || _room == null) {
      return Future.error(const WatchTogetherException('正在重新连接，请稍等'));
    }
    return _request({
      'type': 'command',
      'action': action,
      'mediaEpoch': _room!.mediaEpoch,
      ...values,
    });
  }

  Future<void> selectVideo(
    WatchVideo video, {
    int positionMs = 0,
    bool playing = true,
  }) => command('select', {
    'video': video.toJson(),
    'positionMs': positionMs,
    'playing': playing,
  });

  void reportStatus({
    required int mediaEpoch,
    required bool ready,
    bool buffering = false,
    bool suspended = false,
    String? error,
    int durationMs = 0,
  }) {
    if (!connected) return;
    _channel?.sink.add(
      jsonEncode({
        'type': 'status',
        'mediaEpoch': mediaEpoch,
        'ready': ready,
        'buffering': buffering,
        'suspended': suspended,
        'error': error,
        'durationMs': durationMs,
      }),
    );
  }

  void requestSync() {
    if (connected) _channel?.sink.add('{"type":"sync"}');
  }

  void _sendPing() {
    _channel?.sink.add(
      jsonEncode({'type': 'ping', 'clientTimeMs': localNowMs}),
    );
  }

  void _lostConnection() {
    if (_disposed || _intentionalClose) return;
    _heartbeat?.cancel();
    for (final waiter in _pending.values.toList()) {
      if (!waiter.isCompleted) {
        waiter.completeError(const WatchTogetherException('连接暂时断开，正在恢复'));
      }
    }
    _pending.clear();
    if (!joined) {
      _connection = WatchConnection.disconnected;
    } else {
      _connection = WatchConnection.reconnecting;
      if (_reconnect?.isActive != true) {
        final seconds = min(10, 1 << min(_attempt++, 4));
        _reconnect = Timer(
          Duration(milliseconds: seconds * 1000 + _random.nextInt(300)),
          () {
            final session = _session;
            if (session != null && !_intentionalClose) {
              unawaited(
                _open({
                  'type': 'resume',
                  ...session.toJson(),
                }, reconnecting: true).catchError((Object _) {}),
              );
            }
          },
        );
      }
    }
    notifyListeners();
  }

  Future<void> retry() async {
    if (_session != null) {
      await _open({
        'type': 'resume',
        ..._session!.toJson(),
      }, reconnecting: true);
    } else {
      await resume();
    }
  }

  Future<void> leave() async {
    _intentionalClose = true;
    _reconnect?.cancel();
    _heartbeat?.cancel();
    if (connected) {
      try {
        await _request({'type': 'leave'}).timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    ++_generation;
    await _closeTransport();
    _session = savedSession = null;
    _room = null;
    _connection = WatchConnection.disconnected;
    _error = null;
    clock.reset();
    await onSaveSession?.call(null);
    notifyListeners();
  }

  Future<void> _closeTransport() async {
    _heartbeat?.cancel();
    await _subscription?.cancel();
    _subscription = null;
    final channel = _channel;
    _channel = null;
    unawaited(channel?.sink.close());
  }

  @override
  void dispose() {
    _disposed = _intentionalClose = true;
    ++_generation;
    _reconnect?.cancel();
    _heartbeat?.cancel();
    unawaited(_closeTransport());
    for (final waiter in _pending.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(const WatchTogetherException('已退出房间'));
      }
    }
    _pending.clear();
    super.dispose();
  }
}
