// Big end-to-end test (several GB of disk, a minute or two).
//
//   dart test test/integration_test.dart
//
// 1. Sends a folder with 1,000 small files (nested folders, empty files, an
//    empty folder) plus three big files of 520 MB, 600 MB and 1.1 GB between
//    two engine instances over localhost with TLS, then compares every byte
//    and every modified date.
// 2. Sends again and kills the connection twice mid-transfer; checks that
//    the transfer resumes and still ends with identical files.

@Tags(['integration'])
@Timeout(Duration(minutes: 20))
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:transfer_core/transfer_core.dart';

import 'helpers.dart';

const mb = 1024 * 1024;

Future<void> makeDataset(String root) async {
  for (var i = 0; i < 1000; i++) {
    final dir = '$root/Photos/Folder ${i % 10}/Sub ${i % 3}';
    await Directory(dir).create(recursive: true);
    // sizes from 0 bytes to ~300 KB, a few around the 4 MB boundary
    final size = i == 0 ? 0 : (i % 97 == 0 ? 4 * mb + (i % 3) - 1 : (i * 7919) % 300000);
    final f = File('$dir/IMG_${i.toString().padLeft(4, '0')}.jpg');
    await f.writeAsBytes(randomBytes(size, i + 11));
    await f.setLastModified(DateTime(2023, 1 + i % 12, 1 + i % 28, i % 24, i % 60));
  }
  await Directory('$root/Photos/Empty folder').create(recursive: true);
  await writeBigFile('$root/Photos/video_520mb.mov', 520 * mb + 13, 1);
  await writeBigFile('$root/Photos/backup_600mb.zip', 600 * mb, 2);
  await writeBigFile('$root/Photos/movie_1100mb.mkv', 1100 * mb + 4097, 3); // 8 MB pieces
  await File('$root/Photos/movie_1100mb.mkv').setLastModified(DateTime(2019, 7, 4, 12));
}

void main() {
  late BeamIdentity identity;
  late Directory src;
  setUpAll(() async {
    identity = BeamIdentity.generate();
    src = await tempDir('itest_src');
    await makeDataset(src.path);
  });
  tearDownAll(() async => src.delete(recursive: true));

  test('1,000 small files + 3 big files: every byte matches', () async {
    final dst = await tempDir('itest_dst');
    try {
      final sources = await collectLocalSources(['${src.path}/Photos']);
      final total = sources.fold<int>(0, (s, e) => s + e.size);
      final sw = Stopwatch()..start();
      final (s, r) = await runLocalTransfer(identity: identity, sources: sources, destination: dst.path);
      sw.stop();
      final mbps = total / mb / (sw.elapsedMilliseconds / 1000);
      print('Transferred ${(total / mb).toStringAsFixed(0)} MB, ${r.filesVerified} files '
          'in ${sw.elapsed.inMilliseconds / 1000}s = ${mbps.toStringAsFixed(1)} MB/s (TLS, localhost)');
      expect(s.success, isTrue, reason: s.errors.join('\n'));
      expect(r.success, isTrue, reason: r.errors.join('\n'));
      expect(r.filesVerified, 1003);
      final checked = await compareTrees('${src.path}/Photos', '${dst.path}/Photos');
      expect(checked, 1003);
      print('Byte-by-byte comparison: $checked files identical, dates preserved.');
    } finally {
      await dst.delete(recursive: true);
    }
  });

  test('connection drops twice mid-transfer and the transfer resumes', () async {
    final dst = await tempDir('itest_resume');
    try {
      final sources = await collectLocalSources(['${src.path}/Photos']);
      final total = sources.fold<int>(0, (s, e) => s + e.size);
      final drops = <int>[];
      final (s, r) = await runLocalTransfer(
        identity: identity,
        sources: sources,
        destination: dst.path,
        onReceiverStarted: (link, receiver) {
          receiver.progress.listen((p) {
            final pct = p.totalBytes == 0 ? 0 : p.doneBytes * 100 ~/ p.totalBytes;
            if ((drops.isEmpty && pct >= 25) || (drops.length == 1 && pct >= 60)) {
              drops.add(pct);
              print('Simulating Wi-Fi loss at $pct% ...');
              link.debugDropConnections();
            }
          });
        },
      );
      expect(drops.length, 2);
      expect(r.reconnects, greaterThanOrEqualTo(2));
      expect(s.success && r.success, isTrue, reason: '${s.errors}\n${r.errors}');
      expect(r.bytes, total);
      final checked = await compareTrees('${src.path}/Photos', '${dst.path}/Photos');
      expect(checked, 1003);
      print('Resumed after ${r.reconnects} disconnects; $checked files identical.');
    } finally {
      await dst.delete(recursive: true);
    }
  });
}
