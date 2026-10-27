import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/ssh_tunnel.dart';

void main() {
  group('SshTunnelSpec', () {
    test('accepts ephemeral local and dynamic ports', () {
      const local = SshTunnelSpec(
        type: SshTunnelType.local,
        bindPort: 0,
        targetHost: '127.0.0.1',
        targetPort: 8080,
      );
      const dynamic = SshTunnelSpec(type: SshTunnelType.dynamic, bindPort: 0);

      expect(local.validate, returnsNormally);
      expect(dynamic.validate, returnsNormally);
    });

    test('rejects invalid bind and destination ports', () {
      const invalidBind = SshTunnelSpec(
        type: SshTunnelType.dynamic,
        bindPort: 65536,
      );
      const missingTarget = SshTunnelSpec(
        type: SshTunnelType.local,
        bindPort: 2200,
        targetHost: ' ',
        targetPort: 22,
      );
      const invalidTargetPort = SshTunnelSpec(
        type: SshTunnelType.remote,
        bindPort: 2200,
        targetHost: 'localhost',
        targetPort: 0,
      );

      expect(invalidBind.validate, throwsFormatException);
      expect(missingTarget.validate, throwsFormatException);
      expect(invalidTargetPort.validate, throwsFormatException);
    });
  });
}
