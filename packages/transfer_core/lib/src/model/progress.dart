// Progress and result types shown by the UI.

/// Identity of a device as shown to the other side.
class DeviceInfo {
  const DeviceInfo({required this.id, required this.name, required this.platform});

  final String id;
  final String name;

  /// "android", "ios", "windows", ...
  final String platform;

  Map<String, Object> toJson() => {'id': id, 'name': name, 'platform': platform};

  factory DeviceInfo.fromJson(Map<String, dynamic> j) => DeviceInfo(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? 'Unknown device',
        platform: j['platform'] as String? ?? 'unknown',
      );
}

enum TransferPhase { connecting, transferring, paused, reconnecting, done, failed, cancelled }

class TransferProgress {
  const TransferProgress({
    required this.phase,
    required this.totalBytes,
    required this.doneBytes,
    required this.filesTotal,
    required this.filesDone,
    required this.bytesPerSecond,
    this.currentFile,
    this.errors = 0,
    this.reconnects = 0,
  });

  final TransferPhase phase;
  final int totalBytes;

  /// Sender: bytes sent. Receiver: bytes received *and verified*.
  final int doneBytes;
  final int filesTotal;

  /// Files whose hash has been verified by the receiver.
  final int filesDone;
  final double bytesPerSecond;
  final String? currentFile;
  final int errors;
  final int reconnects;

  double get fraction => totalBytes == 0 ? (filesTotal == filesDone ? 1 : 0) : doneBytes / totalBytes;

  Duration? get eta {
    if (bytesPerSecond < 1) return null;
    final left = totalBytes - doneBytes;
    if (left <= 0) return Duration.zero;
    return Duration(milliseconds: (left / bytesPerSecond * 1000).round());
  }

  Map<String, Object?> toJson() => {
        'phase': phase.name,
        'totalBytes': totalBytes,
        'doneBytes': doneBytes,
        'filesTotal': filesTotal,
        'filesDone': filesDone,
        'bps': bytesPerSecond,
        'current': currentFile,
        'errors': errors,
        'reconnects': reconnects,
      };

  factory TransferProgress.fromJson(Map<String, dynamic> j) => TransferProgress(
        phase: TransferPhase.values.byName(j['phase'] as String),
        totalBytes: j['totalBytes'] as int,
        doneBytes: j['doneBytes'] as int,
        filesTotal: j['filesTotal'] as int,
        filesDone: j['filesDone'] as int,
        bytesPerSecond: (j['bps'] as num).toDouble(),
        currentFile: j['current'] as String?,
        errors: j['errors'] as int? ?? 0,
        reconnects: j['reconnects'] as int? ?? 0,
      );
}

/// Final result of a transfer.
class TransferSummary {
  TransferSummary({
    required this.filesVerified,
    required this.filesFailed,
    required this.bytes,
    required this.duration,
    required this.errors,
    required this.cancelled,
    this.resentPieces = 0,
    this.reconnects = 0,
    this.destination,
  });

  final int filesVerified;
  final int filesFailed;
  final int bytes;
  final Duration duration;
  final List<String> errors;
  final bool cancelled;
  final int resentPieces;
  final int reconnects;

  /// Receiver only: the folder files were saved into.
  final String? destination;

  bool get success => !cancelled && filesFailed == 0;

  double get averageBytesPerSecond =>
      duration.inMicroseconds == 0 ? 0 : bytes / (duration.inMicroseconds / 1e6);

  Map<String, Object?> toJson() => {
        'filesVerified': filesVerified,
        'filesFailed': filesFailed,
        'bytes': bytes,
        'durationMs': duration.inMilliseconds,
        'errors': errors,
        'cancelled': cancelled,
        'resentPieces': resentPieces,
        'reconnects': reconnects,
        'destination': destination,
      };

  factory TransferSummary.fromJson(Map<String, dynamic> j) => TransferSummary(
        filesVerified: j['filesVerified'] as int,
        filesFailed: j['filesFailed'] as int,
        bytes: j['bytes'] as int,
        duration: Duration(milliseconds: j['durationMs'] as int),
        errors: (j['errors'] as List).cast<String>(),
        cancelled: j['cancelled'] as bool,
        resentPieces: j['resentPieces'] as int? ?? 0,
        reconnects: j['reconnects'] as int? ?? 0,
        destination: j['destination'] as String?,
      );
}

/// Errors that end a transfer for good (no reconnect).
class TransferCancelled implements Exception {
  TransferCancelled([this.byPeer = false]);
  final bool byPeer;
  @override
  String toString() => byPeer ? 'Cancelled by the other device' : 'Cancelled';
}

class PairingRejected implements Exception {
  PairingRejected(this.reason);
  final String reason;
  @override
  String toString() => 'Connection refused: $reason';
}

/// Simple moving-window speed meter.
class SpeedMeter {
  SpeedMeter({this.window = const Duration(seconds: 3)});
  final Duration window;
  final _samples = <(int, int)>[]; // (microsecond timestamp, total bytes)
  final _clock = Stopwatch()..start();

  void add(int totalBytes) {
    final now = _clock.elapsedMicroseconds;
    _samples.add((now, totalBytes));
    while (_samples.length > 2 && now - _samples.first.$1 > window.inMicroseconds) {
      _samples.removeAt(0);
    }
  }

  double get bytesPerSecond {
    if (_samples.length < 2) return 0;
    final (t0, b0) = _samples.first;
    final (t1, b1) = _samples.last;
    if (t1 == t0) return 0;
    return (b1 - b0) / ((t1 - t0) / 1e6);
  }
}
