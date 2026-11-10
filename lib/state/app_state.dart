// App-wide settings, device identity and transfer history.
//
// Stored as small JSON files in the app's private support folder:
//   settings.json  device name, theme, receive folder
//   identity.json  TLS certificate + key (created once, never leaves the device)
//   history.json   past transfers

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:transfer_core/transfer_core.dart';

import '../services/platform_bridge.dart';

class HistoryEntry {
  HistoryEntry({
    required this.time,
    required this.sent,
    required this.peerName,
    required this.peerPlatform,
    required this.files,
    required this.failed,
    required this.bytes,
    required this.durationMs,
    required this.cancelled,
    this.destination,
  });

  final DateTime time;
  final bool sent;
  final String peerName;
  final String peerPlatform;
  final int files;
  final int failed;
  final int bytes;
  final int durationMs;
  final bool cancelled;
  final String? destination;

  bool get success => !cancelled && failed == 0;

  Map<String, Object?> toJson() => {
        'time': time.toIso8601String(),
        'sent': sent,
        'peer': peerName,
        'platform': peerPlatform,
        'files': files,
        'failed': failed,
        'bytes': bytes,
        'ms': durationMs,
        'cancelled': cancelled,
        'dest': destination,
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
        time: DateTime.parse(j['time'] as String),
        sent: j['sent'] as bool,
        peerName: j['peer'] as String,
        peerPlatform: j['platform'] as String? ?? 'unknown',
        files: j['files'] as int,
        failed: j['failed'] as int? ?? 0,
        bytes: j['bytes'] as int,
        durationMs: j['ms'] as int,
        cancelled: j['cancelled'] as bool? ?? false,
        destination: j['dest'] as String?,
      );
}

class AppState extends ChangeNotifier {
  AppState._(this._dir);

  final Directory _dir;
  late String deviceId;
  late String deviceName;
  ThemeMode themeMode = ThemeMode.system;
  late String receiveDir;
  late BeamIdentity identity;

  /// Create a hotspot / Wi-Fi Direct group when sharing (works with no router).
  bool offlineMode = true;
  final List<HistoryEntry> history = [];

  DeviceInfo get me => DeviceInfo(id: deviceId, name: deviceName, platform: PlatformBridge.platformName);

  static Future<AppState> load() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final s = AppState._(dir);
    final settings = await s._readJson('settings.json');
    s.deviceId = settings?['id'] as String? ?? randomToken(8);
    s.deviceName = settings?['name'] as String? ?? await PlatformBridge.deviceName();
    s.themeMode = ThemeMode.values.asNameMap()[settings?['theme']] ?? ThemeMode.system;
    s.receiveDir = settings?['receiveDir'] as String? ?? await PlatformBridge.defaultReceiveDir();
    s.offlineMode = settings?['offline'] as bool? ?? true;

    final id = await s._readJson('identity.json');
    if (id != null) {
      s.identity = BeamIdentity.fromJson(id);
    } else {
      // Key generation is CPU work: do it off the UI thread.
      final json = await Isolate.run(() => BeamIdentity.generate().toJson());
      s.identity = BeamIdentity.fromJson(json);
      await s._writeJson('identity.json', json);
    }

    final h = await s._readJson('history.json');
    for (final e in (h?['items'] as List? ?? [])) {
      try {
        s.history.add(HistoryEntry.fromJson((e as Map).cast<String, dynamic>()));
      } catch (_) {}
    }
    await s._saveSettings();
    return s;
  }

  Future<Map<String, dynamic>?> _readJson(String name) async {
    try {
      final f = File('${_dir.path}${Platform.pathSeparator}$name');
      if (!await f.exists()) return null;
      return (jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeJson(String name, Object json) async {
    final f = File('${_dir.path}${Platform.pathSeparator}$name');
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(json));
    await tmp.rename(f.path); // atomic replace
  }

  Future<void> _saveSettings() => _writeJson('settings.json', {
        'id': deviceId,
        'name': deviceName,
        'theme': themeMode.name,
        'receiveDir': receiveDir,
        'offline': offlineMode,
      });

  Future<void> setDeviceName(String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    deviceName = n.length > 40 ? n.substring(0, 40) : n;
    notifyListeners();
    await _saveSettings();
  }

  Future<void> setThemeMode(ThemeMode m) async {
    themeMode = m;
    notifyListeners();
    await _saveSettings();
  }

  Future<void> setReceiveDir(String path) async {
    receiveDir = path;
    notifyListeners();
    await _saveSettings();
  }

  Future<void> setOfflineMode(bool on) async {
    offlineMode = on;
    notifyListeners();
    await _saveSettings();
  }

  Future<void> addHistory(HistoryEntry e) async {
    history.insert(0, e);
    if (history.length > 500) history.removeRange(500, history.length);
    notifyListeners();
    await _writeJson('history.json', {'items': [for (final h in history) h.toJson()]});
  }

  Future<void> clearHistory() async {
    history.clear();
    notifyListeners();
    await _writeJson('history.json', {'items': []});
  }
}
