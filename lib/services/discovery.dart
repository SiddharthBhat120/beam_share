// "Nearby devices" on the same Wi-Fi or hotspot, via mDNS / Bonjour.
//
// A waiting receiver advertises the service "_beamshare._tcp" with its name,
// port and certificate fingerprint in the TXT record. Senders browse for it.
// This works on any shared network, including a phone's hotspot after the
// other device joined it from the QR code.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:nsd/nsd.dart' as nsd;
import 'package:transfer_core/transfer_core.dart';

import 'platform_bridge.dart';

const beamServiceType = '_beamshare._tcp';

class NearbyDevice {
  NearbyDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.fingerprint,
    required this.hosts,
    required this.port,
    this.p2pName,
  });

  final String id;
  final String name;
  final String platform;
  final String fingerprint;
  final List<String> hosts;
  final int port;

  /// Set when found over iPhone peer-to-peer Wi-Fi (connect via relay).
  final String? p2pName;
}

class DiscoveryService {
  nsd.Registration? _registration;
  nsd.Discovery? _discovery;
  StreamSubscription<List<Map<String, dynamic>>>? _p2pSub;
  List<NearbyDevice> _lan = const [];
  List<NearbyDevice> _p2p = const [];
  final _devices = StreamController<List<NearbyDevice>>.broadcast();

  void _publishMerged() {
    if (_devices.isClosed) return;
    final ids = _lan.map((d) => d.id).toSet();
    _devices.add([..._lan, ..._p2p.where((d) => !ids.contains(d.id))]);
  }

  Stream<List<NearbyDevice>> get devices => _devices.stream;

  Future<void> advertise({required DeviceInfo me, required int port, required String fingerprint}) async {
    await stopAdvertising();
    try {
      await PlatformBridge.multicastLock(true);
      _registration = await nsd.register(nsd.Service(
        name: me.name,
        type: beamServiceType,
        port: port,
        txt: {
          'id': _b(me.id),
          'n': _b(me.name),
          'pf': _b(me.platform),
          'fp': _b(fingerprint),
        },
      ));
    } catch (e) {
      debugPrint('mDNS advertise failed: $e');
    }
    // iPhones can also be found with no shared network at all.
    await PlatformBridge.p2pAdvertise(
      name: me.name,
      port: port,
      txt: {'id': me.id, 'n': me.name, 'pf': me.platform, 'fp': fingerprint},
    );
  }

  Future<void> stopAdvertising() async {
    final r = _registration;
    _registration = null;
    if (r != null) {
      try {
        await nsd.unregister(r);
      } catch (_) {}
    }
  }

  Future<void> browse({required String myId}) async {
    await stopBrowsing();
    try {
      await PlatformBridge.multicastLock(true);
      final d = await nsd.startDiscovery(beamServiceType, ipLookupType: nsd.IpLookupType.v4);
      _discovery = d;
      void publish() {
        final list = <NearbyDevice>[];
        for (final s in d.services) {
          final txt = s.txt ?? const {};
          final id = _s(txt['id']);
          final fp = _s(txt['fp']);
          if (id == null || fp == null || id == myId || s.port == null) continue;
          final hosts = <String>[
            ...?s.addresses?.map((a) => a.address),
            if (s.host != null && (s.addresses?.isEmpty ?? true)) s.host!,
          ];
          if (hosts.isEmpty) continue;
          list.add(NearbyDevice(
            id: id,
            name: _s(txt['n']) ?? s.name ?? 'Device',
            platform: _s(txt['pf']) ?? 'unknown',
            fingerprint: fp,
            hosts: hosts,
            port: s.port!,
          ));
        }
        _lan = list;
        _publishMerged();
      }

      d.addListener(publish);
      publish();
    } catch (e) {
      debugPrint('mDNS browse failed: $e');
      _publishMerged();
    }
    if (PlatformBridge.isIOS) {
      _p2pSub = PlatformBridge.p2pPeers.listen((peers) {
        _p2p = [
          for (final p in peers)
            if ((p['txt'] as Map?)?['id'] != null && (p['txt'] as Map)['id'] != myId)
              NearbyDevice(
                id: (p['txt'] as Map)['id'] as String,
                name: (p['txt'] as Map)['n'] as String? ?? p['name'] as String,
                platform: (p['txt'] as Map)['pf'] as String? ?? 'ios',
                fingerprint: (p['txt'] as Map)['fp'] as String? ?? '',
                hosts: const ['127.0.0.1'],
                port: 0,
                p2pName: p['name'] as String,
              ),
        ];
        _publishMerged();
      });
      await PlatformBridge.p2pBrowse();
    }
  }

  Future<void> stopBrowsing() async {
    final d = _discovery;
    _discovery = null;
    if (d != null) {
      try {
        await nsd.stopDiscovery(d);
      } catch (_) {}
    }
  }

  Future<void> stopAll() async {
    await stopAdvertising();
    await stopBrowsing();
    await _p2pSub?.cancel();
    _p2pSub = null;
    _p2p = const [];
    await PlatformBridge.p2pStop();
    await PlatformBridge.multicastLock(false);
  }

  static Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));
  static String? _s(Uint8List? b) => b == null ? null : utf8.decode(b, allowMalformed: true);
}
