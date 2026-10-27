import 'dart:async';
import 'dart:io';

import 'network_diagnostics_models.dart';

Future<List<String>> lookupNetworkHost(
  String host, {
  required Duration timeout,
}) async {
  final addresses = await InternetAddress.lookup(host).timeout(timeout);
  return addresses.map((address) => address.address).toSet().toList();
}

Future<TcpProbeResult> probeTcpPort(
  String host,
  int port, {
  required Duration timeout,
}) => _probeTcpPort(host, port, timeout);

Future<TcpProbeResult> _probeTcpPort(
  Object host,
  int port,
  Duration timeout,
) async {
  final stopwatch = Stopwatch()..start();
  final socket = await Socket.connect(host, port, timeout: timeout);
  stopwatch.stop();
  final result = TcpProbeResult(
    address: socket.remoteAddress.address,
    elapsed: stopwatch.elapsed,
  );
  socket.destroy();
  return result;
}

Future<TcpPortScanResult> scanTcpPorts(
  String host, {
  required int startPort,
  required int endPort,
  required Duration timeout,
  required int concurrency,
  required TcpPortScanCancellation? cancellation,
  required void Function(int scannedPorts, int totalPorts)? onProgress,
}) async {
  final stopwatch = Stopwatch()..start();
  final totalPorts = endPort - startPort + 1;
  if (cancellation?.isRequested == true) {
    return TcpPortScanResult(
      targetAddress: host,
      startPort: startPort,
      endPort: endPort,
      scannedPorts: 0,
      openPorts: const [],
      elapsed: stopwatch.elapsed,
      cancelled: true,
    );
  }

  final addresses = await InternetAddress.lookup(host).timeout(timeout);
  if (addresses.isEmpty) {
    throw SocketException('主机没有可用 IP 地址');
  }
  final targetAddress = addresses.first;
  final openPorts = <int>[];
  var nextOffset = 0;
  var scannedPorts = 0;

  Future<void> worker() async {
    while (cancellation?.isRequested != true) {
      final offset = nextOffset++;
      if (offset >= totalPorts) return;
      final port = startPort + offset;
      try {
        await _probeTcpPort(targetAddress, port, timeout);
        openPorts.add(port);
      } on SocketException {
        // Refused, unreachable, and filtered ports are not reported as open.
      } on TimeoutException {
        // A timed-out connection is not reported as an open service.
      }
      scannedPorts++;
      onProgress?.call(scannedPorts, totalPorts);
    }
  }

  await Future.wait(List.generate(concurrency, (_) => worker()));
  stopwatch.stop();
  openPorts.sort();
  return TcpPortScanResult(
    targetAddress: targetAddress.address,
    startPort: startPort,
    endPort: endPort,
    scannedPorts: scannedPorts,
    openPorts: openPorts,
    elapsed: stopwatch.elapsed,
    cancelled: cancellation?.isRequested == true,
  );
}
