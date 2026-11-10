// Dart side of the native code.
//
// Each platform implements the "beam/platform" method channel:
//   Android: android/app/src/main/kotlin/.../BeamPlatform.kt
//   iOS:     ios/Runner/BeamPlatform.swift
//   Windows: windows/runner/beam_platform.cpp
// Things that are easy in Dart on a platform (e.g. "netsh" on Windows) are
// done here instead.

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:transfer_core/transfer_core.dart';

import '../models/picked_item.dart';

/// An offline network this device created for the other one to join.
class HotspotInfo {
  HotspotInfo({required this.ssid, required this.passphrase, required this.mode});
  final String ssid;
  final String passphrase;

  /// "wifi-direct" (Android group / Windows legacy Wi-Fi Direct) or
  /// "local-only" (Android LocalOnlyHotspot).
  final String mode;
}

class PlatformBridge {
  PlatformBridge._();

  static const _channel = MethodChannel('beam/platform');

  static bool get isAndroid => !kIsWeb && Platform.isAndroid;
  static bool get isIOS => !kIsWeb && Platform.isIOS;
  static bool get isWindows => !kIsWeb && Platform.isWindows;
  static bool get isMobile => isAndroid || isIOS;

  static String get platformName => isAndroid
      ? 'android'
      : isIOS
          ? 'ios'
          : isWindows
              ? 'windows'
              : Platform.operatingSystem;

  /// Can this device create its own Wi-Fi network for the other to join?
  /// (iOS apps are not allowed to.)
  static bool get canHostHotspot => isAndroid || isWindows;

  static Future<HotspotInfo?> startHotspot(String deviceName) async {
    if (!canHostHotspot) return null;
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('startHotspot', {'name': deviceName});
      if (m == null) return null;
      return HotspotInfo(
        ssid: m['ssid'] as String,
        passphrase: m['passphrase'] as String,
        mode: m['mode'] as String? ?? 'wifi-direct',
      );
    } on PlatformException catch (e) {
      debugPrint('startHotspot failed: ${e.code} ${e.message}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<void> stopHotspot() async {
    if (!canHostHotspot) return;
    try {
      await _channel.invokeMethod('stopHotspot');
    } catch (_) {}
  }

  /// Joins the other device's hotspot. Returns true once connected.
  static Future<bool> joinWifi(String ssid, String passphrase) async {
    if (isWindows) return _windowsJoin(ssid, passphrase);
    try {
      return await _channel.invokeMethod<bool>('joinWifi', {'ssid': ssid, 'passphrase': passphrase}) ?? false;
    } on PlatformException catch (e) {
      debugPrint('joinWifi failed: ${e.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> leaveWifi() async {
    if (isWindows) return;
    try {
      await _channel.invokeMethod('leaveWifi');
    } catch (_) {}
  }

  /// Windows: temporary WPA2 profile + "netsh wlan connect".
  static Future<bool> _windowsJoin(String ssid, String passphrase) async {
    String esc(String s) => s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
    final xml = '''<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>${esc(ssid)}</name>
  <SSIDConfig><SSID><name>${esc(ssid)}</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>manual</connectionMode>
  <MSM><security>
    <authEncryption><authentication>WPA2PSK</authentication><encryption>AES</encryption><useOneX>false</useOneX></authEncryption>
    <sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>${esc(passphrase)}</keyMaterial></sharedKey>
  </security></MSM>
</WLANProfile>''';
    final file = File('${Directory.systemTemp.path}\\beam_wifi_profile.xml');
    await file.writeAsString(xml);
    try {
      final add = await Process.run('netsh', ['wlan', 'add', 'profile', 'filename=${file.path}', 'user=current']);
      if (add.exitCode != 0) return false;
      final con = await Process.run('netsh', ['wlan', 'connect', 'name=$ssid']);
      return con.exitCode == 0;
    } finally {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  static Future<String> deviceName() async {
    if (isWindows) return Platform.localHostname;
    try {
      return await _channel.invokeMethod<String>('deviceName') ?? Platform.localHostname;
    } catch (_) {
      return isIOS ? 'iPhone' : 'Android phone';
    }
  }

  /// Folder where received files go.
  static Future<String> defaultReceiveDir() async {
    if (isWindows) {
      final home = Platform.environment['USERPROFILE'] ?? Directory.current.path;
      return '$home\\Downloads\\BeamShare';
    }
    if (isAndroid) {
      try {
        final d = await _channel.invokeMethod<String>('downloadsDir');
        if (d != null) return '$d/BeamShare';
      } catch (_) {}
      final ext = await getExternalStorageDirectory();
      return '${ext!.path}/BeamShare';
    }
    final docs = await getApplicationDocumentsDirectory();
    return '${docs.path}/Received';
  }

  static Future<void> openFolder(String path) async {
    if (isWindows) {
      await Process.run('explorer', [path]);
      return;
    }
    try {
      await _channel.invokeMethod('openFolder', {'path': path});
    } catch (_) {}
  }

  /// Keeps the screen on during a transfer (also stops the OS from sleeping).
  static Future<void> keepScreenOn(bool on) async {
    try {
      await _channel.invokeMethod('keepScreenOn', {'on': on});
    } catch (_) {}
  }

  /// Android: make new photos/videos show up in the gallery.
  static Future<void> scanMedia(List<String> paths) async {
    if (!isAndroid || paths.isEmpty) return;
    try {
      await _channel.invokeMethod('scanMedia', {'paths': paths});
    } catch (_) {}
  }

  /// Android: needed so mDNS packets reach the app.
  static Future<void> multicastLock(bool on) async {
    if (!isAndroid) return;
    try {
      await _channel.invokeMethod('multicastLock', {'on': on});
    } catch (_) {}
  }

  // ---------------------------------------------------------------------
  // Picking
  // ---------------------------------------------------------------------

  /// Any files. Android uses the system document picker (original bytes,
  /// no cache copy); other platforms use file_picker.
  static Future<List<PickedItem>> pickFiles() async {
    if (isAndroid) return _androidPick('pickDocuments', {'mime': '*/*'});
    final files = await FilePicker.pickFiles();
    final out = <PickedItem>[];
    for (final f in files) {
      final path = f.path;
      if (path == null) continue;
      final st = await File(path).stat();
      out.add(PickedItem(
        kind: 'file',
        relativePath: f.name,
        size: st.size,
        modifiedMs: st.modified.millisecondsSinceEpoch,
        path: path,
      ));
    }
    return out;
  }

  /// Photos and videos in original quality.
  static Future<List<PickedItem>> pickMedia() async {
    if (isAndroid) return _androidPick('pickDocuments', {'mime': 'image/*,video/*'});
    if (isIOS) return _iosPickMedia();
    final files = await FilePicker.pickFiles(type: FileType.media);
    return [
      for (final f in files)
        if (f.path != null)
          PickedItem(
            kind: 'file',
            relativePath: f.name,
            size: File(f.path!).lengthSync(),
            modifiedMs: File(f.path!).lastModifiedSync().millisecondsSinceEpoch,
            path: f.path,
          ),
    ];
  }

  /// A whole folder (recursive, keeps the structure and empty folders).
  static Future<List<PickedItem>> pickFolder() async {
    if (isAndroid) return _androidPick('pickFolder', const {});
    final dir = await FilePicker.getDirectoryPath();
    if (dir == null) return [];
    final sources = await collectLocalSources([dir]);
    return [
      for (final s in sources)
        PickedItem(
          kind: s.isDirectory ? 'dir' : 'file',
          relativePath: s.relativePath,
          size: s.size,
          modifiedMs: s.modified.millisecondsSinceEpoch,
          path: s is LocalSourceFile ? s.file.path : null,
        ),
    ];
  }

  static Future<List<PickedItem>> _androidPick(String method, Map<String, Object> args) async {
    final list = await _channel.invokeListMethod<Map<dynamic, dynamic>>(method, args) ?? [];
    return [for (final m in list) PickedItem.fromMap(m)];
  }

  /// iOS: the Swift side exports the original resources (HEIC, ProRAW,
  /// video, Live Photo video) with PHAssetResourceManager into a temp folder.
  static Future<List<PickedItem>> _iosPickMedia() async {
    final list = await _channel.invokeListMethod<Map<dynamic, dynamic>>('pickMedia') ?? [];
    return [for (final m in list) PickedItem.fromMap(m)];
  }

  // ---------------------------------------------------------------------
  // iPhone <-> iPhone peer-to-peer Wi-Fi (AWDL), no network needed
  // ---------------------------------------------------------------------

  static final _p2pPeers = StreamController<List<Map<String, dynamic>>>.broadcast();
  static bool _handlerSet = false;

  /// Peers found over AWDL: {'name': ..., 'txt': {...}}.
  static Stream<List<Map<String, dynamic>>> get p2pPeers {
    if (!_handlerSet) {
      _handlerSet = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'p2pPeers') {
          final list = (call.arguments as List)
              .map((e) => (e as Map).map((k, v) => MapEntry(k.toString(), v)))
              .toList();
          _p2pPeers.add(list);
        }
        return null;
      });
    }
    return _p2pPeers.stream;
  }

  static Future<void> p2pAdvertise({required String name, required int port, required Map<String, String> txt}) async {
    if (!isIOS) return;
    try {
      await _channel.invokeMethod('p2pAdvertise', {'name': name, 'port': port, 'txt': txt});
    } catch (_) {}
  }

  static Future<void> p2pBrowse() async {
    if (!isIOS) return;
    p2pPeers; // make sure the callback handler is installed
    try {
      await _channel.invokeMethod('p2pBrowse');
    } catch (_) {}
  }

  static Future<void> p2pStop() async {
    if (!isIOS) return;
    try {
      await _channel.invokeMethod('p2pStop');
    } catch (_) {}
  }

  /// Returns a local port that relays to the peer over AWDL.
  static Future<int?> p2pConnect(String name) async {
    try {
      return await _channel.invokeMethod<int>('p2pConnect', {'name': name});
    } catch (_) {
      return null;
    }
  }

  /// IPv4 addresses of this device (all of them; the other side tries each).
  static Future<List<String>> localIPv4s() async {
    final out = <String>[];
    try {
      final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      for (final i in ifs) {
        for (final a in i.addresses) {
          if (!a.isLinkLocal) out.add(a.address);
        }
      }
    } catch (_) {}
    // Typical hotspot gateway addresses first: they are the offline path.
    int rank(String ip) => ip.startsWith('192.168.49.') || ip.startsWith('192.168.137.') ? 0 : 1;
    out.sort((a, b) => rank(a).compareTo(rank(b)));
    return out;
  }
}
