import 'dart:async';

export 'network_diagnostics_models.dart';

import 'network_diagnostics_models.dart';
import 'network_diagnostics_stub.dart'
    if (dart.library.io) 'network_diagnostics_io.dart'
    as platform;

void _validateHost(String host) {
  final normalized = host.trim();
  if (normalized.isEmpty || normalized.length > 253) {
    throw const FormatException('主机名不能为空，且长度不能超过 253 个字符');
  }
  if (normalized.contains(RegExp(r'\s'))) {
    throw const FormatException('主机名不能包含空格或换行');
  }
}

void _validateTimeout(Duration timeout) {
  if (timeout < const Duration(seconds: 1) ||
      timeout > const Duration(seconds: 30)) {
    throw const FormatException('超时时间必须在 1 到 30 秒之间');
  }
}

Future<List<String>> lookupNetworkHost(
  String host, {
  Duration timeout = const Duration(seconds: 5),
}) {
  _validateHost(host);
  _validateTimeout(timeout);
  return platform.lookupNetworkHost(host.trim(), timeout: timeout);
}

Future<TcpProbeResult> probeTcpPort(
  String host,
  int port, {
  Duration timeout = const Duration(seconds: 5),
}) {
  _validateHost(host);
  if (port < 1 || port > 65535) {
    throw const FormatException('TCP 端口范围为 1 到 65535');
  }
  _validateTimeout(timeout);
  return platform.probeTcpPort(host.trim(), port, timeout: timeout);
}
