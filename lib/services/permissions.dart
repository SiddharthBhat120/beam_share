// Runtime permissions, asked only when needed.
//
// Android:
//  * Wi-Fi Direct / hotspot / joining Wi-Fi: NEARBY_WIFI_DEVICES (Android 13+)
//    or location (Android 12 and older, the system requires it for Wi-Fi APIs)
//  * saving to Download/BeamShare on Android 9 and older: storage
//  * camera for the QR scanner
// iOS asks by itself (camera, photos, local network) using the texts in
// Info.plist. Windows needs no runtime permissions.

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

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

  /// Permissions for creating/joining offline networks and saving files.
  /// Returns false if the user refused something essential.
  static Future<bool> ensureNetwork() async {
    if (!PlatformBridge.isAndroid) return true;
    final sdk = await androidSdk();
    final wifi = sdk >= 33 ? Permission.nearbyWifiDevices : Permission.locationWhenInUse;
    final perms = <Permission>[wifi, if (sdk <= 28) Permission.storage];
    final result = await perms.request();
    return result[wifi]?.isGranted ?? false;
  }

  static Future<bool> ensureCamera() async {
    if (!PlatformBridge.isMobile) return false;
    if (PlatformBridge.isIOS) return true; // the scanner triggers the iOS prompt
    return (await Permission.camera.request()).isGranted;
  }

  static Future<void> openSettings() => openAppSettings();
}
