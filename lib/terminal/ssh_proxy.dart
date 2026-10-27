import 'package:dartssh2/dartssh2.dart';

import 'ssh_proxy_config.dart';
import 'ssh_proxy_stub.dart'
    if (dart.library.io) 'ssh_proxy_io.dart'
    as platform;

export 'ssh_proxy_config.dart';

Future<SSHSocket> connectSshThroughProxy({
  required SshProxyConfig proxy,
  required String targetHost,
  required int targetPort,
  String? password,
  Duration timeout = const Duration(seconds: 15),
}) => platform.connectSshThroughProxy(
  proxy: proxy,
  targetHost: targetHost,
  targetPort: targetPort,
  password: password,
  timeout: timeout,
);
