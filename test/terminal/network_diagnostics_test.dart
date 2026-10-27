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
}
