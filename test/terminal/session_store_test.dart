import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:geekcore_term/terminal/session_store.dart';
import 'package:geekcore_term/terminal/remote_file_transfer.dart';
import 'package:geekcore_term/terminal/remote_transfer_queue.dart';
import 'package:geekcore_term/terminal/remote_transfer_queue_store.dart';
import 'package:geekcore_term/terminal/terminal_macro.dart';
import 'package:geekcore_term/terminal/terminal_input_recording.dart';

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

    test(
      'round-trips standalone SFTP profiles without duplicating SSH creds',
      () {
        final sftp = SessionRecord(
          id: 'sftp-storage',
          name: '文件服务器',
          protocol: SessionProtocol.sftp,
          address: 'files.example.net',
          port: 2222,
          username: 'deploy',
          sshConfigAlias: 'files',
          group: '存储',
          lastConnectedAt: DateTime.utc(2026, 10, 27),
        );
        final ssh = SessionRecord(
          id: 'ssh-storage',
          name: '终端服务器',
          protocol: SessionProtocol.ssh,
          address: sftp.address,
          port: sftp.port,
          username: sftp.username,
          sshConfigAlias: sftp.sshConfigAlias,
          lastConnectedAt: sftp.lastConnectedAt,
        );

        final decoded = SessionRecord.fromJson(jsonEncode(sftp.toJson()));
        expect(decoded.protocol, SessionProtocol.sftp);
        expect(decoded.address, sftp.address);
        expect(decoded.username, sftp.username);
        expect(decoded.group, '存储');
        expect(decoded.credentialKey, ssh.credentialKey);
        expect(decoded.endpointKey, isNot(ssh.endpointKey));
      },
    );

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

  test('TerminalMacro validates command lines and round-trips', () {
    final macro = TerminalMacro.fromScript(
      id: 'macro-inspect',
      name: '检查节点',
      script: '\r\n  hostname\r\nuptime\r\n',
    );

    expect(macro.commands, ['  hostname', 'uptime']);
    expect(TerminalMacro.fromJson(jsonEncode(macro.toJson())), macro);
    expect(
      () => TerminalMacro.fromScript(
        id: 'empty-line',
        name: '错误宏',
        script: 'hostname\n\nuptime',
      ),
      throwsFormatException,
    );
    expect(
      () => TerminalMacro.fromScript(
        id: 'control',
        name: '错误宏',
        script: 'hostname\u0000',
      ),
      throwsFormatException,
    );
    expect(
      () => TerminalMacro.fromScript(
        id: 'too-many',
        name: '错误宏',
        script: List.filled(TerminalMacro.maxCommands + 1, 'true').join('\n'),
      ),
      throwsFormatException,
    );
    expect(
      () => TerminalMacro.fromScript(
        id: 'too-large-utf8',
        name: '错误宏',
        script: "echo ${List.filled(6000, '中').join()}",
      ),
      throwsFormatException,
    );
  });

  test(
    'macro executor sends UTF-8 commands with Enter and stops between lines',
    () async {
      final macro = TerminalMacro.fromScript(
        id: 'macro-cn',
        name: '中文提示',
        script: 'printf 中文\nwhoami',
      );
      final sent = <String>[];

      await expectLater(
        executeTerminalMacroCommands(
          macro: macro,
          canContinue: (completed) => completed == 0,
          write: (input) async {
            sent.add(utf8.decode(input));
          },
        ),
        throwsA(
          isA<TerminalMacroStoppedException>().having(
            (error) => error.completedCommands,
            'completedCommands',
            1,
          ),
        ),
      );
      expect(sent, ['printf 中文\r']);
    },
  );

  test('SessionStore persists groups, snippets, and macros', () async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = null);
    final store = SessionStore();
    const snippet = CommandSnippet(
      id: 'snippet-disk',
      name: '检查磁盘',
      command: 'df -h && df -i',
    );
    final macro = TerminalMacro.fromScript(
      id: 'macro-health',
      name: '健康检查',
      script: 'hostname\nuptime\ndf -h /',
    );
    final recordedMacro = TerminalRecordedMacro(
      id: 'recorded-hostname',
      name: '录制 hostname',
      events: [
        TerminalRecordedInputEvent(bytes: utf8.encode('hostname'), delayMs: 0),
        TerminalRecordedInputEvent(bytes: [0x0D], delayMs: 75),
      ],
    );

    await store.saveGroups(const ['Production', 'Lab']);
    await store.saveCommandSnippets(const [snippet]);
    await store.saveTerminalMacros([macro]);
    await expectLater(
      store.saveRecordedMacros(
        List.filled(TerminalRecordedMacro.maxSavedMacros + 1, recordedMacro),
      ),
      throwsArgumentError,
    );
    await store.saveRecordedMacros([recordedMacro]);

    expect(await store.loadGroups(), ['Production', 'Lab']);
    expect(await store.loadCommandSnippets(), [snippet]);
    expect(await store.loadTerminalMacros(), [macro]);
    expect(await store.loadRecordedMacros(), [recordedMacro]);
    await store.clear();
    expect(await store.loadTerminalMacros(), isEmpty);
    expect(await store.loadRecordedMacros(), isEmpty);
  });

  test('SessionStore restores and clears the terminal split layout', () async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = null);
    final store = SessionStore();

    expect(await store.loadTerminalSplitMode(), TerminalSplitMode.none);
    await store.saveTerminalSplitMode(TerminalSplitMode.quad);
    expect(
      await SessionStore().loadTerminalSplitMode(),
      TerminalSplitMode.quad,
    );

    await store.clear();
    expect(await store.loadTerminalSplitMode(), TerminalSplitMode.none);
  });

  test(
    'clearing app session data also clears persisted transfer tasks',
    () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = null);
      final queueStore = RemoteTransferQueueStore();
      await queueStore.saveForSession('ssh:node', const [
        PersistedRemoteTransferTask(
          direction: RemoteTransferDirection.download,
          protocol: RemoteTransferProtocol.sftp,
          name: 'logs.tar',
          remotePath: '/var/logs.tar',
        ),
      ]);

      await SessionStore().clear();

      expect(await queueStore.loadForSession('ssh:node'), isEmpty);
    },
  );
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
