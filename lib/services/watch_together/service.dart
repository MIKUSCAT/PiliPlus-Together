import 'dart:async';
import 'dart:convert';

import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/watch_together.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/playback_sync.dart';
import 'package:PiliPlus/services/watch_together/client.dart';
import 'package:PiliPlus/services/watch_together/sync_clock.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class WatchLoadTicket {
  const WatchLoadTicket(this.generation, this.mediaEpoch, this.positionMs);
  final int generation;
  final int mediaEpoch;
  final int positionMs;
}

/// The only bridge between room state and PiliPlus playback/navigation. The
/// socket client and wire models do not depend on the native player.
class WatchTogetherService
    with WidgetsBindingObserver
    implements PlaybackSyncDelegate {
  WatchTogetherService._() {
    WatchSession? saved;
    try {
      final raw = GStorage.localCache.get(_sessionKey) as String?;
      if (raw != null) {
        saved = WatchSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      }
    } catch (_) {
      /* An expired local session can simply be joined again. */
    }
    client = WatchTogetherClient(
      serverUrl: GStorage.setting.get(
        _serverKey,
        defaultValue: const String.fromEnvironment('WATCH_TOGETHER_URL'),
      ) as String,
      nickname: GStorage.setting.get(
        _nameKey,
        defaultValue: Pref.userInfoCache?.uname ?? '一起看的人',
      ) as String,
      savedSession: saved,
      onSaveSession: (session) => session == null
          ? GStorage.localCache.delete(_sessionKey)
          : GStorage.localCache.put(_sessionKey, jsonEncode(session.toJson())),
    )..addListener(_onRoomChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  static WatchTogetherService? _instance;
  static WatchTogetherService get instance =>
      _instance ??= WatchTogetherService._();
  static WatchTogetherService? get maybe => _instance;
  static bool get active => _instance?.client.joined ?? false;
  static const _serverKey = 'watchTogetherServer';
  static const _nameKey = 'watchTogetherNickname';
  // Credentials stay outside the settings export / WebDAV backup.
  static const _sessionKey = 'watchTogetherSession';

  late final WatchTogetherClient client;
  PlPlayerController? _player;
  WatchVideo? _loadedVideo;
  int _loadedEpoch = -1;
  int _loadGeneration = 0;
  String? _activePageTag;
  String? _loadingKey;
  String? _openingKey;
  bool _localSelection = false;
  bool _navigationSuppressed = false;
  bool _ready = false;
  bool _buffering = false;
  String? _playbackError;
  final Set<String> _suspensions = {};
  int _panels = 0;
  Timer? _tick;
  Timer? _bufferTimer;
  Timer? _loadTimeout;
  StreamSubscription<bool>? _bufferSubscription;
  StreamSubscription<String>? _errorSubscription;
  bool _syncRunning = false;
  bool _syncAgain = false;
  bool _forcePosition = false;
  int _lastAppliedRevision = -1;
  int _lastSeekMs = -10000;
  double? _soloRate;
  WatchConnection _lastConnection = WatchConnection.disconnected;
  bool _wasJoined = false;
  int _lastCompletedEpoch = -1;

  bool controls(PlPlayerController player) =>
      client.joined &&
      identical(player, _player) &&
      identical(player.syncDelegate, this) &&
      _loadedVideo?.key == client.room?.video?.key &&
      _loadedEpoch == client.room?.mediaEpoch &&
      player.cid == client.room?.video?.cid;

  VideoDetailController? get currentController {
    final owner = PlPlayerController.playOwner;
    if (owner == null ||
        !Get.isRegistered<VideoDetailController>(tag: owner.tag)) {
      return null;
    }
    final controller = Get.find<VideoDetailController>(tag: owner.tag);
    return controller.isClosed ? null : controller;
  }

  Future<void> configure({
    required String serverUrl,
    required String nickname,
  }) async {
    client.configure(serverUrl: serverUrl, nickname: nickname);
    await GStorage.setting.putAll({
      _serverKey: client.serverUrl,
      _nameKey: client.nickname,
    });
  }

  void panelOpened() => _panels++;
  void panelClosed() {
    if (_panels > 0) _panels--;
    _scheduleOpen();
  }

  Future<void> createRoom(VideoDetailController? controller) async {
    _localSelection = true;
    try {
      await client.create();
      if (controller?.watchVideo case final video?) {
        _activePageTag = controller!.heroTag;
        await client.selectVideo(
          video,
          positionMs: controller.plPlayerController.positionInMilliseconds,
          playing: controller.plPlayerController.playerStatus.isPlaying,
        );
        await _bindCurrent(controller, video);
      }
    } finally {
      _localSelection = false;
      _scheduleOpen();
    }
  }

  Future<void> joinRoom(String code) async {
    _localSelection = true;
    try {
      await client.join(code);
      final controller = currentController;
      final video = controller?.watchVideo;
      await controller?.plPlayerController.pause(sync: false);
      if (controller != null &&
          video != null &&
          video.key == client.room?.video?.key) {
        await _bindCurrent(controller, video);
      }
    } finally {
      _localSelection = false;
      _scheduleOpen();
    }
  }

  Future<void> _bindCurrent(
    VideoDetailController controller,
    WatchVideo video,
  ) async {
    _activePageTag = controller.heroTag;
    final player = controller.plPlayerController;
    if (player.videoPlayerController != null &&
        player.dataStatus.value == DataStatus.loaded) {
      await attachPlayer(
        video,
        player,
        WatchLoadTicket(
          ++_loadGeneration,
          client.room!.mediaEpoch,
          client.room!.positionAt(client.serverNowMs),
        ),
      );
    } else if (controller.videoUrl == null) {
      await controller.queryVideoUrl(fromReset: true);
    } else {
      await controller.playerInit(autoplay: false);
    }
  }

  /// Called when a normal video page becomes the active playback owner. It
  /// holds the room while local URL resolution runs, instead of navigating
  /// back to the previous room video in the middle of a user selection.
  void videoPageOpened(String tag, String? mediaKey) {
    if (!client.joined) return;
    _activePageTag = tag;
    _loadingKey = mediaKey;
    _navigationSuppressed = mediaKey == null;
    _localSelection = mediaKey != null && mediaKey != client.room?.video?.key;
    _ready = false;
    _playbackError = mediaKey == null ? '这种视频暂不支持一起看，可返回房间继续' : null;
    _reportStatus();
    _loadTimeout?.cancel();
    _loadTimeout = Timer(const Duration(seconds: 35), () {
      if (client.joined && !_ready && _activePageTag == tag) {
        _playbackError = '视频暂时无法加载，可以重试或换一个视频';
        _reportStatus();
      }
    });
  }

  Future<WatchLoadTicket?> prepareVideo(WatchVideo video, String tag) async {
    if (!client.joined || !client.connected) return null;
    if (_activePageTag != null && _activePageTag != tag) return null;
    _activePageTag = tag;
    _loadingKey = video.key;
    _ready = false;
    _playbackError = null;
    final generation = ++_loadGeneration;
    _reportStatus();
    try {
      if (client.room?.video?.key != video.key) {
        _localSelection = true;
        await client.selectVideo(video);
      }
      final room = client.room;
      if (!client.joined ||
          room?.video?.key != video.key ||
          generation != _loadGeneration) {
        return null;
      }
      return WatchLoadTicket(
        generation,
        room!.mediaEpoch,
        room.positionAt(client.serverNowMs),
      );
    } catch (error) {
      SmartDialog.showToast(error.toString());
      return null;
    } finally {
      _localSelection = false;
    }
  }

  Future<void> attachPlayer(
    WatchVideo video,
    PlPlayerController player,
    WatchLoadTicket ticket,
  ) async {
    if (!client.joined ||
        ticket.generation != _loadGeneration ||
        ticket.mediaEpoch != client.room?.mediaEpoch ||
        client.room?.video?.key != video.key ||
        player.cid != video.cid) {
      return;
    }
    if (player.dataStatus.value != DataStatus.loaded ||
        player.videoPlayerController == null) {
      _playbackError = '视频加载失败，可以重试或换一个视频';
      _ready = false;
      _reportStatus();
      return;
    }
    await _bufferSubscription?.cancel();
    await _errorSubscription?.cancel();
    _bufferTimer?.cancel();
    _loadTimeout?.cancel();
    if (_player != null && !identical(_player, player)) {
      _player!.syncDelegate = null;
    }
    _soloRate ??= player.playbackSpeed;
    _player = player;
    _loadedVideo = video;
    _loadedEpoch = ticket.mediaEpoch;
    _loadingKey = _openingKey = null;
    _playbackError = null;
    _navigationSuppressed = false;
    player.syncDelegate = this;
    _ready = true;
    _buffering = player.isBuffering.value;
    _forcePosition = true;
    _lastAppliedRevision = -1;
    final nativePlayer = player.videoPlayerController!;
    _bufferSubscription = nativePlayer.stream.buffering.listen((buffering) {
      if (!controls(player)) return;
      _bufferTimer?.cancel();
      if (buffering) {
        _bufferTimer = Timer(const Duration(milliseconds: 700), () {
          if (!controls(player)) return;
          _buffering = true;
          _reportStatus();
        });
      } else {
        _buffering = false;
        _reportStatus();
      }
    });
    _errorSubscription = nativePlayer.stream.error.listen((error) {
      if (!controls(player) || error.isEmpty) return;
      _playbackError = '视频暂时无法播放，请重试或检查观看权限';
      _ready = false;
      _reportStatus();
    });
    await _synchronize();
    _reportStatus();
  }

  void videoPageClosed(String tag) {
    if (_activePageTag != tag || !client.joined) return;
    _activePageTag = null;
    _ready = false;
    _navigationSuppressed = true;
    _loadTimeout?.cancel();
    _reportStatus();
  }

  void videoLoadFailed(String tag) {
    if (_activePageTag != tag || !client.joined) return;
    _ready = false;
    _playbackError = '视频暂时无法播放，请重试或检查观看权限';
    _loadTimeout?.cancel();
    _reportStatus();
  }

  void _onRoomChanged() {
    final joined = client.joined;
    if (!joined) {
      if (_wasJoined) _detach();
      _wasJoined = false;
      _lastConnection = client.connection;
      return;
    }
    _wasJoined = true;
    _tick ??= Timer.periodic(const Duration(milliseconds: 750), (_) {
      if (client.connected) {
        unawaited(_synchronize());
        _scheduleOpen();
      }
    });
    if (!client.connected) {
      unawaited(_player?.pause(sync: false));
    } else {
      final player = _player;
      if (player != null && !controls(player)) {
        _ready = false;
        unawaited(player.pause(sync: false));
      }
      if (_lastConnection != WatchConnection.connected) {
        _forcePosition = true;
        _reportStatus();
      }
      unawaited(_synchronize());
      _scheduleOpen();
    }
    _lastConnection = client.connection;
  }

  void _reportStatus() {
    final room = client.room;
    if (room == null || !client.connected) return;
    final sameVideo =
        _loadedVideo?.key == room.video?.key && _loadedEpoch == room.mediaEpoch;
    client.reportStatus(
      mediaEpoch: room.mediaEpoch,
      ready: _ready && sameVideo,
      buffering: _buffering && sameVideo,
      suspended: _suspensions.isNotEmpty,
      error: _playbackError,
      durationMs: sameVideo
          ? _player?.videoPlayerController?.state.duration.inMilliseconds ?? 0
          : 0,
    );
  }

  Future<void> _synchronize() async {
    if (_syncRunning) {
      _syncAgain = true;
      return;
    }
    _syncRunning = true;
    try {
      do {
        _syncAgain = false;
        final room = client.room;
        final player = _player;
        if (!client.connected ||
            room == null ||
            player == null ||
            !controls(player) ||
            !_ready ||
            player.processing) {
          break;
        }
        final epoch = room.mediaEpoch;
        final native = player.videoPlayerController;
        if (native == null) break;
        final explicitSeek =
            room.revision != _lastAppliedRevision &&
            const {'seek', 'restart', 'select'}.contains(room.lastAction);
        final target = room.positionAt(client.serverNowMs);
        if (target < player.durationInMilliseconds - 2000) {
          _lastCompletedEpoch = -1;
        }
        if (!_buffering &&
            shouldCorrectWatchPosition(
              targetMs: target,
              actualMs: player.positionInMilliseconds,
              playing: room.playing,
              force: _forcePosition || explicitSeek,
              millisecondsSinceSeek: client.localNowMs - _lastSeekMs,
            )) {
          await player.seekTo(Duration(milliseconds: target), sync: false);
          _lastSeekMs = client.localNowMs;
        }
        if (!client.connected ||
            client.room?.mediaEpoch != epoch ||
            !controls(player)) {
          break;
        }
        if (client.room?.revision != room.revision) {
          _syncAgain = true;
          continue;
        }
        if ((player.playbackSpeed - room.rate).abs() > 0.001) {
          await player.setPlaybackSpeed(room.rate, sync: false);
        }
        if (!client.connected ||
            client.room?.mediaEpoch != epoch ||
            !controls(player)) {
          break;
        }
        if (client.room?.revision != room.revision) {
          _syncAgain = true;
          continue;
        }
        final shouldPlay = room.playing && _suspensions.isEmpty && !_buffering;
        if (shouldPlay && !native.state.playing) {
          if (!native.state.completed ||
              target < player.durationInMilliseconds - 200) {
            await player.play(sync: false, hideControls: false);
          }
        } else if (!shouldPlay && native.state.playing) {
          await player.pause(sync: false);
        }
        _forcePosition = false;
        _lastAppliedRevision = room.revision;
      } while (_syncAgain);
    } catch (_) {
      if (client.joined) {
        _playbackError = '播放同步暂时中断，可在房间内重新同步';
        _reportStatus();
      }
    } finally {
      _syncRunning = false;
    }
  }

  @override
  bool handlePlaybackAction(
    SyncedPlaybackAction action, {
    Duration? position,
    double? rate,
  }) {
    final player = _player;
    if (player == null || !controls(player)) return false;
    final values = <String, dynamic>{
      if (position != null)
        'positionMs': position.inMilliseconds.clamp(
          0,
          client.room!.video!.durationMs > 0
              ? client.room!.video!.durationMs
              : 7 * 24 * 3600000,
        ),
      'rate': ?rate,
    };
    unawaited(
      client.command(action.name, values).catchError((Object error) {
        SmartDialog.showToast(error.toString());
        client.requestSync();
      }),
    );
    return true;
  }

  @override
  void setPlaybackSuspended(bool suspended, {String reason = 'lifecycle'}) {
    if (suspended) {
      _suspensions.add(reason);
    } else {
      _suspensions.remove(reason);
    }
    _reportStatus();
    if (suspended) unawaited(_player?.pause(sync: false, isInterrupt: true));
    if (!suspended) {
      _forcePosition = true;
      unawaited(_synchronize());
    }
  }

  /// Exactly one participant runs the existing next-episode / repeat logic.
  bool mayAdvanceAfterCompletion(PlPlayerController player) {
    if (!client.joined) return true;
    if (!controls(player)) return false;
    if (!client.isHost || _lastCompletedEpoch == _loadedEpoch) return false;
    _lastCompletedEpoch = _loadedEpoch;
    unawaited(client.command('pause').catchError((Object _) {}));
    return true;
  }

  Future<void> resynchronize() async {
    _playbackError = null;
    _forcePosition = true;
    if (!client.connected) {
      await client.retry();
      return;
    }
    _navigationSuppressed = false;
    final controller = currentController;
    if (!_ready && controller?.watchVideo?.key == client.room?.video?.key) {
      await controller!.queryVideoUrl(fromReset: true);
    } else {
      client.requestSync();
      await _synchronize();
      _scheduleOpen();
    }
  }

  void openRoomVideo() {
    _navigationSuppressed = false;
    _openingKey = null;
    _scheduleOpen(force: true);
  }

  void _scheduleOpen({bool force = false}) {
    final video = client.room?.video;
    if (video == null ||
        !client.connected ||
        _localSelection ||
        _panels > 0 ||
        _navigationSuppressed) {
      return;
    }
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    if (!force &&
        (_loadingKey == video.key ||
            _openingKey == video.key ||
            (_loadedVideo?.key == video.key &&
                _loadedEpoch == client.room?.mediaEpoch &&
                _ready))) {
      return;
    }
    _openingKey = video.key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!client.joined ||
          _panels > 0 ||
          client.room?.video?.key != video.key) {
        _openingKey = null;
        return;
      }
      final controller = currentController;
      if (controller?.watchVideo?.key == video.key) {
        _navigationSuppressed = false;
        _activePageTag = controller!.heroTag;
        unawaited(_bindCurrent(controller, video));
        return;
      }
      final player = _player;
      if (player?.isFullScreen.value == true) {
        player!.triggerFullScreen(status: false);
      }
      PageUtils.toVideoPage(
        videoType: video.kind == 'pgc' ? VideoType.pgc : VideoType.ugc,
        bvid: video.bvid,
        cid: video.cid,
        epId: video.epId,
        seasonId: video.seasonId,
        pgcType: video.pgcType,
        title: video.title,
        cover: video.cover,
        progress: client.room!.positionAt(client.serverNowMs),
        extraArguments: {'watchTogether': true},
        off: Get.currentRoute == '/videoV',
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      client.requestSync();
      _scheduleOpen();
    }
  }

  Future<void> leaveRoom() async {
    final player = _player;
    final continuePlaying = client.room?.desiredPlaying == true;
    await client.leave();
    if (player != null &&
        player.videoPlayerController != null &&
        continuePlaying) {
      await player.play(sync: false, hideControls: false);
    }
  }

  void _detach() {
    _tick?.cancel();
    _tick = null;
    _loadTimeout?.cancel();
    _bufferTimer?.cancel();
    unawaited(_bufferSubscription?.cancel());
    unawaited(_errorSubscription?.cancel());
    final player = _player;
    if (player != null) {
      player.syncDelegate = null;
      if (_soloRate case final rate?) {
        unawaited(player.setPlaybackSpeed(rate, sync: false));
      }
    }
    _player = null;
    _loadedVideo = null;
    _loadedEpoch = -1;
    _activePageTag = _loadingKey = _openingKey = null;
    _localSelection = _ready = _navigationSuppressed = _buffering = false;
    _playbackError = null;
    _soloRate = null;
    _suspensions.clear();
    _lastCompletedEpoch = -1;
    ++_loadGeneration;
  }
}
