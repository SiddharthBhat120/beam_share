// Binary layout of one data frame ("unit").
//
// A unit carries one or more *segments*. A segment is either a whole small
// file or one piece of a big file. Packing many small files into one unit is
// what makes "1,000 photos" fast: no per-file round trip.
//
//   u32 unitId
//   u16 segmentCount
//   segmentCount x {
//     u32 fileId, u32 pieceIndex, u64 offset, u32 length, 32 bytes hash
//   }
//   segment bytes, back to back
//
// hash = BLAKE3 of the whole file (small files) or the BLAKE3 piece chaining
// value (pieces of big files).

import 'dart:typed_data';

const int segmentHeaderLength = 4 + 4 + 8 + 4 + 32;
const int maxSegmentsPerUnit = 4096;

class Segment {
  Segment({
    required this.fileId,
    required this.piece,
    required this.offset,
    required this.length,
    required this.hash,
  });

  final int fileId;
  final int piece;
  final int offset;
  final int length;
  final Uint8List hash;
}

Uint8List encodeUnitHeader(int unitId, List<Segment> segments) {
  final out = Uint8List(6 + segments.length * segmentHeaderLength);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, unitId);
  bd.setUint16(4, segments.length);
  var p = 6;
  for (final s in segments) {
    bd.setUint32(p, s.fileId);
    bd.setUint32(p + 4, s.piece);
    bd.setUint32(p + 8, s.offset >> 32);
    bd.setUint32(p + 12, s.offset & 0xFFFFFFFF);
    bd.setUint32(p + 16, s.length);
    out.setRange(p + 20, p + 52, s.hash);
    p += segmentHeaderLength;
  }
  return out;
}

class DecodedUnit {
  DecodedUnit(this.unitId, this.segments, this.dataStart);
  final int unitId;
  final List<Segment> segments;

  /// Offset in the payload where the first segment's bytes start.
  final int dataStart;
}

DecodedUnit decodeUnit(Uint8List payload) {
  if (payload.length < 6) throw const FormatException('unit too short');
  final bd = ByteData.sublistView(payload);
  final id = bd.getUint32(0);
  final count = bd.getUint16(4);
  if (count == 0 || count > maxSegmentsPerUnit) throw const FormatException('bad segment count');
  final dataStart = 6 + count * segmentHeaderLength;
  if (payload.length < dataStart) throw const FormatException('unit header truncated');
  final segs = <Segment>[];
  var p = 6;
  var total = 0;
  for (var i = 0; i < count; i++) {
    final len = bd.getUint32(p + 16);
    segs.add(Segment(
      fileId: bd.getUint32(p),
      piece: bd.getUint32(p + 4),
      offset: (bd.getUint32(p + 8) << 32) | bd.getUint32(p + 12),
      length: len,
      hash: Uint8List.fromList(Uint8List.sublistView(payload, p + 20, p + 52)),
    ));
    total += len;
    p += segmentHeaderLength;
  }
  if (dataStart + total != payload.length) throw const FormatException('unit length mismatch');
  return DecodedUnit(id, segs, dataStart);
}

/// Bit set <-> bytes (for the resume "which pieces do you have" message).
Uint8List encodeBits(List<bool> bits) {
  final out = Uint8List((bits.length + 7) >> 3);
  for (var i = 0; i < bits.length; i++) {
    if (bits[i]) out[i >> 3] |= 1 << (i & 7);
  }
  return out;
}

List<bool> decodeBits(Uint8List bytes, int count) =>
    List<bool>.generate(count, (i) => (i >> 3) < bytes.length && (bytes[i >> 3] & (1 << (i & 7))) != 0);

bool bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
