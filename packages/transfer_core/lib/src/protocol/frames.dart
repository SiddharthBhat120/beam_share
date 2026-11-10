// Wire framing.
//
// Every message on a TCP (TLS) connection is a frame:
//
//   [1 byte type][4 bytes big-endian payload length][payload]
//
// type 1 = JSON control message (UTF-8), type 2 = binary data unit.
// Frames are length-prefixed so the reader never has to scan for delimiters
// and big data frames can be received with a single copy.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../util/async_utils.dart';

const int frameJson = 1;
const int frameData = 2;
const int _headerLen = 5;

/// Largest frame we accept (protects against garbage or attacks).
const int maxFrameLength = 64 * 1024 * 1024;

class Frame {
  Frame(this.type, this.payload);
  final int type;
  final Uint8List payload;

  Map<String, dynamic> get json =>
      jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
}

class ProtocolException implements Exception {
  ProtocolException(this.message);
  final String message;
  @override
  String toString() => 'ProtocolException: $message';
}

/// Reads frames from a byte stream with TCP back-pressure.
///
/// When more than [_highWater] bytes are buffered the socket subscription is
/// paused, so a slow disk on the receiver slows down the sender instead of
/// filling up memory.
class FrameReader {
  FrameReader(Stream<Uint8List> source) {
    _sub = source.listen(_onData, onError: _onError, onDone: _onDone);
  }

  static const int _highWater = 24 * 1024 * 1024;

  late final StreamSubscription<Uint8List> _sub;
  final _chunks = ListQueue<Uint8List>();
  int _firstOffset = 0; // bytes already consumed from _chunks.first
  int _buffered = 0;
  bool _done = false;
  Object? _error;
  Completer<void>? _waiter;

  /// Total bytes received so far (for statistics).
  int bytesReceived = 0;

  void _onData(Uint8List chunk) {
    _chunks.add(chunk);
    _buffered += chunk.length;
    bytesReceived += chunk.length;
    if (_buffered > _highWater && !_sub.isPaused) _sub.pause();
    _wake();
  }

  void _onError(Object e) {
    _error ??= e;
    _wake();
  }

  void _onDone() {
    _done = true;
    _wake();
  }

  void _wake() {
    final w = _waiter;
    _waiter = null;
    w?.complete();
  }

  /// Returns the next frame, or null when the stream ended cleanly.
  Future<Frame?> next() async {
    while (true) {
      final frame = _tryParse();
      if (frame != null) return frame;
      if (_error != null) throw _error!;
      if (_done) {
        if (_buffered > 0) throw ProtocolException('connection closed mid-frame');
        return null;
      }
      if (_sub.isPaused) _sub.resume();
      _waiter = Completer<void>();
      await _waiter!.future;
    }
  }

  /// Next frame that must be JSON; throws on end of stream.
  Future<Map<String, dynamic>> nextJson() async {
    final f = await next();
    if (f == null) throw ProtocolException('connection closed');
    if (f.type != frameJson) throw ProtocolException('expected JSON frame');
    return f.json;
  }

  int _peekByte(int index) {
    var i = index + _firstOffset;
    for (final c in _chunks) {
      if (i < c.length) return c[i];
      i -= c.length;
    }
    throw StateError('peek out of range');
  }

  Frame? _tryParse() {
    if (_buffered < _headerLen) return null;
    final type = _peekByte(0);
    final len = (_peekByte(1) << 24) | (_peekByte(2) << 16) | (_peekByte(3) << 8) | _peekByte(4);
    if (type != frameJson && type != frameData) {
      throw ProtocolException('unknown frame type $type');
    }
    if (len > maxFrameLength) throw ProtocolException('frame too large: $len');
    if (_buffered < _headerLen + len) return null;
    _consume(_headerLen);
    return Frame(type, _take(len));
  }

  void _consume(int n) {
    while (n > 0) {
      final first = _chunks.first;
      final avail = first.length - _firstOffset;
      if (n < avail) {
        _firstOffset += n;
        _buffered -= n;
        return;
      }
      n -= avail;
      _buffered -= avail;
      _chunks.removeFirst();
      _firstOffset = 0;
    }
  }

  Uint8List _take(int n) {
    if (n == 0) return Uint8List(0);
    final first = _chunks.first;
    // Fast path: the whole payload sits inside one received chunk.
    if (first.length - _firstOffset >= n) {
      final view = Uint8List.sublistView(first, _firstOffset, _firstOffset + n);
      _consume(n);
      return view;
    }
    final out = Uint8List(n);
    var filled = 0;
    while (filled < n) {
      final c = _chunks.first;
      final avail = c.length - _firstOffset;
      final take = avail < n - filled ? avail : n - filled;
      out.setRange(filled, filled + take, c, _firstOffset);
      filled += take;
      _consume(take);
    }
    return out;
  }

  Future<void> cancel() => _sub.cancel();
}

/// Writes frames to a socket. Calls are serialized by a [Mutex].
class FrameWriter {
  FrameWriter(this._socket);

  final Socket _socket;
  final _lock = Mutex();
  int bytesWritten = 0;

  static Uint8List _header(int type, int len) {
    final h = Uint8List(_headerLen);
    h[0] = type;
    h[1] = (len >> 24) & 0xFF;
    h[2] = (len >> 16) & 0xFF;
    h[3] = (len >> 8) & 0xFF;
    h[4] = len & 0xFF;
    return h;
  }

  Future<void> sendJson(Map<String, Object?> message) {
    final body = utf8.encode(jsonEncode(message));
    return _lock.run(() async {
      _socket.add(_header(frameJson, body.length));
      _socket.add(body);
      bytesWritten += _headerLen + body.length;
      await _socket.flush();
    });
  }

  /// Sends one data frame made of several byte parts (no concatenation copy).
  Future<void> sendData(List<Uint8List> parts) {
    var len = 0;
    for (final p in parts) {
      len += p.length;
    }
    return _lock.run(() async {
      _socket.add(_header(frameData, len));
      for (final p in parts) {
        _socket.add(p);
      }
      bytesWritten += _headerLen + len;
      await _socket.flush();
    });
  }
}
