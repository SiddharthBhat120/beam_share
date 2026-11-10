import 'dart:io';

/// Enables TCP_NODELAY and asks the OS for large send/receive buffers.
///
/// Big buffers keep a fast Wi-Fi link full even when the app is briefly busy
/// (hashing, disk writes). The OS may cap the value; failures are ignored.
void tuneSocket(Socket socket, {int bufferBytes = 4 * 1024 * 1024}) {
  try {
    socket.setOption(SocketOption.tcpNoDelay, true);
  } catch (_) {}
  // SO_SNDBUF / SO_RCVBUF numbers differ per OS.
  final linuxLike = Platform.isAndroid || Platform.isLinux;
  final sndBuf = linuxLike ? 7 : 0x1001;
  final rcvBuf = linuxLike ? 8 : 0x1002;
  for (final opt in [sndBuf, rcvBuf]) {
    try {
      socket.setRawOption(RawSocketOption.fromInt(RawSocketOption.levelSocket, opt, bufferBytes));
    } catch (_) {}
  }
}
