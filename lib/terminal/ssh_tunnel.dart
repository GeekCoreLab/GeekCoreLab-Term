import 'package:dartssh2/dartssh2.dart';

import 'ssh_tunnel_stub.dart'
    if (dart.library.io) 'ssh_tunnel_io.dart'
    as platform;

enum SshTunnelType { local, remote, dynamic }

class SshTunnelSpec {
  const SshTunnelSpec({
    required this.type,
    this.bindHost = '127.0.0.1',
    required this.bindPort,
    this.targetHost = '',
    this.targetPort = 0,
  });

  final SshTunnelType type;
  final String bindHost;
  final int bindPort;
  final String targetHost;
  final int targetPort;

  void validate() {
    if (bindHost.trim().isEmpty) {
      throw const FormatException('监听地址不能为空');
    }
    if (bindPort < 0 || bindPort > 65535) {
      throw const FormatException('监听端口范围为 0 到 65535');
    }
    if (type != SshTunnelType.dynamic) {
      if (targetHost.trim().isEmpty) {
        throw const FormatException('目标地址不能为空');
      }
      if (targetPort < 1 || targetPort > 65535) {
        throw const FormatException('目标端口范围为 1 到 65535');
      }
    }
  }
}

abstract interface class SshTunnelHandle {
  SshTunnelSpec get spec;
  String get boundHost;
  int get boundPort;
  bool get isClosed;
  Future<void> close();
}

Future<SshTunnelHandle> startSshTunnel(SSHClient client, SshTunnelSpec spec) {
  spec.validate();
  return platform.startSshTunnel(client, spec);
}
