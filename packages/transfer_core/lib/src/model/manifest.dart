// The manifest: the list of everything being sent.

/// Files at or below this size are sent whole (packed with other small
/// files). Bigger files are split into pieces.
const int wholeFileLimit = 4 * 1024 * 1024;

/// Picks the piece size for a file of [size] bytes (0 = send whole).
///
/// Piece sizes must be a power-of-two multiple of 1 KiB so the per-piece
/// BLAKE3 values combine into the real file hash (see blake3.dart).
int pieceSizeFor(int size) {
  if (size <= wholeFileLimit) return 0;
  if (size >= 1024 * 1024 * 1024) return 8 * 1024 * 1024; // >= 1 GiB
  return 4 * 1024 * 1024;
}

/// One file or folder in the transfer.
class ManifestEntry {
  ManifestEntry({
    required this.id,
    required this.path,
    required this.size,
    required this.modifiedMs,
    required this.isDirectory,
    required this.pieceSize,
  });

  /// Index in the manifest (used on the wire instead of the path).
  final int id;

  /// Relative path with '/' separators, e.g. "Holiday/IMG_0001.HEIC".
  final String path;
  final int size;

  /// Last-modified time, milliseconds since epoch (UTC).
  final int modifiedMs;
  final bool isDirectory;

  /// 0 = whole file in one segment, otherwise the piece size in bytes.
  final int pieceSize;

  bool get isChunked => pieceSize > 0;

  int get pieceCount {
    if (isDirectory) return 0;
    if (!isChunked) return 1;
    return (size + pieceSize - 1) ~/ pieceSize;
  }

  /// Length of piece [index].
  int pieceLength(int index) {
    if (!isChunked) return size;
    final start = index * pieceSize;
    final end = start + pieceSize > size ? size : start + pieceSize;
    return end - start;
  }

  /// Compact JSON form: [id, path, size, mtime, pieceSize, isDir].
  List<Object> toJson() => [id, path, size, modifiedMs, pieceSize, isDirectory ? 1 : 0];

  factory ManifestEntry.fromJson(List<dynamic> j) => ManifestEntry(
        id: j[0] as int,
        path: j[1] as String,
        size: j[2] as int,
        modifiedMs: j[3] as int,
        pieceSize: j[4] as int,
        isDirectory: (j[5] as int) == 1,
      );
}

class Manifest {
  Manifest(this.entries);

  final List<ManifestEntry> entries;

  int get totalBytes => entries.fold(0, (s, e) => s + (e.isDirectory ? 0 : e.size));
  int get fileCount => entries.where((e) => !e.isDirectory).length;

  Map<String, Object> toJson() => {
        't': 'manifest',
        'entries': [for (final e in entries) e.toJson()],
      };

  factory Manifest.fromJson(Map<String, dynamic> j) {
    final list = (j['entries'] as List).cast<List<dynamic>>();
    final entries = [for (final e in list) ManifestEntry.fromJson(e)];
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      if (e.id != i) throw FormatException('manifest ids must be 0..n-1');
      if (e.size < 0) throw FormatException('negative size');
      if (e.isChunked && (e.size <= e.pieceSize)) {
        throw FormatException('chunked file must have >= 2 pieces');
      }
    }
    return Manifest(entries);
  }
}
