/// One file or folder the user picked to send.
///
/// Stored as plain data (not dart:io objects) so it can be passed to the
/// background engine isolate as a simple map.
class PickedItem {
  const PickedItem({
    required this.kind,
    required this.relativePath,
    required this.size,
    required this.modifiedMs,
    this.path,
    this.uri,
  });

  /// "file" (local path), "dir" (folder entry), "uri" (Android content://).
  final String kind;

  /// Path inside the transfer, '/'-separated.
  final String relativePath;
  final int size;
  final int modifiedMs;
  final String? path;
  final String? uri;

  bool get isDir => kind == 'dir';

  String get name => relativePath.split('/').last;

  /// Top-level group shown in the selection list ("Holiday" for a folder).
  String get topLevel => relativePath.split('/').first;

  Map<String, Object?> toMap() => {
        'kind': kind,
        'rel': relativePath,
        'size': size,
        'mtime': modifiedMs,
        'path': path,
        'uri': uri,
      };

  factory PickedItem.fromMap(Map<dynamic, dynamic> m) => PickedItem(
        kind: m['kind'] as String,
        relativePath: m['rel'] as String,
        size: (m['size'] as num).toInt(),
        modifiedMs: (m['mtime'] as num).toInt(),
        path: m['path'] as String?,
        uri: m['uri'] as String?,
      );
}
