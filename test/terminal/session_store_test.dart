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
import 'package:geekcore_term/terminal/ssh_proxy_config.dart';

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

    test('round-trips proxy routing without serializing proxy passwords', () {
      const proxy = SshProxyConfig(
        type: SshProxyType.socks5,
        address: 'proxy.example.net',
        port: 1080,
        username: 'operator',
      );
      final original = SessionRecord(
        id: 'ssh-proxy',
        name: '代理会话',
        protocol: SessionProtocol.ssh,
        address: 'node.example.net',
        port: 22,
        sshProxy: proxy,
        lastConnectedAt: DateTime.utc(2026, 10, 27),
      );
      final encoded = jsonEncode(original.toJson());
      final decoded = SessionRecord.fromJson(encoded);

      expect(decoded.sshProxy, proxy);
      expect(encoded, isNot(contains('password')));
      expect(decoded.endpointKey, contains('proxy:'));
      expect(() => SshJumpHost.fromSession(decoded), throwsArgumentError);
    });

    test(
      'rejects invalid combinations of proxy, jump host, and port knocks',
      () {
        final base = SessionRecord(
          id: 'ssh-proxy',
          name: '代理会话',
          protocol: SessionProtocol.ssh,
          address: 'node.example.net',
          port: 22,
          sshProxy: const SshProxyConfig(
            type: SshProxyType.httpConnect,
            address: 'proxy.example.net',
            port: 8080,
          ),
          lastConnectedAt: DateTime.utc(2026, 10, 27),
        );
        final withKnock = base.toJson()
          ..['portKnockActions'] = [const PortKnockAction.knock(22).toJson()];
        expect(
          () => SessionRecord.fromJson(jsonEncode(withKnock)),
          throwsFormatException,
        );
      },
    );

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

      expect(direct.endpointKey, 'ssh:10.0.0.5:22::target:jump:');
      expect(routed.endpointKey, isNot(direct.endpointKey));
      expect(
        direct
            .copyWith(
              sshProxy: const SshProxyConfig(
                type: SshProxyType.socks5,
                address: 'proxy.example.net',
                port: 1080,
              ),
            )
            .endpointKey,
        isNot(direct.endpointKey),
      );
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
        script: 'hostname\n\n# 忽略注释和空行\nuptime',
      ),
      returnsNormally,
    );
    expect(
      TerminalMacro.fromScript(
        id: 'comments',
        name: '兼容空行',
        script: 'hostname\n\n# 注释\nuptime',
      ).commands,
      ['hostname', 'uptime'],
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
    'TerminalMacro expands parameters, exact conditions, and bounded loops',
    () {
      final macro = TerminalMacro.fromScript(
        id: 'script-branch-loop',
        name: '条件巡检',
        script: r'''
@param ENV=prod
@secret TOKEN

@if ENV == prod
@repeat 2 as INDEX
echo ${ENV}-${INDEX}-${TOKEN}
@end
@else
echo skipped
@endif
''',
      );

      final production = macro.prepare({'TOKEN': 'secret-value'});
      expect(production.commands, [
        'echo prod-1-secret-value',
        'echo prod-2-secret-value',
      ]);
      expect(production.reviewCommands, [
        'echo prod-1-<已遮蔽变量:TOKEN>',
        'echo prod-2-<已遮蔽变量:TOKEN>',
      ]);
      expect(production.usesSecret, isTrue);

      final staging = macro.prepare({
        'ENV': 'staging',
        'TOKEN': 'secret-value',
      });
      expect(staging.commands, ['echo skipped']);
      expect(staging.usesSecret, isFalse);
      expect(TerminalMacro.fromJson(jsonEncode(macro.toJson())), macro);
      expect(jsonEncode(macro.toJson()), isNot(contains('secret-value')));
    },
  );

  test('TerminalMacro rejects unsafe or unbounded script expansions', () {
    expect(
      () => TerminalMacro.fromScript(
        id: 'unknown-variable',
        name: '错误变量',
        script: r'echo ${MISSING}',
      ),
      throwsFormatException,
    );
    expect(
      () => TerminalMacro.fromScript(
        id: 'unclosed-condition',
        name: '未闭合条件',
        script: '@param ENV=prod\n@if ENV == prod\necho ok',
      ),
      throwsFormatException,
    );
    expect(
      () => TerminalMacro.fromScript(
        id: 'too-many-expanded',
        name: '展开超限',
        script: '@repeat 20 as INDEX\na\nb\nc\n@end',
      ),
      throwsFormatException,
    );
    final parameterized = TerminalMacro.fromScript(
      id: 'bad-value',
      name: '控制字符',
      script: r'''
@param VALUE
echo ${VALUE}
''',
    );
    expect(
      () => parameterized.prepare({'VALUE': 'line one\nline two'}),
      throwsFormatException,
    );
    expect(
      () => TerminalMacro.fromScript(
        id: 'secret-default',
        name: '秘密默认值',
        script: r'''
@secret TOKEN=unsafe
echo ${TOKEN}
''',
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

  test('macro executor sends the reviewed expanded plan', () async {
    final macro = TerminalMacro.fromScript(
      id: 'expanded-plan',
      name: '远端巡检',
      script: r'''
@param HOST=qa
@repeat 2 as INDEX
echo ${HOST} ${INDEX}
@end
''',
    );
    final plan = macro.prepare(const {});
    final sent = <String>[];

    final completed = await executeTerminalMacroCommands(
      macro: macro,
      commands: plan.commands,
      canContinue: (_) => true,
      write: (input) async => sent.add(utf8.decode(input)),
    );

    expect(completed, 2);
    expect(sent, ['echo qa 1\r', 'echo qa 2\r']);
  });

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
