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
Host gateway
  HostName gateway.example.net
  User jump-user
  Port 2200
  IdentityFile ~/.ssh/gateway_ed25519
Host final
  HostName final.example.net
''');

        final node = result.hosts.firstWhere((host) => host.alias == 'node');
        final gateway = node.proxyJump!;
        final finalHost = result.hosts.firstWhere(
          (host) => host.alias == 'final',
        );
        expect(node.identityFile, '~/.ssh/node.example.net_deploy_2022');
        expect(gateway.alias, 'gateway');
        expect(gateway.hostName, 'gateway.example.net');
        expect(gateway.port, 2200);
        expect(gateway.username, 'jump-user');
        expect(gateway.identityFile, '~/.ssh/gateway_ed25519');
        expect(result.warnings, contains(contains('Include')));
        expect(result.warnings, isNot(contains(contains('ProxyJump'))));
        expect(result.warnings, contains(contains('Match')));
        expect(finalHost.hostName, 'final.example.net');
      },
    );

    test('does not import routes it cannot preserve safely', () {
      final result = parseOpenSshConfig('''
Host missing-route
  ProxyJump absent
Host multi-route
  ProxyJump first,second
Host command-route
  ProxyCommand ssh -W %h:%p proxy
Host gateway
  HostName gateway.example.net
''');

      expect(result.hosts.map((host) => host.alias), ['gateway']);
      expect(result.warnings, contains(contains('别名“absent”未定义')));
      expect(result.warnings, contains(contains('不是单个 Host 别名')));
      expect(result.warnings, contains(contains('ProxyCommand')));
    });

    test('imports ProxyJump none as a direct connection', () {
      final result = parseOpenSshConfig('''
Host direct
  ProxyJump none
Host *
  ProxyJump gateway
''');

      expect(result.hosts.single.alias, 'direct');
      expect(result.hosts.single.proxyJump, isNull);
      expect(result.warnings, isEmpty);
    });

    test('honors the first ProxyJump or ProxyCommand route directive', () {
      final result = parseOpenSshConfig('''
Host jump-first
  ProxyJump gateway
  ProxyCommand unsafe-command
Host command-first
  ProxyCommand unsafe-command
  ProxyJump gateway
Host gateway
''');

      expect(result.hosts.map((host) => host.alias), ['jump-first', 'gateway']);
      expect(result.hosts.first.proxyJump?.alias, 'gateway');
      expect(result.warnings, contains(contains('ProxyCommand')));
    });

    test('rejects self and nested ProxyJump routes', () {
      final result = parseOpenSshConfig('''
Host self
  ProxyJump self
Host outer
  ProxyJump middle
Host middle
  ProxyJump inner
Host inner
''');

      expect(result.hosts.map((host) => host.alias), ['middle', 'inner']);
      expect(result.warnings, contains(contains('指向自身')));
      expect(result.warnings, contains(contains('多层跳转暂不支持')));
    });

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
