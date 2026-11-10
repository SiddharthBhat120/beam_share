// The "brain" between the screens and the engine isolate.
//
// Screens call methods like startHosting() or connectWithCode() and rebuild
// whenever this ChangeNotifier changes. Events from the engine isolate
// (progress, finished, incoming request, ...) update the fields below.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:transfer_core/transfer_core.dart';

import '../models/picked_item.dart';
import '../services/discovery.dart';
import '../services/engine_isolate.dart';
import '../services/platform_bridge.dart';
import 'app_state.dart';

enum Stage { idle, preparing, waiting, connecting, transferring, finished }

class PendingRequest {
  PendingRequest(this.id, this.device, this.files, this.bytes);
  final int id;
  final DeviceInfo device;
  final int? files;
  final int? bytes;
}

class TransferController extends ChangeNotifier {
  TransferController(this.app);

  final AppState app;
  final discovery = DiscoveryService();
  EngineClient? _engine;
  StreamSubscription<Map<String, dynamic>>? _sub;
  StreamSubscription<List<NearbyDevice>>? _nearbySub;

  Stage stage = Stage.idle;

  /// "sender" or "receiver" for the current session.
  String role = 'sender';
  List<PickedItem> items = [];
  PairingInfo? myCode;
  HotspotInfo? hotspot;
  String? status; // short line like "Joining DIRECT-bs-..." for the UI
  String? error;
  DeviceInfo? peer;
  TransferProgress? progress;
  TransferSummary? summary;
  PendingRequest? request;
  List<NearbyDevice> nearby = const [];
  bool _joinedWifi = false;
  Completer<int>? _listening;
  Completer<void>? _dialResult;

  int get itemFileCount => items.where((i) => !i.isDir).length;
  int get itemBytes => items.fold(0, (s, i) => s + (i.isDir ? 0 : i.size));

  Future<EngineClient> _ensureEngine() async {
    if (_engine != null) return _engine!;
    final e = await EngineClient.spawn();
    _engine = e;
    _sub = e.events.listen(_onEvent);
    return e;
  }

  void _set(VoidCallback f) {
    f();
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Hosting: show a QR code (and be visible to nearby devices).
  // -------------------------------------------------------------------------

  /// Starts listening. For a sender, [items] must be set first.
  Future<void> startHosting({required String asRole}) async {
    await stopSession(keepItems: true);
    _set(() {
      role = asRole;
      stage = Stage.preparing;
      error = null;
      status = 'Getting ready...';
    });
    final engine = await _ensureEngine();
    final token = randomToken();
    _listening = Completer<int>();
    engine.send({
      'cmd': 'listen',
      'role': asRole,
      'token': token,
      'identity': app.identity.toJson(),
      'me': app.me.toJson(),
      'items': asRole == 'sender' ? [for (final i in items) i.toMap()] : null,
      'dest': app.receiveDir,
    });
    final port = await _listening!.future;

    // Offline network for the other device to join (Android / Windows).
    if (app.offlineMode && PlatformBridge.canHostHotspot) {
      _set(() => status = 'Creating offline Wi-Fi...');
      hotspot = await PlatformBridge.startHotspot(app.deviceName);
      if (hotspot != null) await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    final hosts = await PlatformBridge.localIPv4s();
    myCode = PairingInfo(
      deviceName: app.deviceName,
      platform: PlatformBridge.platformName,
      hosts: hosts,
      port: port,
      fingerprint: app.identity.fingerprint,
      token: token,
      role: asRole,
      ssid: hotspot?.ssid,
      passphrase: hotspot?.passphrase,
    );
    if (asRole == 'receiver') {
      await discovery.advertise(me: app.me, port: port, fingerprint: app.identity.fingerprint);
    } else {
      _nearbySub = discovery.devices.listen((d) => _set(() => nearby = d));
      await discovery.browse(myId: app.deviceId);
    }
    _set(() {
      stage = Stage.waiting;
      status = hotspot != null
          ? 'Offline Wi-Fi "${hotspot!.ssid}" is on'
          : (hosts.isEmpty ? 'No network: turn on Wi-Fi or a hotspot' : 'Using the current Wi-Fi network');
    });
  }

  // -------------------------------------------------------------------------
  // Dialing: after scanning a QR code or tapping a nearby device.
  // -------------------------------------------------------------------------

  /// Connects using a scanned/pasted code. [asRole] is what *this* device does.
  Future<void> connectWithCode(PairingInfo code, {required String asRole}) async {
    if (code.role == asRole) {
      _set(() => error = asRole == 'receiver'
          ? 'That code is from a device that is also receiving. Scan the code on the sending device.'
          : 'That code is from a device that is also sending. Scan the code on the receiving device.');
      return;
    }
    await _pauseHosting();
    _set(() {
      role = asRole;
      stage = Stage.connecting;
      error = null;
      status = 'Connecting to ${code.deviceName}...';
    });
    var reachable = await _anyReachable(code.hosts, code.port, const Duration(milliseconds: 1500));
    if (!reachable && code.ssid != null) {
      _set(() => status = 'Joining "${code.ssid}"...');
      final joined = await PlatformBridge.joinWifi(code.ssid!, code.passphrase ?? '');
      _joinedWifi = joined;
      if (!joined) {
        _set(() {
          stage = Stage.idle;
          error = 'Could not join the Wi-Fi "${code.ssid}". Join it in Wi-Fi settings, then scan again.';
        });
        return;
      }
      _set(() => status = 'Connected to Wi-Fi, opening a secure link...');
      // DHCP can take a few seconds after joining.
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      while (!reachable && DateTime.now().isBefore(deadline)) {
        reachable = await _anyReachable(code.hosts, code.port, const Duration(seconds: 1));
        if (!reachable) await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    }
    await _dial(
      hosts: code.hosts,
      port: code.port,
      fingerprint: code.fingerprint,
      token: code.token,
    );
  }

  Future<void> connectToNearby(NearbyDevice d) async {
    await _pauseHosting();
    _set(() {
      role = 'sender';
      stage = Stage.connecting;
      error = null;
      status = 'Waiting for ${d.name} to accept...';
    });
    await _dial(hosts: d.hosts, port: d.port, fingerprint: d.fingerprint, token: null);
  }

  Future<void> _dial({required List<String> hosts, required int port, required String fingerprint, String? token}) async {
    final engine = await _ensureEngine();
    _dialResult = Completer<void>();
    engine.send({
      'cmd': 'dial',
      'role': role,
      'hosts': hosts,
      'port': port,
      'fingerprint': fingerprint,
      'token': token,
      'identity': app.identity.toJson(),
      'me': app.me.toJson(),
      'items': role == 'sender' ? [for (final i in items) i.toMap()] : null,
      'dest': app.receiveDir,
      'offer': role == 'sender' ? {'files': itemFileCount, 'bytes': itemBytes} : null,
    });
    await _dialResult!.future;
  }

  Future<bool> _anyReachable(List<String> hosts, int port, Duration timeout) async {
    if (hosts.isEmpty) return false;
    final results = await Future.wait(hosts.map((h) async {
      try {
        final s = await Socket.connect(h, port, timeout: timeout);
        s.destroy();
        return true;
      } catch (_) {
        return false;
      }
    }));
    return results.contains(true);
  }

  /// Stops advertising while we dial somebody else.
  Future<void> _pauseHosting() async {
    await _nearbySub?.cancel();
    _nearbySub = null;
    await discovery.stopAll();
  }

  // -------------------------------------------------------------------------
  // During the transfer
  // -------------------------------------------------------------------------

  void answerRequest(bool accept) {
    final r = request;
    if (r == null) return;
    _engine?.send({'cmd': 'requestReply', 'id': r.id, 'accept': accept});
    _set(() {
      request = null;
      if (accept) status = 'Starting...';
    });
  }

  void pause() => _engine?.send({'cmd': 'pause'});
  void resume() => _engine?.send({'cmd': 'resume'});
  void cancel() => _engine?.send({'cmd': 'cancel'});

  void _onEvent(Map<String, dynamic> e) {
    switch (e['ev']) {
      case 'listening':
        _listening?.complete(e['port'] as int);
        _listening = null;
      case 'request':
        _set(() => request = PendingRequest(
              e['id'] as int,
              DeviceInfo.fromJson((e['device'] as Map).cast<String, dynamic>()),
              e['files'] as int?,
              e['bytes'] as int?,
            ));
      case 'started':
        PlatformBridge.keepScreenOn(true);
        _dialResult?.complete();
        _dialResult = null;
        _set(() {
          peer = DeviceInfo.fromJson((e['peer'] as Map).cast<String, dynamic>());
          role = e['role'] as String;
          stage = Stage.transferring;
          progress = null;
          summary = null;
          request = null;
        });
        // Nobody else should find us while we are busy.
        discovery.stopAll();
      case 'progress':
        _set(() => progress = TransferProgress.fromJson(e));
      case 'finished':
        _onFinished(e);
      case 'error':
        _dialResult?.complete();
        _dialResult = null;
        _set(() {
          error = e['message'] as String;
          if (stage == Stage.connecting || stage == Stage.preparing) stage = Stage.idle;
        });
    }
  }

  Future<void> _onFinished(Map<String, dynamic> e) async {
    PlatformBridge.keepScreenOn(false);
    final s = TransferSummary.fromJson((e['summary'] as Map).cast<String, dynamic>());
    final p = DeviceInfo.fromJson((e['peer'] as Map).cast<String, dynamic>());
    final sent = e['role'] == 'sender';
    _set(() {
      summary = s;
      peer = p;
      stage = Stage.finished;
    });
    if (!sent) {
      final saved = (e['saved'] as List?)?.cast<String>() ?? const [];
      unawaited(PlatformBridge.scanMedia(saved));
    }
    await app.addHistory(HistoryEntry(
      time: DateTime.now(),
      sent: sent,
      peerName: p.name,
      peerPlatform: p.platform,
      files: s.filesVerified,
      failed: s.filesFailed,
      bytes: s.bytes,
      durationMs: s.duration.inMilliseconds,
      cancelled: s.cancelled,
      destination: sent ? null : s.destination,
    ));
    await _teardownNetwork();
  }

  Future<void> _teardownNetwork() async {
    _engine?.send({'cmd': 'stopListening'});
    await _nearbySub?.cancel();
    _nearbySub = null;
    await discovery.stopAll();
    if (hotspot != null) {
      await PlatformBridge.stopHotspot();
      hotspot = null;
    }
    if (_joinedWifi) {
      await PlatformBridge.leaveWifi();
      _joinedWifi = false;
    }
  }

  /// Ends everything and goes back to idle.
  Future<void> stopSession({bool keepItems = false}) async {
    if (stage == Stage.transferring) cancel();
    await _teardownNetwork();
    PlatformBridge.keepScreenOn(false);
    _set(() {
      stage = Stage.idle;
      myCode = null;
      status = null;
      error = null;
      peer = null;
      progress = null;
      request = null;
      nearby = const [];
      if (!keepItems) items = [];
    });
  }

  void clearError() => _set(() => error = null);

  void setItems(List<PickedItem> list) => _set(() => items = list);

  @override
  void dispose() {
    _sub?.cancel();
    _engine?.dispose();
    super.dispose();
  }
}
