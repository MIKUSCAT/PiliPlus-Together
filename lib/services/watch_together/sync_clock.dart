/// Estimate server time from round trips. The caller supplies a monotonic local
/// clock so changing a phone's date cannot jump the room's playback position.
class WatchSyncClock {
  final List<({int rtt, double offset})> _samples = [];
  double _offset = 0;
  bool _initialized = false;

  int? get latencyMs => _samples.isEmpty
      ? null
      : _samples.map((s) => s.rtt).reduce((a, b) => a < b ? a : b) ~/ 2;

  void initialize(int localNowMs, int serverTimeMs) {
    if (_initialized) return;
    _initialized = true;
    _offset = (serverTimeMs - localNowMs).toDouble();
  }

  void record({
    required int sentAtMs,
    required int receivedAtMs,
    required int serverTimeMs,
  }) {
    final rtt = receivedAtMs - sentAtMs;
    if (rtt < 0 || rtt > 10000) return;
    _initialized = true;
    _samples.add((
      rtt: rtt,
      offset: serverTimeMs - (sentAtMs + receivedAtMs) / 2,
    ));
    if (_samples.length > 8) _samples.removeAt(0);
    _offset = _samples.reduce((a, b) => a.rtt <= b.rtt ? a : b).offset;
  }

  int serverNow(int localNowMs) => (localNowMs + _offset).round();

  void reset() {
    _samples.clear();
    _initialized = false;
    _offset = 0;
  }
}

/// Small decoder jitter should not cause repeated, audible seeks.
bool shouldCorrectWatchPosition({
  required int targetMs,
  required int actualMs,
  required bool playing,
  required bool force,
  required int millisecondsSinceSeek,
}) {
  final drift = (targetMs - actualMs).abs();
  if (force) return drift > 80;
  if (!playing) return drift > 150;
  return drift > 650 && millisecondsSinceSeek >= 2000;
}
