// Device identity and encryption.
//
// We do NOT write our own crypto. The channel is standard TLS (TLS 1.3 when
// both sides support it) from dart:io, which uses BoringSSL, the same library
// Chrome and Android use. TLS does the key exchange (ECDHE) and encryption
// (AES-GCM / ChaCha20).
//
// What TLS normally gets from certificate authorities, we get from pairing:
// each device makes a self-signed certificate once, and the SHA-256
// fingerprint of that certificate goes into the QR code (or the mDNS record).
// The other device only accepts a TLS connection when the certificate matches
// that fingerprint ("certificate pinning"), so nobody in between can listen in.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart' as crypto;

class BeamIdentity {
  BeamIdentity({required this.certPem, required this.keyPem})
      : fingerprint = fingerprintOfDer(_pemToDer(certPem));

  final String certPem;
  final String keyPem;

  /// Hex SHA-256 of the certificate (DER). Shared during pairing.
  final String fingerprint;

  /// Creates a new P-256 key and a 10-year self-signed certificate.
  /// Takes well under a second; the app stores the result and reuses it.
  factory BeamIdentity.generate({String commonName = 'Beam Share device'}) {
    final pair = CryptoUtils.generateEcKeyPair();
    final priv = pair.privateKey as ECPrivateKey;
    final pub = pair.publicKey as ECPublicKey;
    final csr = X509Utils.generateEccCsrPem({'CN': commonName}, priv, pub);
    final cert = X509Utils.generateSelfSignedCertificate(priv, csr, 3650);
    return BeamIdentity(certPem: cert, keyPem: CryptoUtils.encodeEcPrivateKeyToPem(priv));
  }

  SecurityContext serverContext() => SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(certPem))
    ..usePrivateKeyBytes(utf8.encode(keyPem));

  Map<String, String> toJson() => {'cert': certPem, 'key': keyPem};

  factory BeamIdentity.fromJson(Map<String, dynamic> j) =>
      BeamIdentity(certPem: j['cert'] as String, keyPem: j['key'] as String);
}

Uint8List _pemToDer(String pem) {
  final body = pem
      .split('\n')
      .where((l) => !l.trim().startsWith('-----'))
      .join()
      .replaceAll(RegExp(r'\s'), '');
  return base64.decode(body);
}

/// Hex SHA-256 of a DER certificate.
String fingerprintOfDer(Uint8List der) => crypto.sha256.convert(der).toString();

/// Random hex token (used for session ids and pairing secrets).
String randomToken([int bytes = 16]) {
  final r = Random.secure();
  return List.generate(bytes, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}
