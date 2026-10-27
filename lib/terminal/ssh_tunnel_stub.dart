import 'package:dartssh2/dartssh2.dart';

import 'ssh_tunnel.dart' show SshTunnelHandle, SshTunnelSpec;

Future<SshTunnelHandle> startSshTunnel(
  SSHClient client,
  SshTunnelSpec spec,
) async => throw UnsupportedError('SSH 隧道在此平台不可用');
