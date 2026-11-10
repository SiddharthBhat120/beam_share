/// Tuning knobs shared by sender and receiver.
class TransferOptions {
  const TransferOptions({
    this.batchBytes = 4 * 1024 * 1024,
    this.maxBatchFiles = 512,
    this.readAhead = 6,
    this.heartbeat = const Duration(seconds: 2),
    this.peerTimeout = const Duration(seconds: 20),
    this.maxRetries = 5,
    this.verifyOnDisk = false,
    this.debugCorrupt,
  });

  /// Small files are packed into units of up to this many bytes...
  final int batchBytes;

  /// ...or this many files, whichever comes first.
  final int maxBatchFiles;

  /// Units read from disk ahead of the network (pipelining).
  final int readAhead;

  /// How often each side sends a "ping" on the control connection.
  final Duration heartbeat;

  /// If nothing arrives for this long, the connection counts as dropped.
  final Duration peerTimeout;

  /// How often one piece may fail its checksum before the file fails.
  final int maxRetries;

  /// Receiver: after a big file is complete, read it back from disk and hash
  /// it again (catches faulty storage; costs one extra read).
  final bool verifyOnDisk;

  /// Testing only: return true to flip a byte in a piece *after* hashing, to
  /// simulate corruption on the wire. Arguments: fileId, piece, attempt (1..).
  final bool Function(int fileId, int piece, int attempt)? debugCorrupt;
}
