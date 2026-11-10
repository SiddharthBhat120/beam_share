// Connections between two devices.
//
// A transfer uses one *control* connection (small JSON messages) and N
// *data* connections (big binary pieces, sent in parallel). Together they
// form a "round". If Wi-Fi drops, the round dies; the dialing side reconnects
// and a new round starts, and the transfer continues where it left off.
//
// Either device can be the one that dials:
//  * QR flow: the device showing the QR listens, the scanner dials.
//  * Nearby flow: the waiting receiver listens, the sender dials.
// So the link layer knows nothing about sending/receiving; it only
// delivers rounds to TransferSender / TransferReceiver.

import 'dart:async';
import 'dart:io';

import '../model/progress.dart';
import '../protocol/frames.dart';
import 'identity.dart';
import 'socket_tuning.dart';

const int protocolVersion = 1;

class LinkOptions {
  const LinkOptions({
    this.dataStreams = 3,
    this.secure = true,
    this.connectTimeout = const Duration(seconds: 8),
    this.reconnectWindow = const Duration(minutes: 2),
    this.acceptTimeout = const Duration(seconds: 90),
    this.socketBufferBytes = 4 * 1024 * 1024,
  });

  /// Parallel data connections (2-4 is the sweet spot on Wi-Fi).
  final int dataStreams;

  /// TLS encryption. Only the benchmark turns this off, to compare.
  final bool secure;
  final Duration connectTimeout;

  /// How long to keep trying to reconnect after the link dropped.
  final Duration reconnectWindow;

  /// How long the dialer waits for the other user to tap "Accept".
  final Duration acceptTimeout;
  final int socketBufferBytes;
}

/// One framed TCP/TLS connection.
class BeamConnection {
  BeamConnection(this.socket)
      : reader = FrameReader(socket),
        writer = FrameWriter(socket);

  final Socket socket;
  final FrameReader reader;
  final FrameWriter writer;

  void destroy() {
    try {
      socket.destroy();
    } catch (_) {}
  }
}

/// The connections of one round.
class RoundConnections {
  RoundConnections(this.round, this.control, this.data);
  final int round;
  final BeamConnection control;
  final List<BeamConnection> data;

  void close() {
    control.destroy();
    for (final d in data) {
      d.destroy();
    }
  }
}

/// What TransferSender / TransferReceiver use.
abstract class SessionLink {
  DeviceInfo get peer;

  /// Returns the next set of connections. The first call returns the
  /// initial round; later calls reconnect (or wait for the peer to).
  Future<RoundConnections> nextRound();

  Future<void> close();
}

// ---------------------------------------------------------------------------
// Dialing side
// ---------------------------------------------------------------------------

Future<BeamConnection> _dial(String host, int port, String? fingerprint, LinkOptions o) async {
  final raw = await Socket.connect(host, port, timeout: o.connectTimeout);
  tuneSocket(raw, bufferBytes: o.socketBufferBytes);
  if (!o.secure) return BeamConnection(raw);
  bool pinned(X509Certificate c) => fingerprint != null && fingerprintOfDer(c.der) == fingerprint;
  try {
    final s = await SecureSocket.secure(raw, onBadCertificate: pinned).timeout(o.connectTimeout);
    final cert = s.peerCertificate;
    if (cert == null || !pinned(cert)) {
      s.destroy();
      throw const HandshakeException('certificate fingerprint does not match the pairing code');
    }
    return BeamConnection(s);
  } catch (_) {
    raw.destroy();
    rethrow;
  }
}

/// Tries all [hosts] at once and keeps the first that answers.
Future<(BeamConnection, String)> _dialAny(
    List<String> hosts, int port, String? fingerprint, LinkOptions o) {
  final done = Completer<(BeamConnection, String)>();
  var pending = hosts.length;
  Object? lastError;
  if (hosts.isEmpty) return Future.error(const SocketException('no address to connect to'));
  for (final h in hosts) {
    _dial(h, port, fingerprint, o).then((c) {
      if (done.isCompleted) {
        c.destroy();
      } else {
        done.complete((c, h));
      }
    }, onError: (Object e) {
      lastError = e;
      if (--pending == 0 && !done.isCompleted) done.completeError(lastError!);
    });
  }
  return done.future;
}

class DialerLink implements SessionLink {
  DialerLink._(this._hosts, this._port, this._fingerprint, this._me, this._role, this._token,
      this._offer, this._options);

  /// Connects to a listening device and performs the first round.
  ///
  /// [role] is what *this* device does ("sender" or "receiver"). [offer] is
  /// shown to the other user (e.g. {'files': 12, 'bytes': 123456}).
  /// Throws [PairingRejected] if the other user declines.
  static Future<DialerLink> connect({
    required List<String> hosts,
    required int port,
    required String? fingerprint,
    required DeviceInfo me,
    required String role,
    String? token,
    Map<String, Object?>? offer,
    LinkOptions options = const LinkOptions(),
  }) async {
    final link = DialerLink._(hosts, port, fingerprint, me, role, token, offer, options);
    link._pending = await link._openRound(hosts, first: true);
    return link;
  }

  final List<String> _hosts;
  final int _port;
  final String? _fingerprint;
  final DeviceInfo _me;
  final String _role;
  final String? _token;
  final Map<String, Object?>? _offer;
  final LinkOptions _options;

  final String sessionId = randomToken();
  int _round = 0;
  String? _goodHost;
  RoundConnections? _pending;
  RoundConnections? _current;
  bool _closed = false;
  late DeviceInfo _peer;

  @override
  DeviceInfo get peer => _peer;

  @override
  Future<RoundConnections> nextRound() async {
    if (_pending != null) {
      _current = _pending;
      _pending = null;
      return _current!;
    }
    _current?.close();
    _current = null;
    final deadline = DateTime.now().add(_options.reconnectWindow);
    var delay = const Duration(milliseconds: 300);
    while (true) {
      if (_closed) throw TransferCancelled();
      try {
        final hosts = [?_goodHost, ..._hosts.where((h) => h != _goodHost)];
        _current = await _openRound(hosts, first: false);
        return _current!;
      } on PairingRejected {
        rethrow;
      } catch (_) {
        if (DateTime.now().isAfter(deadline)) rethrow;
        await Future<void>.delayed(delay);
        delay = delay * 2 > const Duration(seconds: 3) ? const Duration(seconds: 3) : delay * 2;
      }
    }
  }

  Future<RoundConnections> _openRound(List<String> hosts, {required bool first}) async {
    _round++;
    final (control, host) = await _dialAny(hosts, _port, _fingerprint, _options);
    final opened = <BeamConnection>[control];
    try {
      await control.writer.sendJson({
        't': 'hello',
        'v': protocolVersion,
        'kind': 'control',
        'sid': sessionId,
        'round': _round,
        'streams': _options.dataStreams,
        'token': _token,
        'role': _role,
        'device': _me.toJson(),
        'offer': _offer,
      });
      final reply = await control.reader
          .nextJson()
          .timeout(first ? _options.acceptTimeout : _options.connectTimeout * 2);
      if (reply['t'] == 'reject') {
        throw PairingRejected(reply['reason'] as String? ?? 'declined');
      }
      if (reply['t'] != 'welcome') throw ProtocolException('expected welcome');
      _peer = DeviceInfo.fromJson((reply['device'] as Map).cast<String, dynamic>());
      _goodHost = host;
      final data = await Future.wait([
        for (var i = 0; i < _options.dataStreams; i++) _openData(host, i, opened),
      ]);
      return RoundConnections(_round, control, data);
    } catch (_) {
      for (final c in opened) {
        c.destroy();
      }
      rethrow;
    }
  }

  Future<BeamConnection> _openData(String host, int index, List<BeamConnection> opened) async {
    final c = await _dial(host, _port, _fingerprint, _options);
    opened.add(c);
    await c.writer.sendJson({
      't': 'hello',
      'v': protocolVersion,
      'kind': 'data',
      'sid': sessionId,
      'round': _round,
      'idx': index,
    });
    final reply = await c.reader.nextJson().timeout(_options.connectTimeout * 2);
    if (reply['t'] != 'welcome') throw ProtocolException('data connection refused');
    return c;
  }

  /// Testing: kill the current connections to simulate Wi-Fi dropping.
  void debugDropConnections() => _current?.close();

  @override
  Future<void> close() async {
    _closed = true;
    _pending?.close();
    _current?.close();
  }
}

// ---------------------------------------------------------------------------
// Listening side
// ---------------------------------------------------------------------------

/// Shown to the user before accepting a connection without the QR token.
class IncomingRequest {
  IncomingRequest({required this.device, required this.role, this.fileCount, this.totalBytes});
  final DeviceInfo device;

  /// Role of the *remote* device.
  final String role;
  final int? fileCount;
  final int? totalBytes;
}

class BeamServer {
  BeamServer._(this._socket, this._me, this._myRole, this._identity, this._token,
      this._onRequest, this._options);

  /// Starts listening. [myRole] is what this device does; peers must have the
  /// opposite role. Connections presenting [token] (from our QR code) are
  /// accepted at once, others go through [onRequest] (the "Accept?" dialog).
  static Future<BeamServer> start({
    required DeviceInfo me,
    required String myRole,
    required BeamIdentity? identity,
    String? token,
    Future<bool> Function(IncomingRequest request)? onRequest,
    int port = 0,
    LinkOptions options = const LinkOptions(),
  }) async {
    if (options.secure && identity == null) {
      throw ArgumentError('identity required for TLS');
    }
    final ss = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    final server = BeamServer._(ss, me, myRole, identity, token, onRequest, options);
    ss.listen(server._onSocket, onError: (_) {});
    return server;
  }

  final ServerSocket _socket;
  final DeviceInfo _me;
  final String _myRole;
  final BeamIdentity? _identity;
  final String? _token;
  final Future<bool> Function(IncomingRequest)? _onRequest;
  final LinkOptions _options;
  final _links = <String, ListenerLink>{};
  final _sessions = StreamController<ListenerLink>.broadcast();
  late final SecurityContext? _context = _identity?.serverContext();

  int get port => _socket.port;

  /// New accepted transfers.
  Stream<ListenerLink> get sessions => _sessions.stream;

  Future<void> close() async {
    await _socket.close();
    for (final l in _links.values.toList()) {
      await l.close();
    }
    await _sessions.close();
  }

  Future<void> _onSocket(Socket raw) async {
    BeamConnection? conn;
    try {
      tuneSocket(raw, bufferBytes: _options.socketBufferBytes);
      if (_options.secure) {
        final s = await SecureSocket.secureServer(raw, _context).timeout(_options.connectTimeout);
        conn = BeamConnection(s);
      } else {
        conn = BeamConnection(raw);
      }
      final hello = await conn.reader.nextJson().timeout(_options.connectTimeout);
      if (hello['t'] != 'hello') throw ProtocolException('expected hello');
      if (hello['v'] != protocolVersion) {
        await conn.writer.sendJson({'t': 'reject', 'reason': 'app version mismatch, please update'});
        conn.destroy();
        return;
      }
      final sid = hello['sid'] as String;
      final round = hello['round'] as int;
      if (hello['kind'] == 'control') {
        await _onControl(conn, hello, sid, round);
      } else {
        final link = _links[sid];
        final idx = hello['idx'] as int;
        if (link == null || !link._canAcceptData(round, idx)) {
          conn.destroy();
          return;
        }
        await conn.writer.sendJson({'t': 'welcome'});
        link._addData(round, idx, conn);
      }
    } catch (_) {
      if (conn != null) {
        conn.destroy();
      } else {
        raw.destroy();
      }
    }
  }

  Future<void> _onControl(BeamConnection conn, Map<String, dynamic> hello, String sid, int round) async {
    final streams = (hello['streams'] as int).clamp(1, 8);
    final existing = _links[sid];
    if (existing != null) {
      // Reconnect of a running transfer (session id is a secret only the
      // authenticated peer knows).
      if (round <= existing._round) {
        conn.destroy();
        return;
      }
      await conn.writer.sendJson({'t': 'welcome', 'device': _me.toJson()});
      existing._beginRound(round, conn, streams);
      return;
    }
    final peerRole = hello['role'] as String? ?? '';
    if (peerRole == _myRole || (peerRole != 'sender' && peerRole != 'receiver')) {
      await conn.writer.sendJson({
        't': 'reject',
        'reason': _myRole == 'sender' ? 'this device is sending, not receiving' : 'this device is receiving',
      });
      conn.destroy();
      return;
    }
    final device = DeviceInfo.fromJson((hello['device'] as Map).cast<String, dynamic>());
    final offer = (hello['offer'] as Map?)?.cast<String, dynamic>();
    var accepted = _token != null && hello['token'] == _token;
    if (!accepted && _onRequest != null) {
      accepted = await _onRequest(IncomingRequest(
        device: device,
        role: peerRole,
        fileCount: offer?['files'] as int?,
        totalBytes: offer?['bytes'] as int?,
      ));
    }
    if (!accepted) {
      await conn.writer.sendJson({'t': 'reject', 'reason': 'declined'});
      conn.destroy();
      return;
    }
    final link = ListenerLink._(this, sid, device, peerRole, _options.reconnectWindow);
    _links[sid] = link;
    await conn.writer.sendJson({'t': 'welcome', 'device': _me.toJson()});
    link._beginRound(round, conn, streams);
    _sessions.add(link);
  }
}

class ListenerLink implements SessionLink {
  ListenerLink._(this._server, this.sessionId, this.peer, this.peerRole, this._reconnectWindow);

  final BeamServer _server;
  final String sessionId;
  @override
  final DeviceInfo peer;

  /// "sender" or "receiver": what the remote device does.
  final String peerRole;
  final Duration _reconnectWindow;

  int _round = 0;
  BeamConnection? _control;
  List<BeamConnection?> _data = [];
  RoundConnections? _ready;
  RoundConnections? _current;
  Completer<void>? _waiter;
  bool _closed = false;

  void _beginRound(int round, BeamConnection control, int streams) {
    // A newer round means the old connections are dead (or about to be).
    _current?.close();
    _current = null;
    _ready?.close();
    _ready = null;
    _control?.destroy();
    for (final d in _data) {
      d?.destroy();
    }
    _round = round;
    _control = control;
    _data = List<BeamConnection?>.filled(streams, null);
  }

  bool _canAcceptData(int round, int idx) =>
      !_closed && round == _round && _control != null && idx >= 0 && idx < _data.length && _data[idx] == null;

  void _addData(int round, int idx, BeamConnection c) {
    if (!_canAcceptData(round, idx)) {
      c.destroy();
      return;
    }
    _data[idx] = c;
    if (_data.every((d) => d != null)) {
      _ready = RoundConnections(_round, _control!, _data.cast<BeamConnection>());
      _control = null;
      _data = [];
      final w = _waiter;
      _waiter = null;
      w?.complete();
    }
  }

  @override
  Future<RoundConnections> nextRound() async {
    _current?.close();
    _current = null;
    final deadline = DateTime.now().add(_reconnectWindow);
    while (_ready == null) {
      if (_closed) throw TransferCancelled();
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        throw TimeoutException('The other device did not reconnect');
      }
      final w = _waiter ??= Completer<void>();
      await w.future.timeout(left, onTimeout: () {});
    }
    _current = _ready;
    _ready = null;
    return _current!;
  }

  @override
  Future<void> close() async {
    _closed = true;
    _server._links.remove(sessionId);
    _current?.close();
    _ready?.close();
    _control?.destroy();
    for (final d in _data) {
      d?.destroy();
    }
    final w = _waiter;
    _waiter = null;
    w?.complete();
  }
}
