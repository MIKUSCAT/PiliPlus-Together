enum SyncedPlaybackAction { play, pause, seek, rate, restart, toggle }

/// A room can handle user intent before the native player changes. Applying a
/// remote state always bypasses this hook, so state observations never echo.
abstract interface class PlaybackSyncDelegate {
  bool handlePlaybackAction(
    SyncedPlaybackAction action, {
    Duration? position,
    double? rate,
  });

  void setPlaybackSuspended(bool suspended, {String reason = 'lifecycle'});
}
