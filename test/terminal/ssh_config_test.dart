import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/ssh_config.dart';

void main() {
  group('parseOpenSshConfig', () {
    test('imports aliases and applies first matching values', () {
      final result = parseOpenSshConfig('''
User global-user
Host prod alias-prod
  HostName "prod.example.internal"
  Port 2202
  User ignored-by-first-match
  IdentityFile ~/.ssh/prod_ed25519
Host alias-prod
  Port 2203
''');

      expect(result.hosts, hasLength(2));
      final prod = result.hosts.firstWhere((host) => host.alias == 'prod');
      final alias = result.hosts.firstWhere(
        (host) => host.alias == 'alias-prod',
      );
      expect(prod.hostName, 'prod.example.internal');
      expect(prod.port, 2202);
      expect(prod.username, 'global-user');
      expect(prod.identityFile, '~/.ssh/prod_ed25519');
      expect(alias.port, 2202);
    });

    test('supports wildcard exclusions and quoted continued values', () {
      final result = parseOpenSshConfig(r'''
Host *.internal !blocked.internal
  User ops
  IdentityFile ~/.ssh/key\ with\ spaces
Host app.internal
  HostName %n.service.local
  Port 2222
Host blocked.internal
  HostName should-not-be-replaced.internal
''');

      final app = result.hosts.firstWhere(
        (host) => host.alias == 'app.internal',
      );
      final blocked = result.hosts.firstWhere(
        (host) => host.alias == 'blocked.internal',
      );
      expect(app.username, 'ops');
      expect(app.identityFile, '~/.ssh/key with spaces');
      expect(app.hostName, 'app.internal.service.local');
      expect(app.port, 2222);
      expect(blocked.username, isEmpty);
      expect(blocked.hostName, 'should-not-be-replaced.internal');
    });

    test(
      'expands supported identity tokens and reports unsupported directives',
      () {
        final result = parseOpenSshConfig('''
Host node
  HostName node.example.net
  User deploy
  Port 2022
  IdentityFile ~/.ssh/%h_%r_%p
  Include ~/.ssh/extra.conf
  ProxyJump gateway
  Match host other
  User ignored
Host final
  HostName final.example.net
''');

        final node = result.hosts.firstWhere((host) => host.alias == 'node');
        final finalHost = result.hosts.firstWhere(
          (host) => host.alias == 'final',
        );
        expect(node.identityFile, '~/.ssh/node.example.net_deploy_2022');
        expect(result.warnings, contains(contains('Include')));
        expect(result.warnings, contains(contains('ProxyJump')));
        expect(result.warnings, contains(contains('Match')));
        expect(finalHost.hostName, 'final.example.net');
      },
    );

    test('skips invalid ports and ignores comments outside quotes', () {
      final result = parseOpenSshConfig('''
Host bad
  Port 70000
Host good
  HostName "good#host.example" # trailing comment
''');

      expect(result.hosts.map((host) => host.alias), ['good']);
      expect(result.hosts.single.hostName, 'good#host.example');
      expect(result.warnings, contains(contains('端口无效')));
    });
  });
}
