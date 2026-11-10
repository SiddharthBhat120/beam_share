// What goes into the QR code.
//
// Everything the other device needs to connect with no internet and no
// router: the Wi-Fi hotspot to join (if any), where to connect, and the
// security keys.

import 'dart:convert';

class PairingInfo {
  const PairingInfo({
    required this.deviceName,
    required this.platform,
    required this.hosts,
    required this.port,
    required this.fingerprint,
    required this.token,
    required this.role,
    this.ssid,
    this.passphrase,
  });

  final String deviceName;
  final String platform;

  /// Hotspot / Wi-Fi Direct group to join first (null = same network).
  final String? ssid;
  final String? passphrase;

  /// IP addresses of the device showing the QR code (tried in parallel).
  final List<String> hosts;
  final int port;

  /// SHA-256 fingerprint of the TLS certificate (pinning).
  final String fingerprint;

  /// One-time secret; proves the scanner really saw this QR code.
  final String token;

  /// Role of the device that shows the QR: "sender" or "receiver".
  final String role;

  static const _prefix = 'BEAM1:';

  /// Compact text for the QR code (also works for copy/paste).
  String encode() {
    final m = <String, Object>{
      'n': deviceName,
      'p': platform,
      'h': hosts,
      'o': port,
      'f': fingerprint,
      't': token,
      'r': role == 'sender' ? 's' : 'r',
      's': ?ssid,
      'w': ?passphrase,
    };
    return _prefix + base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  }

  static PairingInfo decode(String text) {
    final t = text.trim();
    if (!t.startsWith(_prefix)) throw const FormatException('Not a Beam Share code');
    var b64 = t.substring(_prefix.length);
    while (b64.length % 4 != 0) {
      b64 += '=';
    }
    final m = jsonDecode(utf8.decode(base64Url.decode(b64))) as Map<String, dynamic>;
    return PairingInfo(
      deviceName: m['n'] as String,
      platform: m['p'] as String,
      hosts: (m['h'] as List).cast<String>(),
      port: m['o'] as int,
      fingerprint: m['f'] as String,
      token: m['t'] as String,
      role: m['r'] == 's' ? 'sender' : 'receiver',
      ssid: m['s'] as String?,
      passphrase: m['w'] as String?,
    );
  }
}
