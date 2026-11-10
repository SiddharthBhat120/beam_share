import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:transfer_core/transfer_core.dart';

/// Official BLAKE3 test-vector convention: byte i = i % 251.
Uint8List pattern(int n) {
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = i % 251;
  }
  return b;
}

void main() {
  // Reference hashes produced by the official `blake3` Python package
  // (see test/fixtures_blake3.json).
  final fixtures = (jsonDecode(File('test/fixtures_blake3.json').readAsStringSync())
          as Map<String, dynamic>)
      .map((k, v) => MapEntry(int.parse(k), v as String));
  final maxLen = fixtures.keys.reduce((a, b) => a > b ? a : b);
  final data = pattern(maxLen);

  test('known answers for empty and "abc"', () {
    expect(Blake3.hashHex([]),
        'af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262');
    expect(Blake3.hashHex(utf8.encode('abc')),
        '6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85');
  });

  test('one-shot hash matches reference for all lengths', () {
    fixtures.forEach((len, expected) {
      expect(Blake3.toHex(Blake3.hash(Uint8List.sublistView(data, 0, len))), expected,
          reason: 'length $len');
    });
  });

  test('incremental hashing with odd-sized updates gives same result', () {
    for (final len in fixtures.keys.where((l) => l < 200000)) {
      final h = Blake3Hasher();
      var pos = 0;
      var step = 1;
      while (pos < len) {
        final end = (pos + step) > len ? len : pos + step;
        h.add(data, pos, end);
        pos = end;
        step = step * 3 + 7; // 1, 10, 37, 118, ... odd boundaries
      }
      expect(Blake3.toHex(h.finalize()), fixtures[len], reason: 'length $len');
    }
  });

  test('piece CVs merge into the full-file root hash', () {
    for (final pieceSize in [4096, 1024 * 1024 * 4, 1024 * 1024 * 8]) {
      for (final len in fixtures.keys.where((l) => l > pieceSize)) {
        final cvs = <Uint8List>[];
        for (var off = 0, i = 0; off < len; off += pieceSize, i++) {
          final end = off + pieceSize > len ? len : off + pieceSize;
          cvs.add(Blake3.pieceCv(data, i, pieceSize, off, end));
        }
        expect(Blake3.toHex(Blake3.rootFromPieceCvs(cvs)), fixtures[len],
            reason: 'len $len pieceSize $pieceSize');
      }
    }
  });

  test('rejects piece sizes that are not power-of-two KiB', () {
    expect(() => Blake3.pieceCv(Uint8List(10), 0, 3000), throwsArgumentError);
    expect(() => Blake3.pieceCv(Uint8List(10), 0, 3072), throwsArgumentError);
  });
}
