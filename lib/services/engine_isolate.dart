// Runs the transfer engine in a background isolate.
//
// Hashing gigabytes and handling TLS is CPU work. Doing it on the UI thread
// would make animations stutter, so the engine lives in its own isolate
// (a separate thread with its own memory). The UI talks to it with simple
// map messages:
//
//   UI -> engine:  {'cmd': 'listen' | 'dial' | 'requestReply' | 'pause' |
//                   'resume' | 'cancel' | 'stopListening', ...}
//   engine -> UI:  {'ev': 'listening' | 'request' | 'started' | 'progress' |
//                   'finished' | 'error', ...}

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:transfer_core/transfer_core.dart';

import '../models/picked_item.dart';

class EngineClient {
  EngineClient._(this._isolate, this._toEngine, this._events);

  final Isolate _isolate;
  final SendPort _toEngine;
  final Stream<Map<String, dynamic>> _events;

  Stream<Map<String, dynamic>> get events => _events;

  static Future<EngineClient> spawn() async {
    final fromEngine = ReceivePort();
    final isolate = await Isolate.spawn(_engineMain, [fromEngine.sendPort, RootIsolateToken.instance],
        debugName: 'beam-engine');
    final broadcast = fromEngine.asBroadcastStream();
    final toEngine = await broadcast.first as SendPort;
    final events = broadcast.where((m) => m is Map).map((m) => (m as Map).cast<String, dynamic>());
    return EngineClient._(isolate, toEngine, events.asBroadcastStream());
  }

  void send(Map<String, Object?> command) => _toEngine.send(command);

  void dispose() => _isolate.kill(priority: Isolate.immediate);
}

// ---------------------------------------------------------------------------
// Everything below runs inside the engine isolate.
// ---------------------------------------------------------------------------

Future<void> _engineMain(List<Object?> args) async {
  final toUi = args[0] as SendPort;
  final token = args[1] as RootIsolateToken?;
  // Lets this isolate call the Android "beam/files" channel directly.
  if (token != null) BackgroundIsolateBinaryMessenger.ensureInitialized(token);
  final inbox = ReceivePort();
  toUi.send(inbox.sendPort);
  final host = _EngineHost(toUi);
  await for (final msg in inbox) {
    if (msg is Map) {
      try {
        await host.handle(msg.cast<String, dynamic>());
      } catch (e) {
        toUi.send({'ev': 'error', 'message': e.toString()});
      }
    }
  }
}

class _EngineHost {
  _EngineHost(this.toUi);

  final SendPort toUi;
  BeamServer? _server;
  TransferSender? _sender;
  TransferReceiver? _receiver;
  bool _busy = false;
  bool _abortDial = false;
  int _requestSeq = 0;
  final _pendingRequests = <int, Completer<bool>>{};

  Future<void> handle(Map<String, dynamic> m) async {
    switch (m['cmd']) {
      case 'listen':
        await _listen(m);
      case 'stopListening':
        await _server?.close();
        _server = null;
      case 'dial':
        // Not awaited: waiting for the other user to tap "Accept" can take a
        // while, and "cancel" must still be handled in the meantime.
        unawaited(_dial(m));
      case 'requestReply':
        _pendingRequests.remove(m['id'] as int)?.complete(m['accept'] as bool);
      case 'pause':
        _sender?.pause();
        _receiver?.pause();
      case 'resume':
        _sender?.resume();
        _receiver?.resume();
      case 'cancel':
        if (_sender == null && _receiver == null) _abortDial = true;
        await _sender?.cancel();
        await _receiver?.cancel();
    }
  }

  BeamIdentity _identity(Map<String, dynamic> m) =>
      BeamIdentity.fromJson((m['identity'] as Map).cast<String, dynamic>());

  DeviceInfo _me(Map<String, dynamic> m) => DeviceInfo.fromJson((m['me'] as Map).cast<String, dynamic>());

  Future<void> _listen(Map<String, dynamic> m) async {
    await _server?.close();
    final role = m['role'] as String;
    final server = await BeamServer.start(
      me: _me(m),
      myRole: role,
      identity: _identity(m),
      token: m['token'] as String?,
      port: m['port'] as int? ?? 0,
      onRequest: (req) async {
        if (_busy) return false;
        final id = ++_requestSeq;
        final c = Completer<bool>();
        _pendingRequests[id] = c;
        toUi.send({
          'ev': 'request',
          'id': id,
          'device': req.device.toJson(),
          'files': req.fileCount,
          'bytes': req.totalBytes,
        });
        return c.future.timeout(const Duration(seconds: 80), onTimeout: () => false);
      },
    );
    _server = server;
    server.sessions.listen((link) {
      if (_busy) {
        link.close();
        return;
      }
      _startJob(link, role, m);
    });
    toUi.send({'ev': 'listening', 'port': server.port});
  }

  Future<void> _dial(Map<String, dynamic> m) async {
    if (_busy) return;
    final role = m['role'] as String;
    _busy = true;
    _abortDial = false;
    try {
      final link = await DialerLink.connect(
        hosts: (m['hosts'] as List).cast<String>(),
        port: m['port'] as int,
        fingerprint: m['fingerprint'] as String?,
        me: _me(m),
        role: role,
        token: m['token'] as String?,
        offer: (m['offer'] as Map?)?.cast<String, Object?>(),
      );
      _busy = false;
      if (_abortDial) {
        // The user left the screen while we were connecting.
        _abortDial = false;
        await link.close();
        return;
      }
      _startJob(link, role, m);
    } on PairingRejected catch (e) {
      _busy = false;
      toUi.send({'ev': 'error', 'message': e.reason, 'rejected': true});
    } catch (e) {
      _busy = false;
      toUi.send({'ev': 'error', 'message': _friendly(e)});
    }
  }

  String _friendly(Object e) {
    final s = e.toString();
    if (s.contains('fingerprint')) return 'Security check failed: this is not the device from the code.';
    if (s.contains('SocketException') || s.contains('Timeout')) {
      return 'Could not reach the other device. Make sure both are on the same Wi-Fi or hotspot.';
    }
    return s;
  }

  void _startJob(SessionLink link, String role, Map<String, dynamic> m) {
    _busy = true;
    final options = const TransferOptions();
    final Future<TransferSummary> job;
    Stream<TransferProgress> progress;
    if (role == 'sender') {
      final items = (m['items'] as List).map((e) => PickedItem.fromMap(e as Map)).toList();
      final sender = TransferSender(link: link, sources: items.map(_toSource).toList(), options: options);
      _sender = sender;
      progress = sender.progress;
      job = sender.run();
    } else {
      final receiver = TransferReceiver(link: link, destination: m['dest'] as String, options: options);
      _receiver = receiver;
      progress = receiver.progress;
      job = receiver.run();
    }
    toUi.send({'ev': 'started', 'peer': link.peer.toJson(), 'role': role});
    final sub = progress.listen((p) => toUi.send({'ev': 'progress', ...p.toJson()}));
    job.then((summary) async {
      await sub.cancel();
      final saved = role == 'receiver' ? _receiver?.savedFiles ?? const <String>[] : const <String>[];
      toUi.send({
        'ev': 'finished',
        'summary': summary.toJson(),
        'saved': saved.length > 20000 ? saved.sublist(0, 20000) : saved,
        'peer': link.peer.toJson(),
        'role': role,
      });
    }).whenComplete(() {
      _busy = false;
      _sender = null;
      _receiver = null;
    });
  }

  SourceFile _toSource(PickedItem i) {
    final modified = DateTime.fromMillisecondsSinceEpoch(i.modifiedMs);
    switch (i.kind) {
      case 'dir':
        return DirectorySource(i.relativePath, modified);
      case 'uri':
        return CallbackSourceFile(
          relativePath: i.relativePath,
          size: i.size,
          modified: modified,
          opener: () => _AndroidUriReader.open(i.uri!),
        );
      default:
        return LocalSourceFile(File(i.path!), i.relativePath, size: i.size, modified: modified);
    }
  }
}

/// Reads an Android content:// URI through Kotlin (raw bytes, any offset).
class _AndroidUriReader implements SourceReader {
  _AndroidUriReader(this._handle);

  // Runs on a background thread on the Kotlin side (TaskQueue).
  static const _ch = MethodChannel('beam/files');
  final int _handle;

  static Future<SourceReader> open(String uri) async {
    final h = await _ch.invokeMethod<int>('open', {'uri': uri});
    if (h == null) throw const FileSystemException('cannot open file');
    return _AndroidUriReader(h);
  }

  @override
  Future<Uint8List> readAt(int offset, int length) async {
    final data = await _ch.invokeMethod<Uint8List>('read', {'h': _handle, 'offset': offset, 'length': length});
    return data ?? Uint8List(0);
  }

  @override
  Future<void> close() async {
    await _ch.invokeMethod('close', {'h': _handle});
  }
}
