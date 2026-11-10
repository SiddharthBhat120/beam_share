// Runtime permissions, asked only when needed.
//
// Android (requested through our own Kotlin code, see BeamPlatform.kt):
//  * Wi-Fi Direct / hotspot / joining Wi-Fi: NEARBY_WIFI_DEVICES (Android 13+)
//    or location (Android 12 and older, the system requires it for Wi-Fi APIs)
//  * saving to Download/BeamShare on Android 10 and older: storage
//  * keeping GPS data in sent photos: ACCESS_MEDIA_LOCATION
//  * camera for the QR scanner
// iOS asks by itself (camera, photos, local network) using the texts in
// Info.plist. Windows needs no runtime permissions.

import 'package:flutter/services.dart';

import 'platform_bridge.dart';

class Permissions {
  static const _ch = MethodChannel('beam/platform');
  static int? _sdk;

  static Future<int> androidSdk() async {
    if (_sdk != null) return _sdk!;
    try {
      _sdk = await _ch.invokeMethod<int>('sdkInt') ?? 0;
    } catch (_) {
      _sdk = 0;
    }
    return _sdk!;
  }

  /// Asks for Android permissions; returns which ones are granted.
  static Future<Map<String, bool>> _request(List<String> permissions) async {
    try {
      final m = await _ch.invokeMapMethod<String, bool>('requestPermissions', {'permissions': permissions});
      return m ?? const {};
    } catch (_) {
      return const {};
    }
  }

  /// Permissions for creating/joining offline networks and saving files.
  /// Returns false if the user refused the Wi-Fi permission.
  static Future<bool> ensureNetwork() async {
    if (!PlatformBridge.isAndroid) return true;
    final sdk = await androidSdk();
    final wifi = sdk >= 33 ? 'android.permission.NEARBY_WIFI_DEVICES' : 'android.permission.ACCESS_FINE_LOCATION';
    final granted = await _request([wifi, if (sdk <= 29) 'android.permission.WRITE_EXTERNAL_STORAGE']);
    return granted[wifi] ?? false;
  }

  /// Lets Android give us photos with their GPS location intact.
  static Future<void> ensureMediaLocation() async {
    if (!PlatformBridge.isAndroid || await androidSdk() < 29) return;
    await _request(['android.permission.ACCESS_MEDIA_LOCATION']);
  }

  static Future<bool> ensureCamera() async {
    if (!PlatformBridge.isMobile) return false;
    if (PlatformBridge.isIOS) return true; // the scanner triggers the iOS prompt
    final g = await _request(['android.permission.CAMERA']);
    return g['android.permission.CAMERA'] ?? false;
  }

  static Future<void> openSettings() async {
    try {
      await _ch.invokeMethod('openAppSettings');
    } catch (_) {}
  }
}
