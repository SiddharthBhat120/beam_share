// The receiving side of a transfer.
//
// Every segment is hashed *before* it is written. Small files are written
// straight to their final path. Big files are written piece by piece into
// "<name>.beampart" at the right offsets (pieces arrive out of order over
// several connections); once every piece is verified and the merged BLAKE3
// root equals the sender's full-file hash, the file is renamed to its final
// name and gets its original modified date. Only then does it count as done.
//
// All of this state lives in memory across reconnects, so after a drop the
// receiver tells the sender exactly which pieces it already has.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../hash/blake3.dart';
import '../model/manifest.dart';
import '../model/progress.dart';
import '../net/link.dart';
import '../protocol/data_unit.dart';
import '../protocol/frames.dart';
import '../util/async_utils.dart';
import '../util/paths.dart';
import 'options.dart';

class _RxFile {
  _RxFile(this.entry, this.target, this.partPath)
      : verified = List<bool>.filled(entry.pieceCount, false),
        cvs = List<Uint8List?>.filled(entry.pieceCount, null);

  final ManifestEntry entry;
  final String target;
  final String? partPath; // only for big (chunked) files
  final List<bool> verified;
  final List<Uint8List?> cvs;
  final lock = Mutex();
  int verifiedCount = 0;
  int verifiedBytes = 0;
  int failures = 0;
  bool done = false;
  bool failed = false;
  bool finalizing = false;
  bool writing = false;
  String? expectedRoot;
  RandomAccessFile? raf;
}

class TransferReceiver {
  TransferReceiver({
    required this.link,
    required this.destination,
    this.options = const TransferOptions(),
  });

  final SessionLink link;

  /// Folder the files are saved into (created if missing).
  final String destination;
  final TransferOptions options;

  List<_RxFile>? _files;
  Manifest? _manifest;
  final _reserved = <String>{};
  final _errors = <String>[];
  int _verifiedBytes = 0;
  int _filesDone = 0;
  int _badPieces = 0;
  int _reconnects = 0;
  String? _currentFile;

  final _okPending = <int>[];
  RoundConnections? _round;
  void Function(Object error)? _failRound;

  final _gate = Gate(); // receiver does not send data; gate only tracks pause
  bool _localPaused = false;
  bool _remotePaused = false;
  bool _cancelled = false;
  TransferPhase _phase = TransferPhase.connecting;
  final _progress = StreamController<TransferProgress>.broadcast();
  final _speed = SpeedMeter();

  Stream<TransferProgress> get progress => _progress.stream;

  /// Manifest once it arrived (null before the first round).
  Manifest? get manifest => _manifest;

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

  void _applyPause() => (_localPaused || _remotePaused) ? _gate.close() : _gate.open();

  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    try {
      await _round?.control.writer.sendJson({'t': 'cancel'}).timeout(const Duration(seconds: 1));
      // Let the message reach the peer before the sockets are torn down
      // (an immediate close can reset the connection and drop it).
      await Future<void>.delayed(const Duration(milliseconds: 300));
    } catch (_) {}
    await link.close();
  }

  Future<TransferSummary> run() async {
    final clock = Stopwatch()..start();
    final timer = Timer.periodic(const Duration(milliseconds: 250), (_) => _emit());
    var cancelled = false;
    try {
      while (true) {
        final rc = await link.nextRound();
        _round = rc;
        try {
          await _runRound(rc);
          break;
        } catch (e) {
          if (_cancelled || e is TransferCancelled || e is UnsafePathException) rethrow;
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
      _errors.add(e.toString());
    } catch (e) {
      if (_cancelled) {
        cancelled = true;
        _phase = TransferPhase.cancelled;
      } else {
        _phase = TransferPhase.failed;
        _errors.add('Connection lost: $e');
      }
    } finally {
      timer.cancel();
      await link.close();
      await _cleanupIncomplete();
    }
    _emit();
    await _progress.close();
    final total = _manifest?.fileCount ?? 0;
    return TransferSummary(
      filesVerified: _filesDone,
      filesFailed: cancelled ? 0 : total - _filesDone,
      bytes: _verifiedBytes,
      duration: clock.elapsed,
      errors: _errors,
      cancelled: cancelled,
      resentPieces: _badPieces,
      reconnects: _reconnects,
      destination: destination,
    );
  }

  void _emit() {
    if (_progress.isClosed) return;
    _speed.add(_verifiedBytes);
    var phase = _phase;
    if (phase == TransferPhase.transferring && !_gate.isOpen) phase = TransferPhase.paused;
    _progress.add(TransferProgress(
      phase: phase,
      totalBytes: _manifest?.totalBytes ?? 0,
      doneBytes: _verifiedBytes,
      filesTotal: _manifest?.fileCount ?? 0,
      filesDone: _filesDone,
      bytesPerSecond: _speed.bytesPerSecond,
      currentFile: _currentFile,
      errors: _files?.where((f) => f.failed).length ?? 0,
      reconnects: _reconnects,
    ));
  }

  /// Turns the manifest into target paths (first round only).
  Future<void> _prepare(Manifest m) async {
    await Directory(destination).create(recursive: true);
    final files = <_RxFile>[];
    for (final e in m.entries) {
      final path = safeJoin(destination, e.path); // throws on "../" tricks
      if (e.isDirectory) {
        await Directory(path).create(recursive: true);
        files.add(_RxFile(e, path, null)..done = true);
        continue;
      }
      final target = uniquePath(path, reserved: _reserved);
      _reserved.add(target);
      String? part;
      if (e.isChunked) {
        part = uniquePath('$target.beampart', reserved: _reserved);
        _reserved.add(part);
      }
      files.add(_RxFile(e, target, part));
    }
    _files = files;
    _manifest = m;
  }

  Future<void> _runRound(RoundConnections rc) async {
    final ctl = rc.control;
    Map<String, dynamic> msg;
    do {
      msg = await ctl.reader.nextJson().timeout(const Duration(seconds: 60));
      if (msg['t'] == 'cancel') throw TransferCancelled(true);
    } while (msg['t'] != 'manifest');
    final m = Manifest.fromJson(msg);
    if (_files == null) {
      await _prepare(m);
    } else if (m.entries.length != _files!.length) {
      throw ProtocolException('manifest changed between reconnects');
    }
    final files = _files!;

    // Tell the sender what we already have (resume).
    await ctl.writer.sendJson({
      't': 'state',
      'done': [for (final f in files) if (f.done && !f.entry.isDirectory) f.entry.id],
      'failed': {for (final f in files) if (f.failed) '${f.entry.id}': 'failed on receiver'},
      'partial': {
        for (final f in files)
          if (!f.done && !f.failed && f.verifiedCount > 0) '${f.entry.id}': base64Encode(encodeBits(f.verified)),
      },
    });
    _phase = TransferPhase.transferring;
    if (_localPaused) await ctl.writer.sendJson({'t': 'pause'});

    final end = Completer<void>();
    end.future.ignore();
    void fail(Object e) {
      if (!end.isCompleted) end.completeError(e);
    }

    _failRound = fail;
    var lastHeard = DateTime.now();

    // Control loop.
    spawn(() async {
      while (true) {
        final f = await ctl.reader.next();
        if (f == null) throw ProtocolException('control connection closed');
        lastHeard = DateTime.now();
        final m = f.json;
        switch (m['t']) {
          case 'fhash':
            final id = m['f'] as int;
            if (id >= 0 && id < files.length) {
              files[id].expectedRoot = m['h'] as String;
              await _maybeFinalize(files[id], ctl);
            }
          case 'pause':
            _remotePaused = true;
            _applyPause();
          case 'resume':
            _remotePaused = false;
            _applyPause();
          case 'cancel':
            throw TransferCancelled(true);
          case 'done':
            await _flushOk(ctl);
            if (!end.isCompleted) end.complete();
        }
      }
    }, fail);

    // Data loops, one per connection, all in parallel.
    for (final conn in rc.data) {
      spawn(() async {
        while (true) {
          final f = await conn.reader.next();
          if (f == null) throw ProtocolException('data connection closed');
          if (f.type != frameData) throw ProtocolException('expected data frame');
          lastHeard = DateTime.now();
          await _handleUnit(f.payload, ctl);
        }
      }, fail);
    }

    final okTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      _flushOk(ctl).catchError(fail);
    });
    final heartbeat = Timer.periodic(options.heartbeat, (_) {
      ctl.writer.sendJson({'t': 'ping'}).catchError(fail);
      if (DateTime.now().difference(lastHeard) > options.peerTimeout) {
        fail(TimeoutException('no data from the other device'));
      }
    });

    try {
      await end.future;
      await ctl.writer.sendJson({
        't': 'summary',
        'verified': _filesDone,
        'failed': files.where((f) => f.failed).length,
        'bytes': _verifiedBytes,
      });
      // Give the summary a moment to leave before the sockets close.
      await Future<void>.delayed(const Duration(milliseconds: 200));
    } finally {
      okTimer.cancel();
      heartbeat.cancel();
      _failRound = null;
    }
  }

  Future<void> _flushOk(BeamConnection ctl) async {
    if (_okPending.isEmpty) return;
    final ids = List<int>.of(_okPending);
    _okPending.clear();
    await ctl.writer.sendJson({'t': 'ok', 'f': ids});
  }

  Future<void> _handleUnit(Uint8List payload, BeamConnection ctl) async {
    final unit = decodeUnit(payload);
    final files = _files!;
    var off = unit.dataStart;
    final nacks = <List<int>>[];
    for (final s in unit.segments) {
      final start = off;
      final end = off + s.length;
      off = end;
      if (s.fileId >= files.length) throw ProtocolException('unknown file id');
      final f = files[s.fileId];
      final e = f.entry;
      if (e.isDirectory) throw ProtocolException('data for a folder');
      if (f.done || f.failed) continue; // duplicate after a resend
      if (e.isChunked) {
        if (s.piece >= e.pieceCount || s.offset != s.piece * e.pieceSize || s.length != e.pieceLength(s.piece)) {
          throw ProtocolException('bad piece bounds');
        }
        if (f.verified[s.piece]) continue;
      } else if (s.piece != 0 || s.offset != 0 || s.length != e.size) {
        throw ProtocolException('bad file bounds');
      }

      // 1) verify
      final Uint8List hash;
      if (e.isChunked) {
        hash = Blake3.pieceCv(payload, s.piece, e.pieceSize, start, end);
      } else {
        final h = Blake3Hasher()..add(payload, start, end);
        hash = h.finalize();
      }
      if (!bytesEqual(hash, s.hash)) {
        _badPieces++;
        f.failures++;
        if (f.failures > options.maxRetries) {
          await _failFile(f, 'checksum failed ${f.failures} times', ctl);
        } else {
          nacks.add([e.id, s.piece]);
        }
        continue;
      }

      // 2) write
      _currentFile = e.path;
      try {
        if (!e.isChunked) {
          await _writeWholeFile(f, payload, start, end);
          f.done = true;
          f.verifiedBytes = e.size;
          _verifiedBytes += e.size;
          _filesDone++;
          _okPending.add(e.id);
        } else {
          final wrote = await f.lock.run(() async {
            if (f.verified[s.piece] || f.failed) return false;
            f.raf ??= await _openPart(f);
            await f.raf!.setPosition(s.offset);
            await f.raf!.writeFrom(payload, start, end);
            f.verified[s.piece] = true;
            f.cvs[s.piece] = hash;
            f.verifiedCount++;
            return true;
          });
          if (wrote) {
            f.verifiedBytes += s.length;
            _verifiedBytes += s.length;
            await _maybeFinalize(f, ctl);
          }
        }
      } on FileSystemException catch (err) {
        await _failFile(f, 'could not write: ${err.osError?.message ?? err.message}', ctl);
      }
    }
    if (nacks.isNotEmpty) await ctl.writer.sendJson({'t': 'nack', 's': nacks});
  }

  Future<void> _writeWholeFile(_RxFile f, Uint8List data, int start, int end) async {
    final file = File(f.target);
    await file.parent.create(recursive: true);
    final raf = await file.open(mode: FileMode.write);
    try {
      await raf.writeFrom(data, start, end);
    } finally {
      await raf.close();
    }
    await _setModified(file, f.entry);
  }

  Future<RandomAccessFile> _openPart(_RxFile f) async {
    final file = File(f.partPath!);
    await file.parent.create(recursive: true);
    final raf = await file.open(mode: FileMode.write);
    // Reserve the full size up front: fails early if the disk is full.
    await raf.truncate(f.entry.size);
    return raf;
  }

  Future<void> _setModified(File file, ManifestEntry e) async {
    try {
      await file.setLastModified(DateTime.fromMillisecondsSinceEpoch(e.modifiedMs, isUtc: true));
    } catch (_) {
      // Some storage (e.g. certain Android folders) refuses; content is still exact.
    }
  }

  Future<void> _maybeFinalize(_RxFile f, BeamConnection ctl) async {
    final e = f.entry;
    if (!e.isChunked || f.done || f.failed || f.finalizing) return;
    if (f.verifiedCount < e.pieceCount || f.expectedRoot == null) return;
    f.finalizing = true;
    try {
      final root = Blake3.toHex(Blake3.rootFromPieceCvs(f.cvs.cast<Uint8List>()));
      if (root != f.expectedRoot) {
        await _resetFile(f, ctl);
        return;
      }
      await f.lock.run(() async {
        await f.raf!.flush();
        await f.raf!.close();
        f.raf = null;
      });
      if (options.verifyOnDisk) {
        final diskHash = await _hashFile(f.partPath!);
        if (diskHash != f.expectedRoot) {
          await _resetFile(f, ctl);
          return;
        }
      }
      await File(f.partPath!).rename(f.target);
      await _setModified(File(f.target), e);
      f.done = true;
      _filesDone++;
      _okPending.add(e.id);
    } on FileSystemException catch (err) {
      await _failFile(f, 'could not save: ${err.osError?.message ?? err.message}', ctl);
    } finally {
      f.finalizing = false;
    }
  }

  /// Full-file hash mismatch: forget all pieces and ask for the file again.
  Future<void> _resetFile(_RxFile f, BeamConnection ctl) async {
    f.failures++;
    _verifiedBytes -= f.verifiedBytes;
    f.verifiedBytes = 0;
    f.verifiedCount = 0;
    f.verified.fillRange(0, f.verified.length, false);
    f.cvs.fillRange(0, f.cvs.length, null);
    if (f.failures > options.maxRetries) {
      await _failFile(f, 'file hash did not match', ctl);
      return;
    }
    await ctl.writer.sendJson({'t': 'bad', 'f': f.entry.id});
  }

  Future<String> _hashFile(String path) async {
    final h = Blake3Hasher();
    await for (final chunk in File(path).openRead()) {
      h.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
    }
    return Blake3.toHex(h.finalize());
  }

  Future<void> _failFile(_RxFile f, String reason, BeamConnection ctl) async {
    if (f.failed) return;
    f.failed = true;
    _errors.add('${f.entry.path}: $reason');
    await f.lock.run(() async {
      try {
        await f.raf?.close();
      } catch (_) {}
      f.raf = null;
      if (f.partPath != null) {
        try {
          await File(f.partPath!).delete();
        } catch (_) {}
      }
    });
    try {
      await ctl.writer.sendJson({'t': 'fail', 'f': f.entry.id, 'r': reason});
    } catch (e) {
      _failRound?.call(e);
    }
  }

  /// Deletes half-received big files (finished files are always kept).
  Future<void> _cleanupIncomplete() async {
    for (final f in _files ?? <_RxFile>[]) {
      if (f.done || f.partPath == null) continue;
      try {
        // Take the file lock so a write still in progress finishes first.
        await f.lock.run(() async {
          await f.raf?.close();
          f.raf = null;
        }).timeout(const Duration(seconds: 5));
      } catch (_) {}
      try {
        final part = File(f.partPath!);
        if (await part.exists()) await part.delete();
      } catch (_) {}
    }
  }
}
