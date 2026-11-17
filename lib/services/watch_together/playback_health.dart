/// MPV's error stream includes recoverable decoder and network diagnostics.
/// Give the native player time to recover, and only hold the room when it
/// still cannot produce buffered playback. Repeated diagnostics must not
/// extend that grace period or repeatedly toggle the participant's status.
class WatchPlaybackHealth {
  int? _firstErrorMs;
  bool _failed = false;

  bool get hasError => _firstErrorMs != null;
  bool get failed => _failed;

  void recordError(int nowMs) => _firstErrorMs ??= nowMs;

  /// Returns true only when the availability of playback actually changes.
  bool update({required int nowMs, required bool usable}) {
    final previous = _failed;
    if (usable) {
      reset();
    } else if (_firstErrorMs case final since?) {
      _failed = nowMs - since >= 3000;
    }
    return previous != _failed;
  }

  void reset() {
    _firstErrorMs = null;
    _failed = false;
  }
}
