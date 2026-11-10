// A pure-Dart implementation of the BLAKE3 hash function.
//
// Why our own implementation? The transfer engine must stay pure Dart (no
// native build steps) so it runs the same on Android, iOS and Windows, and so
// it can later be swapped for a Rust core. BLAKE3 is a hash (not encryption),
// is fully specified, and this file is checked against the official test
// vectors in test/blake3_test.dart.
//
// Besides the normal "hash some bytes" API, this file exposes BLAKE3's tree
// structure, which the engine relies on:
//
//  * A big file is cut into pieces of 4 MiB or 8 MiB (a power-of-two number of
//    1 KiB BLAKE3 chunks).
//  * Each piece is hashed on its own into a *subtree chaining value* (CV).
//    The receiver checks each piece by recomputing its CV.
//  * The CVs of all pieces are merged into the root, which is exactly the
//    normal BLAKE3 hash of the whole file (same value `b3sum` prints).
//
// So each side hashes every byte only once, pieces can be verified out of
// order (they arrive over several TCP streams), and we still get a genuine
// full-file BLAKE3 hash at the end.

import 'dart:typed_data';

part 'blake3_compress.g.dart';

const int _chunkLen = 1024;
const int _blockLen = 64;

const int _flagChunkStart = 1;
const int _flagChunkEnd = 2;
const int _flagParent = 4;
const int _flagRoot = 8;

/// The BLAKE3 initialization vector (same as SHA-256's).
final Uint32List _iv = Uint32List.fromList(const [
  0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, //
  0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
]);

/// Length of a BLAKE3 hash / chaining value in bytes.
const int blake3OutLen = 32;

/// BLAKE3 chunk length (1 KiB). Piece sizes must be a power-of-two multiple.
const int blake3ChunkLen = _chunkLen;

/// Static helpers.
class Blake3 {
  Blake3._();

  /// Hashes [data] and returns the 32-byte BLAKE3 digest.
  static Uint8List hash(List<int> data) {
    final h = Blake3Hasher();
    h.add(data is Uint8List ? data : Uint8List.fromList(data));
    return h.finalize();
  }

  /// Hex string of the BLAKE3 hash of [data].
  static String hashHex(List<int> data) => toHex(hash(data));

  /// Computes the chaining value of one *piece* of a larger input.
  ///
  /// [pieceIndex] is the position of the piece and [pieceSize] the size of all
  /// full pieces (a power of two, >= 1 KiB). The last piece may be shorter.
  /// Only valid when the whole input has more than one piece.
  static Uint8List pieceCv(Uint8List data, int pieceIndex, int pieceSize,
      [int start = 0, int? end]) {
    _checkPieceSize(pieceSize);
    final h = Blake3Hasher(chunkCounterOffset: pieceIndex * (pieceSize ~/ _chunkLen));
    h.add(data, start, end);
    return h.finalizeSubtree();
  }

  /// Merges the chaining values of all pieces (in order) into the root hash.
  ///
  /// Gives the same result as hashing the whole input in one go, as long as
  /// every full piece has the same power-of-two size. Requires >= 2 pieces.
  static Uint8List rootFromPieceCvs(List<Uint8List> cvs) {
    if (cvs.length < 2) {
      throw ArgumentError('Need at least two pieces; hash small inputs directly.');
    }
    final words = cvs.map(_bytesToWords).toList();
    final out = _merge(words, 0, words.length, true);
    return _wordsToBytes(out);
  }

  static Uint32List _merge(List<Uint32List> cvs, int start, int count, bool root) {
    if (count == 1) return cvs[start];
    // The left subtree holds the largest power of two that is < count.
    var left = 1;
    while (left * 2 < count) {
      left *= 2;
    }
    final l = _merge(cvs, start, left, false);
    final r = _merge(cvs, start + left, count - left, false);
    return _parentCv(l, r, root ? _flagRoot : 0);
  }

  static void _checkPieceSize(int pieceSize) {
    if (pieceSize < _chunkLen ||
        pieceSize % _chunkLen != 0 ||
        ((pieceSize ~/ _chunkLen) & ((pieceSize ~/ _chunkLen) - 1)) != 0) {
      throw ArgumentError('pieceSize must be a power-of-two multiple of 1 KiB');
    }
  }

  /// Lower-case hex encoding.
  static String toHex(List<int> bytes) {
    const digits = '0123456789abcdef';
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(digits[(b >> 4) & 0xF]);
      sb.write(digits[b & 0xF]);
    }
    return sb.toString();
  }

  /// Decodes a hex string.
  static Uint8List fromHex(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}

/// Compresses two child CVs into their parent CV.
Uint32List _parentCv(Uint32List left, Uint32List right, int extraFlags) {
  final msg = Uint32List(16);
  msg.setRange(0, 8, left);
  msg.setRange(8, 16, right);
  final out = Uint32List(8);
  _compress(_iv, msg, 0, 0, _blockLen, _flagParent | extraFlags, out);
  return out;
}

Uint32List _bytesToWords(Uint8List b) {
  final w = Uint32List(8);
  final bd = ByteData.sublistView(b);
  for (var i = 0; i < 8; i++) {
    w[i] = bd.getUint32(i * 4, Endian.little);
  }
  return w;
}

Uint8List _wordsToBytes(Uint32List w) {
  final out = Uint8List(32);
  final bd = ByteData.sublistView(out);
  for (var i = 0; i < 8; i++) {
    bd.setUint32(i * 4, w[i], Endian.little);
  }
  return out;
}

/// Incremental BLAKE3 hasher (default "hash" mode, 32-byte output).
///
/// Call [add] any number of times, then [finalize] (normal hash) or
/// [finalizeSubtree] (chaining value of a piece; see [Blake3.pieceCv]).
class Blake3Hasher {
  Blake3Hasher({int chunkCounterOffset = 0}) : _counterOffset = chunkCounterOffset {
    _cv.setAll(0, _iv);
  }

  final int _counterOffset;

  // --- state of the current (partial) chunk ---
  final Uint32List _cv = Uint32List(8);
  // 64-byte block buffer with a 32-bit word view of the same memory.
  final Uint8List _block = Uint8List(_blockLen);
  late final Uint32List _blockWords = Uint32List.view(_block.buffer);
  int _blockFill = 0;
  int _blocksCompressed = 0;

  /// Number of finished chunks in this hasher (relative to the offset).
  int _chunksDone = 0;

  /// Stack of subtree CVs waiting to be merged.
  final List<Uint32List> _stack = [];

  // Aligned scratch buffer so full chunks can be read as 32-bit words.
  static final Uint8List _scratch = Uint8List(_chunkLen);
  static final Uint32List _scratchWords = Uint32List.view(_scratch.buffer);

  int get _chunkStateLen => _blocksCompressed * _blockLen + _blockFill;

  /// Adds bytes `data[start..end)` to the hash.
  void add(Uint8List data, [int start = 0, int? end]) {
    var pos = start;
    final stop = end ?? data.length;
    while (pos < stop) {
      // A finished chunk is only closed once more input arrives, because
      // the very last chunk must be finalized differently.
      if (_chunkStateLen == _chunkLen) {
        _finishChunk();
      }
      // Fast path: whole chunk available and more input after it.
      if (_chunkStateLen == 0 && stop - pos > _chunkLen) {
        _scratch.setRange(0, _chunkLen, data, pos);
        _compressFullChunk();
        pos += _chunkLen;
        continue;
      }
      // Slow path: fill the block buffer.
      if (_blockFill == _blockLen) {
        _compress(_cv, _blockWords, 0, _counterOffset + _chunksDone, _blockLen,
            _blocksCompressed == 0 ? _flagChunkStart : 0, _cv);
        _blocksCompressed++;
        _blockFill = 0;
      }
      final take = _min(_blockLen - _blockFill, stop - pos);
      _block.setRange(_blockFill, _blockFill + take, data, pos);
      _blockFill += take;
      pos += take;
    }
  }

  /// Compresses the full chunk held in [_scratch] and pushes its CV.
  void _compressFullChunk() {
    final cv = Uint32List.fromList(_iv);
    final counter = _counterOffset + _chunksDone;
    for (var b = 0; b < 16; b++) {
      var flags = 0;
      if (b == 0) flags |= _flagChunkStart;
      if (b == 15) flags |= _flagChunkEnd;
      _compress(cv, _scratchWords, b * 16, counter, _blockLen, flags, cv);
    }
    _pushChunkCv(cv);
  }

  /// Closes the current (full) chunk state and pushes its CV.
  void _finishChunk() {
    final out = Uint32List(8);
    _outputCv(out, 0);
    _pushChunkCv(out);
    _resetChunkState();
  }

  void _resetChunkState() {
    _cv.setAll(0, _iv);
    _block.fillRange(0, _blockLen, 0);
    _blockFill = 0;
    _blocksCompressed = 0;
  }

  void _pushChunkCv(Uint32List cv) {
    _chunksDone++;
    var total = _chunksDone;
    var newCv = cv;
    // Merge completed subtrees: one merge per trailing zero bit.
    while ((total & 1) == 0) {
      newCv = _parentCv(_stack.removeLast(), newCv, 0);
      total >>= 1;
    }
    _stack.add(newCv);
  }

  /// Computes the output CV of the current chunk state with [extraFlags].
  void _outputCv(Uint32List out, int extraFlags) {
    // Zero-pad the unused part of the block.
    _block.fillRange(_blockFill, _blockLen, 0);
    var flags = _flagChunkEnd | extraFlags;
    if (_blocksCompressed == 0) flags |= _flagChunkStart;
    _compress(_cv, _blockWords, 0, _counterOffset + _chunksDone, _blockFill, flags, out);
  }

  /// Returns the normal 32-byte BLAKE3 hash. The hasher must not be reused.
  Uint8List finalize() => _wordsToBytes(_finish(root: true));

  /// Returns the (non-root) chaining value of everything added so far.
  Uint8List finalizeSubtree() => _wordsToBytes(_finish(root: false));

  Uint32List _finish({required bool root}) {
    final out = Uint32List(8);
    if (_stack.isEmpty) {
      _outputCv(out, root ? _flagRoot : 0);
      return out;
    }
    // Last chunk output, then fold the stack from the top down.
    _outputCv(out, 0);
    var cur = out;
    for (var i = _stack.length - 1; i >= 0; i--) {
      final isTop = i == 0;
      cur = _parentCv(_stack[i], cur, (isTop && root) ? _flagRoot : 0);
    }
    return cur;
  }
}

int _min(int a, int b) => a < b ? a : b;
