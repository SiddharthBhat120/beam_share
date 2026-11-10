// Where the sender's bytes come from.
//
// The engine only needs "open this file and let me read at offsets". On
// Windows/iOS that's a normal path. On Android, files picked through the
// system picker are content:// URIs; the app reads their raw bytes through a
// small Kotlin channel (ContentResolver + FileChannel), so we still send the
// original bytes with no temporary copy and no re-encoding.

import 'dart:io';
import 'dart:typed_data';

/// Random-access reader for one open source file.
abstract class SourceReader {
  /// Reads exactly [length] bytes at [offset] (fewer only at end of file).
  Future<Uint8List> readAt(int offset, int length);
  Future<void> close();
}

/// [SourceReader] backed by a dart:io [RandomAccessFile].
class FileSourceReader implements SourceReader {
  FileSourceReader(this._raf);
  final RandomAccessFile _raf;

  @override
  Future<Uint8List> readAt(int offset, int length) async {
    await _raf.setPosition(offset);
    return _raf.read(length);
  }

  @override
  Future<void> close() => _raf.close();
}

/// One item to send.
abstract class SourceFile {
  /// Relative path inside the transfer, '/'-separated ("Trip/IMG_1.HEIC").
  String get relativePath;
  int get size;
  DateTime get modified;
  bool get isDirectory;

  /// Opens the file for reading. Called lazily, one file at a time.
  Future<SourceReader> open();
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
  Future<SourceReader> open() async => FileSourceReader(await file.open());
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
  Future<SourceReader> open() => throw UnsupportedError('directory');
}

/// A source whose reader is created by a callback (used for Android
/// content URIs and similar).
class CallbackSourceFile extends SourceFile {
  CallbackSourceFile({
    required this.relativePath,
    required this.size,
    required this.modified,
    required Future<SourceReader> Function() opener,
  }) : _opener = opener;

  @override
  final String relativePath;
  @override
  final int size;
  @override
  final DateTime modified;
  final Future<SourceReader> Function() _opener;

  @override
  bool get isDirectory => false;
  @override
  Future<SourceReader> open() => _opener();
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
