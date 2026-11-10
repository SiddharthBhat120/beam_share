// Localhost speed benchmark.
//
// For real numbers compile it first (JIT is ~40% slower):
//   dart compile exe bin/benchmark.dart -o build/benchmark.exe
//   build/benchmark.exe            (default 1 GB big file + 500 small files)
//   build/benchmark.exe 4096       (4 GB big file)
//
// Prints BLAKE3 speed and transfer MB/s for different stream counts, with
// and without TLS. Sender and receiver run in separate isolates (threads).
// A real Wi-Fi transfer is limited by the radio, not by these numbers.

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:transfer_core/transfer_core.dart';

const mb = 1024 * 1024;
const me = DeviceInfo(id: 'bench-a', name: 'Bench A', platform: 'bench');
const peer = DeviceInfo(id: 'bench-b', name: 'Bench B', platform: 'bench');

Future<void> main(List<String> args) async {
  final bigMb = args.isNotEmpty ? int.parse(args[0]) : 1024;
  final tmp = await Directory.systemTemp.createTemp('beam_bench');
  try {
    // --- hash speed ---
    final buf = Uint8List(256 * mb);
    for (var i = 0; i < buf.length; i += 4096) {
      buf[i] = i & 0xFF;
    }
    Blake3.hash(Uint8List.sublistView(buf, 0, 16 * mb)); // warm up
    final hsw = Stopwatch()..start();
    Blake3.hash(buf);
    print('BLAKE3 hashing: ${(256 / (hsw.elapsedMicroseconds / 1e6)).toStringAsFixed(0)} MB/s (one core)');

    // --- dataset ---
    stdout.write('Creating dataset ($bigMb MB file + 500 small files)... ');
    final root = Directory('${tmp.path}/data/Bench');
    await root.create(recursive: true);
    final big = await File('${root.path}/big.bin').open(mode: FileMode.write);
    for (var i = 0; i < bigMb ~/ 64; i++) {
      await big.writeFrom(Uint8List.sublistView(buf, (i % 4) * 64 * mb, (i % 4 + 1) * 64 * mb));
    }
    await big.close();
    for (var i = 0; i < 500; i++) {
      await File('${root.path}/small_$i.jpg').writeAsBytes(Uint8List.sublistView(buf, i * 1000, i * 1000 + 150000));
    }
    print('done');

    final identity = BeamIdentity.generate();
    final sources = await collectLocalSources([root.path]);
    final total = sources.fold<int>(0, (s, e) => s + e.size);

    for (final secure in [true, false]) {
      for (final streams in [1, 2, 3, 4]) {
        final dst = await Directory('${tmp.path}/out_${secure}_$streams').create();
        final opts = LinkOptions(dataStreams: streams, secure: secure);
        final token = randomToken();
        final server = await BeamServer.start(
            me: me, myRole: 'sender', identity: identity, token: token, options: opts);
        final sw = Stopwatch()..start();
        final sendF = server.sessions.first.then((l) => TransferSender(link: l, sources: sources).run());
        // The receiver runs in its own isolate (own CPU thread), like a real
        // second device would.
        final port = server.port, fp = identity.fingerprint, dstPath = dst.path;
        final r = await Isolate.run(() async {
          final link = await DialerLink.connect(
              hosts: ['127.0.0.1'], port: port, fingerprint: fp, me: peer, role: 'receiver', token: token, options: opts);
          final s = await TransferReceiver(link: link, destination: dstPath).run();
          return (s.filesVerified, s.filesFailed);
        });
        await sendF;
        sw.stop();
        await server.close();
        final speed = total / mb / (sw.elapsedMicroseconds / 1e6);
        print('${secure ? 'TLS  ' : 'plain'}  streams=$streams  '
            '${(total / mb).toStringAsFixed(0)} MB in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s  '
            '=> ${speed.toStringAsFixed(1)} MB/s  verified=${r.$1} errors=${r.$2}');
        await dst.delete(recursive: true);
      }
    }
  } finally {
    await tmp.delete(recursive: true);
  }
}
