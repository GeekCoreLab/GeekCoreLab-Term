import 'dart:async';

import 'network_diagnostics_models.dart';

Future<List<String>> lookupNetworkHost(
  String host, {
  required Duration timeout,
}) => Future.error(UnsupportedError('本机 DNS 诊断在此平台不可用'));

Future<TcpProbeResult> probeTcpPort(
  String host,
  int port, {
  required Duration timeout,
}) => Future.error(UnsupportedError('本机 TCP 诊断在此平台不可用'));

Future<TcpPortScanResult> scanTcpPorts(
  String host, {
  required int startPort,
  required int endPort,
  required Duration timeout,
  required int concurrency,
  required TcpPortScanCancellation? cancellation,
  required void Function(int scannedPorts, int totalPorts)? onProgress,
}) => Future.error(UnsupportedError('本机 TCP 端口扫描在此平台不可用'));
