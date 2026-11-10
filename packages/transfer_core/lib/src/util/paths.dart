import 'dart:io';

/// Thrown when a peer sends a path that could escape the destination folder.
class UnsafePathException implements Exception {
  UnsafePathException(this.path);
  final String path;
  @override
  String toString() => 'Unsafe path rejected: $path';
}

const _windowsReserved = {
  'CON', 'PRN', 'AUX', 'NUL', //
  'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
  'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
};

/// Splits a manifest path (always '/'-separated) into safe segments.
///
/// Security: a malicious sender could try `../../Windows/x` or `C:\x`.
/// We reject `..`, absolute paths and drive letters, and replace characters
/// that are illegal on Windows/Android so every platform can store the file.
List<String> safeSegments(String manifestPath) {
  if (manifestPath.isEmpty) throw UnsafePathException(manifestPath);
  if (manifestPath.startsWith('/') || manifestPath.startsWith('\\')) {
    throw UnsafePathException(manifestPath);
  }
  if (RegExp(r'^[a-zA-Z]:').hasMatch(manifestPath)) {
    throw UnsafePathException(manifestPath);
  }
  final parts = manifestPath.split(RegExp(r'[\\/]'));
  final out = <String>[];
  for (final raw in parts) {
    if (raw.isEmpty || raw == '.') continue;
    if (raw == '..') throw UnsafePathException(manifestPath);
    out.add(sanitizeName(raw));
  }
  if (out.isEmpty) throw UnsafePathException(manifestPath);
  return out;
}

/// Makes one file/folder name valid on all platforms.
String sanitizeName(String name) {
  var n = name.replaceAll(RegExp(r'[<>:"|?*\x00-\x1F]'), '_');
  // Windows does not allow trailing dots/spaces.
  n = n.replaceAll(RegExp(r'[. ]+$'), '');
  if (n.isEmpty) n = '_';
  final stem = n.split('.').first.toUpperCase();
  if (_windowsReserved.contains(stem)) n = '_$n';
  return n;
}

/// Joins the safe segments of [manifestPath] below [root].
String safeJoin(String root, String manifestPath) {
  final segs = safeSegments(manifestPath);
  return [root, ...segs].join(Platform.pathSeparator);
}

/// Returns [path] or, if it exists, "name (1).ext", "name (2).ext", ...
String uniquePath(String path, {Set<String> reserved = const {}}) {
  bool taken(String p) =>
      reserved.contains(p) ||
      FileSystemEntity.typeSync(p, followLinks: false) != FileSystemEntityType.notFound;
  if (!taken(path)) return path;
  final sep = Platform.pathSeparator;
  final slash = path.lastIndexOf(sep);
  final dir = slash >= 0 ? path.substring(0, slash + 1) : '';
  final name = slash >= 0 ? path.substring(slash + 1) : path;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  for (var i = 1;; i++) {
    final candidate = '$dir$stem ($i)$ext';
    if (!taken(candidate)) return candidate;
  }
}
