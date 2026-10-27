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

const maxTcpPortScanRange = 1024;
const maxTcpPortScanConcurrency = 24;

void _validateScanTimeout(Duration timeout) {
  if (timeout < const Duration(milliseconds: 250) ||
      timeout > const Duration(seconds: 5)) {
    throw const FormatException('扫描超时必须在 250 毫秒到 5 秒之间');
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

Future<TcpPortScanResult> scanTcpPorts(
  String host, {
  required int startPort,
  required int endPort,
  Duration timeout = const Duration(milliseconds: 500),
  int concurrency = maxTcpPortScanConcurrency,
  TcpPortScanCancellation? cancellation,
  void Function(int scannedPorts, int totalPorts)? onProgress,
}) {
  _validateHost(host);
  if (startPort < 1 || endPort > 65535 || startPort > endPort) {
    throw const FormatException('扫描端口范围必须位于 1 到 65535 之间');
  }
  if (endPort - startPort + 1 > maxTcpPortScanRange) {
    throw FormatException('单次最多扫描 $maxTcpPortScanRange 个连续端口');
  }
  _validateScanTimeout(timeout);
  if (concurrency < 1 || concurrency > maxTcpPortScanConcurrency) {
    throw FormatException('并发数必须在 1 到 $maxTcpPortScanConcurrency 之间');
  }
  return platform.scanTcpPorts(
    host.trim(),
    startPort: startPort,
    endPort: endPort,
    timeout: timeout,
    concurrency: concurrency,
    cancellation: cancellation,
    onProgress: onProgress,
  );
}
