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
}) async {
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
