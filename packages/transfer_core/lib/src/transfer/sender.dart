// The sending side of a transfer.
//
// Per round:
//   1. send the manifest, get back what the receiver already has (resume)
//   2. a *reader* task reads files from disk in order, hashes them and puts
//      ready-to-send units into a small queue (so disk reads overlap sending)
//   3. one *worker* per data connection takes units from the queue and sends
//      them; all connections run in parallel
//   4. the receiver reports verified files ("ok") and bad pieces ("nack");
//      bad pieces are read again and re-sent first
//   5. when every file is verified (or failed), send "done", get a summary.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../hash/blake3.dart';
import '../model/manifest.dart';
import '../model/progress.dart';
import '../model/source.dart';
import '../net/link.dart';
import '../protocol/data_unit.dart';
import '../protocol/frames.dart';
import '../util/async_utils.dart';
import 'options.dart';

class _Unit {
  _Unit(this.segments, this.parts);
  final List<Segment> segments;
  final List<Uint8List> parts;
}

class TransferSender {
  TransferSender({
    required this.link,
    required List<SourceFile> sources,
    this.options = const TransferOptions(),
  }) : _sources = sources {
    _manifest = buildManifest(sources);
  }

  final SessionLink link;
  final TransferOptions options;
  final List<SourceFile> _sources;
  late final Manifest _manifest;

  Manifest get manifest => _manifest;

  // ---- state that survives reconnects ----
  final _ok = <int>{};
  final _failed = <int, String>{};
  final _cvs = <int, List<Uint8List?>>{}; // piece hashes of big files
  final _attempts = <int, int>{}; // (fileId << 24 | piece) -> sends
  final _countedPieces = <int>{};
  Map<int, List<bool>> _remoteHave = {};
  int _progressBytes = 0;
  int _resent = 0;
  int _reconnects = 0;
  int _nextUnitId = 1;
  String? _currentFile;

  // ---- control ----
  final _gate = Gate();
  bool _localPaused = false;
  bool _remotePaused = false;
  bool _cancelled = false;
  RoundConnections? _round;
  TransferPhase _phase = TransferPhase.connecting;
  final _progress = StreamController<TransferProgress>.broadcast();
  final _speed = SpeedMeter();

  Stream<TransferProgress> get progress => _progress.stream;

  /// Builds the manifest. Duplicate paths get " (1)" suffixes.
  static Manifest buildManifest(List<SourceFile> sources) {
    final used = <String>{};
    final entries = <ManifestEntry>[];
    for (var i = 0; i < sources.length; i++) {
      final s = sources[i];
      var path = s.relativePath.replaceAll('\\', '/');
      if (!s.isDirectory) {
        var n = 1;
        final base = path;
        while (used.contains(path.toLowerCase())) {
          final dot = base.lastIndexOf('.');
          final slash = base.lastIndexOf('/');
          path = dot > slash + 1
              ? '${base.substring(0, dot)} ($n)${base.substring(dot)}'
              : '$base ($n)';
          n++;
        }
      }
      used.add(path.toLowerCase());
      entries.add(ManifestEntry(
        id: i,
        path: path,
        size: s.isDirectory ? 0 : s.size,
        modifiedMs: s.modified.toUtc().millisecondsSinceEpoch,
        isDirectory: s.isDirectory,
        pieceSize: s.isDirectory ? 0 : pieceSizeFor(s.size),
      ));
    }
    return Manifest(entries);
  }

  int get _fileCount => _manifest.fileCount;
  bool get _allResolved => _ok.length + _failed.length >= _fileCount;

  void pause() {
    _localPaused = true;
    _applyPause();
    _round?.control.writer.sendJson({'t': 'pause'}).catchError((_) {});
  }

  void resume() {
    _localPaused = false;
    _applyPause();
    _round?.control.writer.sendJson({'t': 'resume'}).catchError((_) {});
  }

  void _applyPause() {
    if (_localPaused || _remotePaused) {
      _gate.close();
    } else {
      _gate.open();
    }
  }

  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    try {
      await _round?.control.writer.sendJson({'t': 'cancel'}).timeout(const Duration(seconds: 1));
      // Let the message reach the peer before the sockets are torn down
      // (an immediate close can reset the connection and drop it).
      await Future<void>.delayed(const Duration(milliseconds: 300));
    } catch (_) {}
    _gate.open();
    await link.close();
  }

  /// Runs the transfer to the end. Never throws; check the summary.
  Future<TransferSummary> run() async {
    final clock = Stopwatch()..start();
    final timer = Timer.periodic(const Duration(milliseconds: 250), (_) => _emit());
    final errors = <String>[];
    var cancelled = false;
    try {
      while (true) {
        final rc = await link.nextRound();
        _round = rc;
        try {
          await _runRound(rc);
          break;
        } catch (e) {
          if (_cancelled || e is TransferCancelled) rethrow;
          _reconnects++;
          _phase = TransferPhase.reconnecting;
          _emit();
        } finally {
          _round = null;
          rc.close();
        }
      }
      _phase = TransferPhase.done;
    } on TransferCancelled catch (e) {
      cancelled = true;
      _phase = TransferPhase.cancelled;
      errors.add(e.toString());
    } catch (e) {
      if (_cancelled) {
        cancelled = true;
        _phase = TransferPhase.cancelled;
      } else {
        _phase = TransferPhase.failed;
        errors.add('Connection lost: $e');
      }
    } finally {
      timer.cancel();
      await link.close();
    }
    _failed.forEach((id, reason) => errors.add('${_manifest.entries[id].path}: $reason'));
    _emit();
    await _progress.close();
    final failedCount = _fileCount - _ok.length;
    return TransferSummary(
      filesVerified: _ok.length,
      filesFailed: cancelled ? 0 : failedCount,
      bytes: _manifest.entries.where((e) => _ok.contains(e.id)).fold(0, (s, e) => s + e.size),
      duration: clock.elapsed,
      errors: errors,
      cancelled: cancelled,
      resentPieces: _resent,
      reconnects: _reconnects,
    );
  }

  void _emit() {
    if (_progress.isClosed) return;
    _speed.add(_progressBytes);
    var phase = _phase;
    if (phase == TransferPhase.transferring && !_gate.isOpen) phase = TransferPhase.paused;
    _progress.add(TransferProgress(
      phase: phase,
      totalBytes: _manifest.totalBytes,
      doneBytes: _progressBytes,
      filesTotal: _fileCount,
      filesDone: _ok.length,
      bytesPerSecond: _speed.bytesPerSecond,
      currentFile: _currentFile,
      errors: _failed.length,
      reconnects: _reconnects,
    ));
  }

  Future<Map<String, dynamic>> _awaitMessage(BeamConnection c, String type, Duration timeout) async {
    while (true) {
      final m = await c.reader.nextJson().timeout(timeout);
      if (m['t'] == type) return m;
      if (m['t'] == 'cancel') throw TransferCancelled(true);
    }
  }

  Future<void> _runRound(RoundConnections rc) async {
    final ctl = rc.control;
    await ctl.writer.sendJson(_manifest.toJson());
    final state = await _awaitMessage(ctl, 'state', const Duration(seconds: 60));
    _applyState(state);
    _phase = TransferPhase.transferring;
    // Tell the receiver if we are paused right now.
    if (_localPaused) await ctl.writer.sendJson({'t': 'pause'});

    final end = Completer<void>();
    end.future.ignore();
    final summary = Completer<Map<String, dynamic>>();
    summary.future.ignore();
    void fail(Object e) {
      if (!end.isCompleted) end.completeError(e);
      if (!summary.isCompleted) summary.completeError(e);
    }

    void checkDone() {
      if (_allResolved && !end.isCompleted) end.complete();
    }

    final channel = AsyncChannel<_Unit>(options.readAhead);
    var lastHeard = DateTime.now();
    var aborted = false;

    // Control messages from the receiver.
    spawn(() async {
      while (true) {
        final f = await ctl.reader.next();
        if (f == null) throw ProtocolException('control connection closed');
        lastHeard = DateTime.now();
        final m = f.json;
        switch (m['t']) {
          case 'ok':
            _ok.addAll((m['f'] as List).cast<int>());
            checkDone();
          case 'nack':
            for (final s in (m['s'] as List).cast<List<dynamic>>()) {
              _resend(s[0] as int, s[1] as int, channel).catchError(fail);
            }
          case 'bad':
            final id = m['f'] as int;
            final e = _manifest.entries[id];
            for (var i = 0; i < e.pieceCount; i++) {
              _resend(id, i, channel).catchError(fail);
            }
          case 'fail':
            _failed[m['f'] as int] = m['r'] as String? ?? 'failed';
            checkDone();
          case 'pause':
            _remotePaused = true;
            _applyPause();
          case 'resume':
            _remotePaused = false;
            _applyPause();
          case 'cancel':
            throw TransferCancelled(true);
          case 'summary':
            if (!summary.isCompleted) summary.complete(m);
        }
      }
    }, fail);

    final heartbeat = Timer.periodic(options.heartbeat, (_) {
      ctl.writer.sendJson({'t': 'ping'}).catchError(fail);
      if (DateTime.now().difference(lastHeard) > options.peerTimeout) {
        fail(TimeoutException('no answer from the other device'));
      }
    });

    _readAll(channel, ctl, () => aborted).catchError(fail);
    for (final conn in rc.data) {
      _worker(conn, channel).catchError(fail);
    }
    checkDone();

    try {
      await end.future;
      await ctl.writer.sendJson({'t': 'done'});
      await summary.future.timeout(const Duration(seconds: 30));
    } finally {
      aborted = true;
      heartbeat.cancel();
      channel.close();
    }
  }

  void _applyState(Map<String, dynamic> state) {
    _ok.addAll((state['done'] as List).cast<int>());
    final failed = (state['failed'] as Map?)?.cast<String, dynamic>() ?? {};
    failed.forEach((k, v) => _failed[int.parse(k)] = v as String);
    final partial = (state['partial'] as Map).cast<String, dynamic>();
    _remoteHave = {
      for (final e in partial.entries)
        int.parse(e.key): decodeBits(base64Decode(e.value as String), _manifest.entries[int.parse(e.key)].pieceCount),
    };
    // Count already-delivered bytes as progress.
    for (final id in _ok) {
      final e = _manifest.entries[id];
      for (var i = 0; i < e.pieceCount; i++) {
        _countPiece(id, i, e.pieceLength(i));
      }
    }
    _remoteHave.forEach((id, bits) {
      final e = _manifest.entries[id];
      for (var i = 0; i < bits.length; i++) {
        if (bits[i]) _countPiece(id, i, e.pieceLength(i));
      }
    });
  }

  void _countPiece(int fileId, int piece, int length) {
    if (_countedPieces.add(fileId << 24 | piece)) _progressBytes += length;
  }

  bool _skip(ManifestEntry e) => e.isDirectory || _ok.contains(e.id) || _failed.containsKey(e.id);

  /// Reads all files in order and fills the channel.
  Future<void> _readAll(AsyncChannel<_Unit> channel, BeamConnection ctl, bool Function() aborted) async {
    var segs = <Segment>[];
    var parts = <Uint8List>[];
    var batchBytes = 0;

    Future<void> flush() async {
      if (segs.isEmpty) return;
      final u = _Unit(segs, parts);
      segs = [];
      parts = [];
      batchBytes = 0;
      await channel.put(u);
    }

    for (final e in _manifest.entries) {
      if (aborted()) return;
      if (_skip(e)) continue;
      final src = _sources[e.id];
      _currentFile = e.path;
      if (!e.isChunked) {
        final bytes = await _readRange(src, 0, e.size);
        if (batchBytes + bytes.length > options.batchBytes || segs.length >= options.maxBatchFiles) {
          await flush();
        }
        segs.add(Segment(fileId: e.id, piece: 0, offset: 0, length: bytes.length, hash: Blake3.hash(bytes)));
        parts.add(bytes);
        batchBytes += bytes.length;
      } else {
        await flush();
        await _readChunked(e, src, channel, ctl, aborted);
      }
    }
    await flush();
  }

  Future<void> _readChunked(ManifestEntry e, SourceFile src, AsyncChannel<_Unit> channel,
      BeamConnection ctl, bool Function() aborted) async {
    final n = e.pieceCount;
    final cvs = _cvs.putIfAbsent(e.id, () => List<Uint8List?>.filled(n, null));
    final have = _remoteHave[e.id];
    final reader = await src.open();
    try {
      for (var i = 0; i < n; i++) {
        if (aborted()) return;
        final needed = have == null || !have[i];
        if (!needed && cvs[i] != null) continue;
        final len = e.pieceLength(i);
        final data = await reader.readAt(i * e.pieceSize, len);
        if (data.length != len) throw StateError('${e.path} changed while sending');
        final cv = Blake3.pieceCv(data, i, e.pieceSize);
        if (cvs[i] != null && !bytesEqual(cvs[i]!, cv)) {
          throw StateError('${e.path} changed while sending');
        }
        cvs[i] = cv;
        if (needed) {
          await channel.put(_Unit(
            [Segment(fileId: e.id, piece: i, offset: i * e.pieceSize, length: len, hash: cv)],
            [data],
          ));
        }
      }
    } finally {
      await reader.close();
    }
    // All piece hashes known: tell the receiver the full-file BLAKE3 hash.
    final root = Blake3.rootFromPieceCvs(cvs.cast<Uint8List>());
    await ctl.writer.sendJson({'t': 'fhash', 'f': e.id, 'h': Blake3.toHex(root)});
  }

  Future<Uint8List> _readRange(SourceFile src, int offset, int length) async {
    final reader = await src.open();
    try {
      final data = await reader.readAt(offset, length);
      if (data.length != length) throw StateError('${src.relativePath} changed while sending');
      return data;
    } finally {
      await reader.close();
    }
  }

  /// Re-reads one piece (or small file) and queues it before everything else.
  Future<void> _resend(int fileId, int piece, AsyncChannel<_Unit> channel) async {
    if (fileId < 0 || fileId >= _manifest.entries.length) return;
    final e = _manifest.entries[fileId];
    if (e.isDirectory || piece < 0 || piece >= e.pieceCount) return;
    _resent++;
    final src = _sources[fileId];
    final offset = e.isChunked ? piece * e.pieceSize : 0;
    final len = e.pieceLength(piece);
    final data = await _readRange(src, offset, len);
    final hash = e.isChunked ? Blake3.pieceCv(data, piece, e.pieceSize) : Blake3.hash(data);
    channel.putFront(_Unit(
      [Segment(fileId: fileId, piece: piece, offset: offset, length: len, hash: hash)],
      [data],
    ));
  }

  Future<void> _worker(BeamConnection conn, AsyncChannel<_Unit> channel) async {
    while (true) {
      await _gate.wait();
      final unit = await channel.take();
      if (unit == null) return;
      var parts = unit.parts;
      final corrupt = options.debugCorrupt;
      for (var i = 0; i < unit.segments.length; i++) {
        final s = unit.segments[i];
        final key = s.fileId << 24 | s.piece;
        final attempt = (_attempts[key] ?? 0) + 1;
        _attempts[key] = attempt;
        if (corrupt != null && s.length > 0 && corrupt(s.fileId, s.piece, attempt)) {
          // Simulated bit-flip on the wire (tests only).
          final bad = Uint8List.fromList(parts[i]);
          bad[bad.length ~/ 2] ^= 0xFF;
          parts = [...parts]..[i] = bad;
        }
      }
      final header = encodeUnitHeader(_nextUnitId++, unit.segments);
      await conn.writer.sendData([header, ...parts]).timeout(const Duration(seconds: 60));
      for (final s in unit.segments) {
        _countPiece(s.fileId, s.piece, s.length);
      }
    }
  }
}
