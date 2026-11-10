/// Beam Share transfer engine.
///
/// Pure Dart, no Flutter imports, so it can be tested with `dart test` and
/// later replaced by a Rust core without touching the UI.
///
/// Typical use (sender listening, receiver scanning a QR code):
///
/// ```dart
/// final server = await BeamServer.start(me: me, myRole: 'sender',
///     identity: identity, token: qr.token);
/// final link = await server.sessions.first;
/// final summary = await TransferSender(link: link, sources: files).run();
///
/// // on the other device
/// final link = await DialerLink.connect(hosts: qr.hosts, port: qr.port,
///     fingerprint: qr.fingerprint, token: qr.token, me: me, role: 'receiver');
/// final summary = await TransferReceiver(link: link, destination: dir).run();
/// ```
library;

export 'src/hash/blake3.dart';
export 'src/model/manifest.dart';
export 'src/model/progress.dart';
export 'src/model/source.dart';
export 'src/net/identity.dart';
export 'src/net/link.dart';
export 'src/net/pairing.dart';
export 'src/protocol/data_unit.dart' show encodeBits, decodeBits;
export 'src/transfer/options.dart';
export 'src/transfer/receiver.dart';
export 'src/transfer/sender.dart';
export 'src/util/paths.dart';
