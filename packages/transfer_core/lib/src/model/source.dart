// Where the sender's bytes come from.
//
// The engine only needs "open this file and let me read at offsets". On
// Windows/iOS that's a normal path. On Android, files picked through the
// system picker are content:// URIs; the app turns each one into a raw file
// descriptor (/proc/self/fd/N), so we still read the original bytes directly,
// with no copying and no re-encoding.

import 'dart:io';

/// One item to send.
abstract class SourceFile {
  /// Relative path inside the transfer, '/'-separated ("Trip/IMG_1.HEIC").
  String get relativePath;
  int get size;
  DateTime get modified;
  bool get isDirectory;

  /// Opens the file for reading. Called lazily, one file at a time.
  Future<RandomAccessFile> open();

  /// Called after the file was closed (e.g. to release an Android fd).
  Future<void> release() async {}
}

/// A file on the local file system.
class LocalSourceFile extends SourceFile {
  LocalSourceFile(this.file, this.relativePath, {int? size, DateTime? modified})
      : size = size ?? file.lengthSync(),
        modified = modified ?? file.lastModifiedSync();

  final File file;
  @override
  final String relativePath;
  @override
  final int size;
  @override
  final DateTime modified;
  @override
  bool get isDirectory => false;

  @override
  Future<RandomAccessFile> open() => file.open();
}

/// A folder entry (keeps empty folders and folder structure).
class DirectorySource extends SourceFile {
  DirectorySource(this.relativePath, this.modified);

  @override
  final String relativePath;
  @override
  final DateTime modified;
  @override
  int get size => 0;
  @override
  bool get isDirectory => true;

  @override
  Future<RandomAccessFile> open() => throw UnsupportedError('directory');
}

/// A source whose bytes are opened by a callback (used for Android fds and
/// iOS exported photos).
class CallbackSourceFile extends SourceFile {
  CallbackSourceFile({
    required this.relativePath,
    required this.size,
    required this.modified,
    required Future<RandomAccessFile> Function() opener,
    Future<void> Function()? releaser,
  })  : _opener = opener,
        _releaser = releaser;

  @override
  final String relativePath;
  @override
  final int size;
  @override
  final DateTime modified;
  final Future<RandomAccessFile> Function() _opener;
  final Future<void> Function()? _releaser;

  @override
  bool get isDirectory => false;
  @override
  Future<RandomAccessFile> open() => _opener();
  @override
  Future<void> release() async => _releaser?.call();
}

/// Builds sources from local paths. Folders are walked recursively and keep
/// their own name as the top-level folder.
Future<List<SourceFile>> collectLocalSources(List<String> paths) async {
  final out = <SourceFile>[];
  for (final p in paths) {
    final type = await FileSystemEntity.type(p, followLinks: true);
    if (type == FileSystemEntityType.file) {
      final f = File(p);
      out.add(LocalSourceFile(f, _baseName(p)));
    } else if (type == FileSystemEntityType.directory) {
      final root = Directory(p);
      final rootName = _baseName(p);
      out.add(DirectorySource(rootName, (await root.stat()).modified));
      await for (final ent in root.list(recursive: true, followLinks: false)) {
        final rel = ent.path.substring(root.path.length).replaceAll('\\', '/');
        final relPath = '$rootName${rel.startsWith('/') ? rel : '/$rel'}';
        final st = await ent.stat();
        if (st.type == FileSystemEntityType.directory) {
          out.add(DirectorySource(relPath, st.modified));
        } else if (st.type == FileSystemEntityType.file) {
          out.add(LocalSourceFile(File(ent.path), relPath, size: st.size, modified: st.modified));
        }
      }
    }
  }
  return out;
}

String _baseName(String p) {
  final norm = p.replaceAll('\\', '/');
  final trimmed = norm.endsWith('/') ? norm.substring(0, norm.length - 1) : norm;
  return trimmed.substring(trimmed.lastIndexOf('/') + 1);
}
