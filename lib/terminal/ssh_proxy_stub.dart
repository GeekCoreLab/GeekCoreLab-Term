import 'package:dartssh2/dartssh2.dart';

import 'ssh_proxy_config.dart';

Future<SSHSocket> connectSshThroughProxy({
  required SshProxyConfig proxy,
  required String targetHost,
  required int targetPort,
  String? password,
  required Duration timeout,
}) => Future.error(UnsupportedError('当前平台不支持 SSH TCP 代理，请使用 WebSocket SSH 网关'));
