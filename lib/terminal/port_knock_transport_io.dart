import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'session_store.dart';

const _androidPortKnockChannel = MethodChannel(
  'cn.geekcorelab.geekcore_term/port_knock',
);

Future<void> knockOnce(
  String host,
  PortKnockProtocol protocol,
  int port, {
  Uri? webSocketUri,
}) async {
  switch (protocol) {
    case PortKnockProtocol.tcp:
      Socket? socket;
      try {
        socket = await Socket.connect(
          host,
          port,
          timeout: const Duration(seconds: 5),
        );
      } on SocketException {
        // A refused TCP connection still sends the packet used for port knocking.
      } on TimeoutException {
        // A filtered port may not complete a TCP handshake; the attempt is the knock.
      } finally {
        socket?.destroy();
      }
    case PortKnockProtocol.udp:
      final addresses = await InternetAddress.lookup(host);
      if (addresses.isEmpty) throw SocketException('无法解析目标主机：$host');
      final address = addresses.first;
      final socket = await RawDatagramSocket.bind(
        address.type == InternetAddressType.IPv6
            ? InternetAddress.anyIPv6
            : InternetAddress.anyIPv4,
        0,
      );
      try {
        socket.send(Uint8List(0), address, port);
      } finally {
        socket.close();
      }
    case PortKnockProtocol.icmp:
      if (Platform.isAndroid) {
        await _androidPortKnockChannel.invokeMethod<void>('icmpEcho', {
          'host': host,
        });
      } else if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
        final arguments = switch (Platform.operatingSystem) {
          'windows' => ['-n', '1', '-w', '2000', host],
          'macos' => ['-c', '1', '-W', '2000', host],
          _ => ['-c', '1', '-W', '2', host],
        };
        final result = await Process.run('ping', arguments);
        // Linux and Windows use 1 for no reply; macOS uses 2 after a successful
        // transmission without a reply. Those still count as sent knocks.
        final noReplyExitCode = Platform.isMacOS ? 2 : 1;
        if (result.exitCode != 0 && result.exitCode != noReplyExitCode) {
          final details = '${result.stderr}'.trim();
          throw ProcessException(
            'ping',
            arguments,
            details.isEmpty ? 'ICMP 敲门失败' : details,
            result.exitCode,
          );
        }
      } else {
        throw UnsupportedError('当前平台不支持 ICMP 敲门');
      }
  }
}
