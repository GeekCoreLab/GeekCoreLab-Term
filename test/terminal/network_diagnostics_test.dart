import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/network_diagnostics.dart';

void main() {
  group('network diagnostic validation', () {
    test('rejects empty or whitespace-containing host names', () {
      expect(() => lookupNetworkHost('  '), throwsFormatException);
      expect(() => probeTcpPort('bad host', 443), throwsFormatException);
    });

    test('rejects invalid TCP ports and timeouts', () {
      expect(() => probeTcpPort('localhost', 0), throwsFormatException);
      expect(() => probeTcpPort('localhost', 65536), throwsFormatException);
      expect(
        () => probeTcpPort(
          'localhost',
          443,
          timeout: const Duration(milliseconds: 500),
        ),
        throwsFormatException,
      );
    });

    test('bounds scan range, timeout, and concurrency', () {
      expect(
        () => scanTcpPorts('localhost', startPort: 0, endPort: 10),
        throwsFormatException,
      );
      expect(
        () => scanTcpPorts('localhost', startPort: 20, endPort: 10),
        throwsFormatException,
      );
      expect(
        () => scanTcpPorts('localhost', startPort: 65535, endPort: 65536),
        throwsFormatException,
      );
      expect(
        () => scanTcpPorts('localhost', startPort: 1, endPort: 1025),
        throwsFormatException,
      );
      expect(
        () => scanTcpPorts(
          'localhost',
          startPort: 1,
          endPort: 2,
          timeout: const Duration(milliseconds: 249),
        ),
        throwsFormatException,
      );
      expect(
        () => scanTcpPorts(
          'localhost',
          startPort: 1,
          endPort: 2,
          timeout: const Duration(seconds: 6),
        ),
        throwsFormatException,
      );
      expect(
        () =>
            scanTcpPorts('localhost', startPort: 1, endPort: 2, concurrency: 0),
        throwsFormatException,
      );
      expect(
        () => scanTcpPorts(
          'localhost',
          startPort: 1,
          endPort: 2,
          concurrency: maxTcpPortScanConcurrency + 1,
        ),
        throwsFormatException,
      );
    });
  });

  test('resolves localhost without requiring a remote service', () async {
    final addresses = await lookupNetworkHost('localhost');
    expect(addresses, isNotEmpty);
    expect(addresses, everyElement(isNotEmpty));
  });

  test(
    'TCP probe connects once and closes without sending a payload',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final acceptedSocket = server.first;

      final result = await probeTcpPort('127.0.0.1', server.port);
      final peer = await acceptedSocket;
      peer.destroy();

      expect(result.address, '127.0.0.1');
      expect(result.elapsed, greaterThanOrEqualTo(Duration.zero));
    },
  );

  test('scans one loopback port and reports its resolved target', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final acceptedSocket = server.first;

    final result = await scanTcpPorts(
      '127.0.0.1',
      startPort: server.port,
      endPort: server.port,
      timeout: const Duration(milliseconds: 500),
      concurrency: 1,
    );
    final peer = await acceptedSocket;
    peer.destroy();

    expect(result.targetAddress, '127.0.0.1');
    expect(result.scannedPorts, 1);
    expect(result.totalPorts, 1);
    expect(result.openPorts, [server.port]);
    expect(result.cancelled, isFalse);
  });

  test('cancellation stops scheduling additional ports', () async {
    final cancellation = TcpPortScanCancellation();
    final result = await scanTcpPorts(
      '127.0.0.1',
      startPort: 1,
      endPort: 1024,
      concurrency: 1,
      timeout: const Duration(milliseconds: 250),
      cancellation: cancellation,
      onProgress: (scanned, _) {
        if (scanned == 1) cancellation.cancel();
      },
    );

    expect(result.cancelled, isTrue);
    expect(result.scannedPorts, 1);
    expect(result.totalPorts, 1024);
  });

  test('cancelled scan does not resolve or connect to its host', () async {
    final cancellation = TcpPortScanCancellation()..cancel();
    final result = await scanTcpPorts(
      'not-a-resolvable-host.invalid',
      startPort: 1,
      endPort: 1,
      cancellation: cancellation,
    );

    expect(result.cancelled, isTrue);
    expect(result.scannedPorts, 0);
    expect(result.targetAddress, 'not-a-resolvable-host.invalid');
  });
}
