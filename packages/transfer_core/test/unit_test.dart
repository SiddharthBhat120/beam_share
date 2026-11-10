import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:transfer_core/transfer_core.dart';
import 'package:transfer_core/src/protocol/data_unit.dart';
import 'package:transfer_core/src/protocol/frames.dart';
import 'package:transfer_core/src/util/async_utils.dart';

import 'helpers.dart';

void main() {
  late BeamIdentity identity;
  setUpAll(() => identity = BeamIdentity.generate());

  group('manifest', () {
    test('piece size rules', () {
      expect(pieceSizeFor(0), 0);
      expect(pieceSizeFor(4 * 1024 * 1024), 0); // exactly 4 MiB: whole
      expect(pieceSizeFor(4 * 1024 * 1024 + 1), 4 * 1024 * 1024);
      expect(pieceSizeFor(1024 * 1024 * 1024), 8 * 1024 * 1024);
    });

    test('piece count and lengths', () {
      final e = ManifestEntry(
          id: 0, path: 'a', size: 10 * 1024 * 1024 + 5, modifiedMs: 0, isDirectory: false, pieceSize: 4 << 20);
      expect(e.pieceCount, 3);
      expect(e.pieceLength(0), 4 << 20);
      expect(e.pieceLength(2), 2 * 1024 * 1024 + 5);
    });

    test('JSON round trip and duplicate names', () async {
      final dir = await tempDir('manifest');
      final a = File('${dir.path}/a.txt')..writeAsStringSync('hello');
      final b = File('${dir.path}/b.txt')..writeAsStringSync('world');
      final sources = [
        LocalSourceFile(a, 'photo.jpg'),
        LocalSourceFile(b, 'photo.jpg'),
        DirectorySource('Empty', DateTime(2020)),
      ];
      final m = TransferSender.buildManifest(sources);
      expect(m.entries.map((e) => e.path), ['photo.jpg', 'photo (1).jpg', 'Empty']);
      final back = Manifest.fromJson(m.toJson());
      expect(back.entries.length, 3);
      expect(back.entries[2].isDirectory, true);
      expect(back.totalBytes, 10);
      expect(back.fileCount, 2);
      await dir.delete(recursive: true);
    });

    test('collectLocalSources keeps folder structure and empty folders', () async {
      final dir = await tempDir('collect');
      await Directory('${dir.path}/Trip/Day 1').create(recursive: true);
      await Directory('${dir.path}/Trip/Empty').create();
      File('${dir.path}/Trip/Day 1/x.bin').writeAsBytesSync([1, 2, 3]);
      final s = await collectLocalSources(['${dir.path}/Trip']);
      final paths = s.map((e) => e.relativePath).toSet();
      expect(paths, containsAll(['Trip', 'Trip/Day 1', 'Trip/Empty', 'Trip/Day 1/x.bin']));
      await dir.delete(recursive: true);
    });
  });

  group('paths', () {
    test('rejects traversal and absolute paths', () {
      for (final bad in ['../x', 'a/../../x', '/etc/passwd', r'C:\Windows\x', r'\\server\x', '']) {
        expect(() => safeSegments(bad), throwsA(isA<UnsafePathException>()), reason: bad);
      }
    });

    test('sanitizes Windows-illegal names', () {
      expect(safeSegments('ab:c/c?d.txt'), ['ab_c', 'c_d.txt']);
      expect(() => safeSegments('a:b'), throwsA(isA<UnsafePathException>())); // looks like a drive
      expect(sanitizeName('CON.txt'), '_CON.txt');
      expect(sanitizeName('name. '), 'name');
    });

    test('uniquePath adds (1), (2)', () async {
      final dir = await tempDir('unique');
      final p = '${dir.path}${Platform.pathSeparator}a.txt';
      File(p).writeAsStringSync('x');
      expect(uniquePath(p), '${dir.path}${Platform.pathSeparator}a (1).txt');
      expect(uniquePath(p, reserved: {'${dir.path}${Platform.pathSeparator}a (1).txt'}),
          '${dir.path}${Platform.pathSeparator}a (2).txt');
      await dir.delete(recursive: true);
    });
  });

  group('wire format', () {
    test('data unit encode/decode', () {
      final segs = [
        Segment(fileId: 3, piece: 0, offset: 0, length: 4, hash: Uint8List(32)..[0] = 9),
        Segment(fileId: 70000, piece: 5, offset: 5 * (8 << 20) + (1 << 33), length: 2, hash: Uint8List(32)),
      ];
      final header = encodeUnitHeader(42, segs);
      final payload = Uint8List.fromList([...header, 1, 2, 3, 4, 5, 6]);
      final d = decodeUnit(payload);
      expect(d.unitId, 42);
      expect(d.segments[1].fileId, 70000);
      expect(d.segments[1].offset, 5 * (8 << 20) + (1 << 33));
      expect(d.segments[0].hash[0], 9);
      expect(d.dataStart, header.length);
      expect(() => decodeUnit(Uint8List.fromList([...header, 1])), throwsFormatException);
    });

    test('bit sets', () {
      final bits = [true, false, true, true, false, false, false, false, true];
      expect(decodeBits(encodeBits(bits), bits.length), bits);
    });

    test('pairing code round trip', () {
      final p = PairingInfo(
        deviceName: 'Phone',
        platform: 'android',
        hosts: ['192.168.49.1', '10.0.0.5'],
        port: 47820,
        fingerprint: identity.fingerprint,
        token: randomToken(),
        role: 'sender',
        ssid: 'DIRECT-bs-Phone',
        passphrase: 'secret123',
      );
      final back = PairingInfo.decode(p.encode());
      expect(back.hosts, p.hosts);
      expect(back.ssid, 'DIRECT-bs-Phone');
      expect(back.passphrase, 'secret123');
      expect(back.role, 'sender');
      expect(back.fingerprint, identity.fingerprint);
      expect(() => PairingInfo.decode('hello'), throwsFormatException);
    });

    test('frame reader splits and joins frames across TCP chunks', () async {
      final ctrl = StreamController<Uint8List>();
      final reader = FrameReader(ctrl.stream);
      // Two frames delivered in odd pieces.
      final f1 = [1, 0, 0, 0, 2, 123, 125]; // JSON "{}"
      final f2 = [2, 0, 0, 0, 3, 7, 8, 9];
      final all = [...f1, ...f2];
      for (var i = 0; i < all.length; i += 3) {
        ctrl.add(Uint8List.fromList(all.sublist(i, i + 3 > all.length ? all.length : i + 3)));
      }
      await ctrl.close();
      final a = await reader.next();
      expect(a!.type, frameJson);
      expect(a.json, isEmpty);
      final b = await reader.next();
      expect(b!.payload, [7, 8, 9]);
      expect(await reader.next(), isNull);
    });
  });

  group('async utils', () {
    test('channel is bounded and putFront jumps the queue', () async {
      final ch = AsyncChannel<int>(2);
      await ch.put(1);
      await ch.put(2);
      var third = false;
      final f = ch.put(3).then((_) => third = true);
      await Future<void>.delayed(Duration.zero);
      expect(third, isFalse); // full
      ch.putFront(0);
      expect(await ch.take(), 0);
      expect(await ch.take(), 1);
      await f;
      expect(third, isTrue);
      ch.close();
      expect(await ch.take(), isNull);
    });
  });

  group('transfer (small, fast)', () {
    late Directory src;
    late Directory dst;
    setUp(() async {
      src = await tempDir('src');
      dst = await tempDir('dst');
      final root = Directory('${src.path}/Album');
      await Directory('${root.path}/Sub/Empty').create(recursive: true);
      for (var i = 0; i < 50; i++) {
        File('${root.path}/small_$i.bin').writeAsBytesSync(randomBytes(i * 997, i + 1));
      }
      File('${root.path}/Sub/empty.txt').writeAsBytesSync([]);
      await writeBigFile('${root.path}/Sub/big.bin', 13 * 1024 * 1024 + 321, 77);
      File('${root.path}/Sub/big.bin').setLastModifiedSync(DateTime(2021, 5, 6, 7, 8, 9));
    });
    tearDown(() async {
      await src.delete(recursive: true);
      await dst.delete(recursive: true);
    });

    test('QR flow: every byte and date matches', () async {
      final sources = await collectLocalSources(['${src.path}/Album']);
      final (s, r) = await runLocalTransfer(identity: identity, sources: sources, destination: dst.path);
      expect(s.success, isTrue, reason: s.errors.join());
      expect(r.success, isTrue, reason: r.errors.join());
      expect(r.filesVerified, 52);
      expect(await compareTrees('${src.path}/Album', '${dst.path}/Album'), 52);
      expect(Directory('${dst.path}/Album/Sub/Empty').existsSync(), isTrue);
      expect(dst.listSync(recursive: true).where((e) => e.path.endsWith('.beampart')), isEmpty);
    });

    test('nearby flow: receiver listens and accepts', () async {
      final sources = await collectLocalSources(['${src.path}/Album']);
      final (s, r) = await runLocalTransfer(
          identity: identity, sources: sources, destination: dst.path, receiverListens: true);
      expect(s.success && r.success, isTrue);
      expect(await compareTrees('${src.path}/Album', '${dst.path}/Album'), 52);
    });

    test('corrupted pieces are detected and only they are re-sent', () async {
      final sources = await collectLocalSources(['${src.path}/Album']);
      final bigId = sources.indexWhere((e) => e.relativePath.endsWith('big.bin'));
      final smallId = sources.indexWhere((e) => e.relativePath.endsWith('small_10.bin'));
      final (s, r) = await runLocalTransfer(
        identity: identity,
        sources: sources,
        destination: dst.path,
        senderOptions: TransferOptions(
          // piece 1 of the big file: corrupt on first send; small file: twice
          debugCorrupt: (f, p, attempt) =>
              (f == bigId && p == 1 && attempt == 1) || (f == smallId && attempt <= 2),
        ),
      );
      expect(s.success && r.success, isTrue, reason: '${s.errors} ${r.errors}');
      expect(r.resentPieces, 3, reason: 'receiver saw exactly 3 bad pieces');
      expect(s.resentPieces, 3, reason: 'sender re-sent exactly 3 pieces');
      expect(await compareTrees('${src.path}/Album', '${dst.path}/Album'), 52);
    });

    test('a piece that is always corrupt fails only that file', () async {
      final sources = await collectLocalSources(['${src.path}/Album']);
      final smallId = sources.indexWhere((e) => e.relativePath.endsWith('small_3.bin'));
      final (s, r) = await runLocalTransfer(
        identity: identity,
        sources: sources,
        destination: dst.path,
        senderOptions: TransferOptions(debugCorrupt: (f, p, a) => f == smallId),
        receiverOptions: const TransferOptions(maxRetries: 2),
      );
      expect(r.filesVerified, 51);
      expect(r.filesFailed, 1);
      expect(s.filesFailed, 1);
      expect(File('${dst.path}/Album/small_3.bin').existsSync(), isFalse);
    });

    test('resume after a dropped connection re-sends only missing pieces', () async {
      await writeBigFile('${src.path}/Album/huge.bin', 64 * 1024 * 1024 + 7, 5);
      final sources = await collectLocalSources(['${src.path}/Album']);
      var dropped = false;
      final (s, r) = await runLocalTransfer(
        identity: identity,
        sources: sources,
        destination: dst.path,
        onReceiverStarted: (link, receiver) {
          receiver.progress.listen((p) {
            if (!dropped && p.doneBytes > 30 * 1024 * 1024) {
              dropped = true;
              link.debugDropConnections(); // simulate Wi-Fi loss
            }
          });
        },
      );
      expect(dropped, isTrue);
      expect(r.reconnects, greaterThanOrEqualTo(1));
      expect(s.success && r.success, isTrue, reason: '${s.errors} ${r.errors}');
      expect(await compareTrees('${src.path}/Album', '${dst.path}/Album'), 53);
    });

    test('cancel stops both sides and removes partial files', () async {
      await writeBigFile('${src.path}/Album/huge.bin', 200 * 1024 * 1024, 5);
      final sources = await collectLocalSources(['${src.path}/Album']);
      final (s, r) = await runLocalTransfer(
        identity: identity,
        sources: sources,
        destination: dst.path,
        onReceiverStarted: (link, receiver) {
          var asked = false;
          receiver.progress.listen((p) {
            if (!asked && p.doneBytes > 20 * 1024 * 1024) {
              asked = true;
              receiver.cancel();
            }
          });
        },
      );
      expect(s.cancelled, isTrue);
      expect(r.cancelled, isTrue);
      expect(dst.listSync(recursive: true).where((e) => e.path.endsWith('.beampart')), isEmpty);
    });
  });

  group('security', () {
    test('wrong certificate fingerprint is refused', () async {
      final server = await BeamServer.start(me: me, myRole: 'sender', identity: identity, token: 'x');
      final other = BeamIdentity.generate();
      await expectLater(
        DialerLink.connect(
            hosts: ['127.0.0.1'], port: server.port, fingerprint: other.fingerprint, me: peer, role: 'receiver', token: 'x'),
        throwsA(anything),
      );
      await server.close();
    });

    test('declined request throws PairingRejected', () async {
      final server = await BeamServer.start(
          me: peer, myRole: 'receiver', identity: identity, onRequest: (_) async => false);
      await expectLater(
        DialerLink.connect(
            hosts: ['127.0.0.1'], port: server.port, fingerprint: identity.fingerprint, me: me, role: 'sender'),
        throwsA(isA<PairingRejected>()),
      );
      await server.close();
    });

    test('same role on both sides is refused', () async {
      final server = await BeamServer.start(me: me, myRole: 'sender', identity: identity, token: 't');
      await expectLater(
        DialerLink.connect(
            hosts: ['127.0.0.1'], port: server.port, fingerprint: identity.fingerprint, me: peer, role: 'sender', token: 't'),
        throwsA(isA<PairingRejected>()),
      );
      await server.close();
    });
  });
}
