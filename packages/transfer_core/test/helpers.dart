import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:transfer_core/transfer_core.dart';

const me = DeviceInfo(id: 'test-sender', name: 'Test Sender', platform: 'windows');
const peer = DeviceInfo(id: 'test-receiver', name: 'Test Receiver', platform: 'android');

/// Fast deterministic pseudo-random bytes (xorshift32).
Uint8List randomBytes(int length, int seed) {
  final out = Uint8List(length);
  final words = length ~/ 4;
  final view = Uint32List.view(out.buffer, 0, words);
  var x = seed == 0 ? 0x9E3779B9 : seed;
  for (var i = 0; i < words; i++) {
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    view[i] = x;
  }
  for (var i = words * 4; i < length; i++) {
    out[i] = (i * 7 + seed) & 0xFF;
  }
  return out;
}

/// Writes a big file in 16 MiB steps without holding it all in memory.
Future<void> writeBigFile(String path, int size, int seed) async {
  final f = await File(path).open(mode: FileMode.write);
  const step = 16 * 1024 * 1024;
  var written = 0;
  var s = seed;
  while (written < size) {
    final n = size - written < step ? size - written : step;
    await f.writeFrom(randomBytes(n, s++));
    written += n;
  }
  await f.close();
}

/// Byte-by-byte comparison (independent of our own hashing code).
Future<bool> sameContent(String a, String b) async {
  final fa = File(a), fb = File(b);
  if (await fa.length() != await fb.length()) return false;
  final ra = await fa.open(), rb = await fb.open();
  try {
    const step = 8 * 1024 * 1024;
    while (true) {
      final x = await ra.read(step);
      final y = await rb.read(step);
      if (x.length != y.length) return false;
      if (x.isEmpty) return true;
      for (var i = 0; i < x.length; i++) {
        if (x[i] != y[i]) return false;
      }
    }
  } finally {
    await ra.close();
    await rb.close();
  }
}

/// Compares every file under [srcRoot] with the same path under [dstRoot]
/// (content and modified time). Returns the number of files checked.
Future<int> compareTrees(String srcRoot, String dstRoot) async {
  var count = 0;
  await for (final e in Directory(srcRoot).list(recursive: true)) {
    final rel = e.path.substring(srcRoot.length);
    final other = '$dstRoot$rel';
    if (e is Directory) {
      if (!await Directory(other).exists()) throw StateError('missing folder $rel');
      continue;
    }
    if (e is! File) continue;
    if (!await File(other).exists()) throw StateError('missing file $rel');
    if (!await sameContent(e.path, other)) throw StateError('content differs: $rel');
    final m1 = (await e.lastModified()).millisecondsSinceEpoch ~/ 1000;
    final m2 = (await File(other).lastModified()).millisecondsSinceEpoch ~/ 1000;
    if ((m1 - m2).abs() > 2) throw StateError('modified time differs: $rel');
    count++;
  }
  return count;
}

/// Runs a full sender/receiver pair over localhost (QR flow: the sender
/// listens with a token, the receiver dials).
Future<(TransferSummary, TransferSummary)> runLocalTransfer({
  required BeamIdentity identity,
  required List<SourceFile> sources,
  required String destination,
  TransferOptions senderOptions = const TransferOptions(),
  TransferOptions receiverOptions = const TransferOptions(),
  LinkOptions linkOptions = const LinkOptions(),
  void Function(DialerLink link, TransferReceiver receiver)? onReceiverStarted,
  bool receiverListens = false,
}) async {
  final token = randomToken();
  if (!receiverListens) {
    final server = await BeamServer.start(
        me: me, myRole: 'sender', identity: identity, token: token, options: linkOptions);
    final senderFuture = server.sessions.first.then((link) =>
        TransferSender(link: link, sources: sources, options: senderOptions).run());
    final link = await DialerLink.connect(
      hosts: ['127.0.0.1'],
      port: server.port,
      fingerprint: identity.fingerprint,
      me: peer,
      role: 'receiver',
      token: token,
      options: linkOptions,
    );
    final receiver = TransferReceiver(link: link, destination: destination, options: receiverOptions);
    onReceiverStarted?.call(link, receiver);
    final results = await Future.wait([senderFuture, receiver.run()]);
    await server.close();
    return (results[0], results[1]);
  } else {
    // Nearby flow: receiver waits and accepts via the dialog callback.
    final server = await BeamServer.start(
      me: peer,
      myRole: 'receiver',
      identity: identity,
      onRequest: (req) async => req.role == 'sender',
      options: linkOptions,
    );
    final receiverFuture = server.sessions.first.then((link) =>
        TransferReceiver(link: link, destination: destination, options: receiverOptions).run());
    final link = await DialerLink.connect(
      hosts: ['127.0.0.1'],
      port: server.port,
      fingerprint: identity.fingerprint,
      me: me,
      role: 'sender',
      offer: {'files': sources.length, 'bytes': 0},
      options: linkOptions,
    );
    final sender = TransferSender(link: link, sources: sources, options: senderOptions);
    final results = await Future.wait([sender.run(), receiverFuture]);
    await server.close();
    return (results[0], results[1]);
  }
}

Future<Directory> tempDir(String name) => Directory.systemTemp.createTemp('beam_$name');
