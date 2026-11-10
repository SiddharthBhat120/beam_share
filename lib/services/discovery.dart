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
  });

  final String id;
  final String name;
  final String platform;
  final String fingerprint;
  final List<String> hosts;
  final int port;
}

class DiscoveryService {
  nsd.Registration? _registration;
  nsd.Discovery? _discovery;
  final _devices = StreamController<List<NearbyDevice>>.broadcast();

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
        if (!_devices.isClosed) _devices.add(list);
      }

      d.addListener(publish);
      publish();
    } catch (e) {
      debugPrint('mDNS browse failed: $e');
      if (!_devices.isClosed) _devices.add(const []);
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
    await PlatformBridge.multicastLock(false);
  }

  static Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));
  static String? _s(Uint8List? b) => b == null ? null : utf8.decode(b, allowMalformed: true);
}
