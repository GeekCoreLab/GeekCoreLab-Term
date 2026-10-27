class TcpProbeResult {
  const TcpProbeResult({required this.address, required this.elapsed});

  final String address;
  final Duration elapsed;
}

class TcpPortScanCancellation {
  bool _requested = false;

  bool get isRequested => _requested;

  void cancel() => _requested = true;
}

class TcpPortScanResult {
  TcpPortScanResult({
    required this.targetAddress,
    required this.startPort,
    required this.endPort,
    required this.scannedPorts,
    required List<int> openPorts,
    required this.elapsed,
    required this.cancelled,
  }) : openPorts = List<int>.unmodifiable(openPorts);

  final int startPort;
  final int endPort;
  final String targetAddress;
  final int scannedPorts;
  final List<int> openPorts;
  final Duration elapsed;
  final bool cancelled;

  int get totalPorts => endPort - startPort + 1;
}
