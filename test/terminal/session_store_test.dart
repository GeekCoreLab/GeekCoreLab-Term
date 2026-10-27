import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:geekcore_term/terminal/session_store.dart';

void main() {
  group('SessionRecord', () {
    test('round-trips SSH metadata and ordered port-knock actions', () {
      final original = SessionRecord(
        id: 'ssh-node',
        name: '生产节点',
        protocol: SessionProtocol.ssh,
        address: 'node.example.net',
        port: 2222,
        username: 'deploy',
        identityFile: '~/.ssh/prod_ed25519',
        sshConfigAlias: 'prod',
        jumpHost: const SshJumpHost(
          name: '运维堡垒机',
          address: 'bastion.example.net',
          port: 2200,
          username: 'ops',
          identityFile: '~/.ssh/bastion_ed25519',
        ),
        group: '生产环境',
        authenticationMode: SshAuthenticationMode.keyFirst,
        portKnockActions: const [
          PortKnockAction.knock(3128),
          PortKnockAction.knock(0, protocol: PortKnockProtocol.icmp),
          PortKnockAction.delay(150),
        ],
        lastConnectedAt: DateTime.utc(2026, 10, 26, 12),
      );

      final decoded = SessionRecord.fromJson(jsonEncode(original.toJson()));
      expect(decoded.id, original.id);
      expect(decoded.name, original.name);
      expect(decoded.port, original.port);
      expect(decoded.username, original.username);
      expect(decoded.identityFile, original.identityFile);
      expect(decoded.sshConfigAlias, original.sshConfigAlias);
      expect(decoded.jumpHost?.name, '运维堡垒机');
      expect(decoded.jumpHost?.address, 'bastion.example.net');
      expect(decoded.jumpHost?.identityFile, '~/.ssh/bastion_ed25519');
      expect(decoded.group, original.group);
      expect(decoded.authenticationMode, SshAuthenticationMode.keyFirst);
      expect(decoded.portKnockActions, original.portKnockActions);
      expect(decoded.lastConnectedAt, original.lastConnectedAt);
    });

    test('round-trips serial framing options', () {
      final original = SessionRecord(
        id: 'serial-1',
        name: 'Console',
        protocol: SessionProtocol.serial,
        address: '/dev/ttyUSB0',
        port: 57600,
        dataBits: 7,
        parity: 'even',
        stopBits: 2,
        flowControl: 'hardware',
        lastConnectedAt: DateTime.utc(2026, 10, 26),
      );

      final decoded = SessionRecord.fromJson(jsonEncode(original.toJson()));
      expect(decoded.port, 57600);
      expect(decoded.dataBits, 7);
      expect(decoded.parity, 'even');
      expect(decoded.stopBits, 2);
      expect(decoded.flowControl, 'hardware');
    });

    test('loads records written before optional SSH metadata existed', () {
      final oldJson = jsonEncode({
        'id': 'old',
        'name': '旧 SSH',
        'protocol': 'ssh',
        'address': 'legacy.example.net',
        'port': 22,
        'lastConnectedAt': '2026-01-01T00:00:00.000Z',
      });

      final record = SessionRecord.fromJson(oldJson);
      expect(record.identityFile, isNull);
      expect(record.sshConfigAlias, isNull);
      expect(record.jumpHost, isNull);
      expect(record.authenticationMode, SshAuthenticationMode.automatic);
      expect(record.portKnockActions, isEmpty);
    });

    test('credential identity distinguishes SSH config aliases', () {
      final first = _sshRecord(alias: 'prod-a', host: '10.0.0.1');
      final second = _sshRecord(alias: 'prod-b', host: '10.0.0.1');

      expect(first.credentialKey, isNot(second.credentialKey));
      expect(first.endpointKey, isNot(second.endpointKey));
    });

    test('session identity distinguishes direct and jump-host routes', () {
      final direct = _sshRecord(alias: 'target', host: '10.0.0.5');
      final routed = SessionRecord(
        id: 'target-through-bastion',
        name: 'Target through bastion',
        protocol: SessionProtocol.ssh,
        address: '10.0.0.5',
        port: 22,
        jumpHost: const SshJumpHost(
          name: 'Bastion',
          address: '10.0.0.1',
          port: 22,
        ),
        lastConnectedAt: DateTime.utc(2026, 10, 26),
      );

      expect(routed.endpointKey, isNot(direct.endpointKey));
    });
  });

  test('CommandSnippet preserves a one-line command', () {
    const original = CommandSnippet(
      id: 'snippet-disk',
      name: '检查磁盘',
      command: 'df -h && df -i',
    );

    final decoded = CommandSnippet.fromJson(jsonEncode(original.toJson()));

    expect(decoded.id, original.id);
    expect(decoded.name, original.name);
    expect(decoded.command, original.command);
  });

  test('SessionStore persists groups and command snippets', () async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = null);
    final store = SessionStore();
    const snippet = CommandSnippet(
      id: 'snippet-disk',
      name: '检查磁盘',
      command: 'df -h && df -i',
    );

    await store.saveGroups(const ['Production', 'Lab']);
    await store.saveCommandSnippets(const [snippet]);

    expect(await store.loadGroups(), ['Production', 'Lab']);
    expect(await store.loadCommandSnippets(), [snippet]);
  });
}

SessionRecord _sshRecord({required String alias, required String host}) =>
    SessionRecord(
      id: alias,
      name: alias,
      protocol: SessionProtocol.ssh,
      address: host,
      port: 22,
      sshConfigAlias: alias,
      lastConnectedAt: DateTime.utc(2026),
    );
