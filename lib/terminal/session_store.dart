import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'remote_transfer_queue_store.dart';
import 'terminal_macro.dart';

enum SessionProtocol { serial, telnet, ssh }

enum TerminalSplitMode {
  none,
  vertical,
  horizontal,
  quad;

  int get capacity => switch (this) {
    TerminalSplitMode.none => 1,
    TerminalSplitMode.vertical || TerminalSplitMode.horizontal => 2,
    TerminalSplitMode.quad => 4,
  };

  static TerminalSplitMode fromName(String? name) =>
      values.where((mode) => mode.name == name).firstOrNull ?? none;
}

enum SshAuthenticationMode { automatic, passwordFirst, keyFirst }

enum PortKnockProtocol { tcp, udp, icmp }

enum PortKnockActionKind { knock, delay }

class PortKnockAction {
  const PortKnockAction.knock(
    this.port, {
    this.protocol = PortKnockProtocol.tcp,
  }) : kind = PortKnockActionKind.knock,
       delayMs = 0;

  const PortKnockAction.delay(this.delayMs)
    : kind = PortKnockActionKind.delay,
      port = 0,
      protocol = PortKnockProtocol.tcp;

  final PortKnockActionKind kind;
  final int port;
  final int delayMs;
  final PortKnockProtocol protocol;

  Map<String, Object> toJson() => {
    'kind': kind.name,
    if (kind == PortKnockActionKind.knock) ...{
      'protocol': protocol.name,
      if (protocol != PortKnockProtocol.icmp) 'port': port,
    },
    if (kind == PortKnockActionKind.delay) 'delayMs': delayMs,
  };

  factory PortKnockAction.fromJson(Object? encoded) {
    if (encoded is! Map<String, dynamic>) {
      throw const FormatException('端口敲门操作格式无效');
    }
    final kind = PortKnockActionKind.values.firstWhere(
      (item) => item.name == encoded['kind'],
    );
    final protocol = PortKnockProtocol.values.firstWhere(
      (item) => item.name == encoded['protocol'],
      orElse: () => PortKnockProtocol.tcp,
    );
    return switch (kind) {
      PortKnockActionKind.knock => PortKnockAction.knock(
        protocol == PortKnockProtocol.icmp ? 0 : encoded['port'] as int,
        protocol: protocol,
      ),
      PortKnockActionKind.delay => PortKnockAction.delay(
        encoded['delayMs'] as int,
      ),
    };
  }

  @override
  bool operator ==(Object other) =>
      other is PortKnockAction &&
      other.kind == kind &&
      other.port == port &&
      other.delayMs == delayMs &&
      other.protocol == protocol;

  @override
  int get hashCode => Object.hash(kind, port, delayMs, protocol);
}

class SshJumpHost {
  const SshJumpHost({
    required this.name,
    required this.address,
    required this.port,
    this.webSocketUrl = '',
    this.portKnockActions = const [],
    this.authenticationMode = SshAuthenticationMode.automatic,
    this.username = '',
    this.identityFile,
    this.sshConfigAlias,
  });

  final String name;
  final String address;
  final int port;
  final String webSocketUrl;
  final List<PortKnockAction> portKnockActions;
  final SshAuthenticationMode authenticationMode;
  final String username;
  final String? identityFile;
  final String? sshConfigAlias;

  String get endpointKey =>
      '${address.trim().toLowerCase()}:$port:$webSocketUrl:${sshConfigAlias?.toLowerCase() ?? ''}';

  String get credentialKey =>
      'ssh:${address.trim().toLowerCase()}:$port${sshConfigAlias == null ? '' : ':config:${sshConfigAlias!.toLowerCase()}'}';

  Map<String, Object> toJson() => {
    'name': name,
    'address': address,
    'port': port,
    if (webSocketUrl.isNotEmpty) 'webSocketUrl': webSocketUrl,
    'portKnockActions': portKnockActions
        .map((action) => action.toJson())
        .toList(),
    'authenticationMode': authenticationMode.name,
    if (username.isNotEmpty) 'username': username,
    'identityFile': ?identityFile,
    'sshConfigAlias': ?sshConfigAlias,
  };

  factory SshJumpHost.fromJson(Object? encoded) {
    if (encoded is! Map<String, dynamic>) {
      throw const FormatException('SSH 跳板机配置格式无效');
    }
    final address = encoded['address'];
    final port = encoded['port'];
    if (address is! String || address.trim().isEmpty || port is! int) {
      throw const FormatException('SSH 跳板机地址或端口无效');
    }
    if (port < 1 || port > 65535) {
      throw const FormatException('SSH 跳板机端口超出范围');
    }
    return SshJumpHost(
      name: encoded['name'] as String? ?? address,
      address: address,
      port: port,
      webSocketUrl: encoded['webSocketUrl'] as String? ?? '',
      portKnockActions:
          (encoded['portKnockActions'] as List<Object?>? ?? const [])
              .map(PortKnockAction.fromJson)
              .toList(),
      authenticationMode: SshAuthenticationMode.values.firstWhere(
        (item) => item.name == encoded['authenticationMode'],
        orElse: () => SshAuthenticationMode.automatic,
      ),
      username: encoded['username'] as String? ?? '',
      identityFile: encoded['identityFile'] as String?,
      sshConfigAlias: encoded['sshConfigAlias'] as String?,
    );
  }

  factory SshJumpHost.fromSession(SessionRecord record) {
    if (record.protocol != SessionProtocol.ssh) {
      throw ArgumentError.value(record.protocol, 'record', '必须是 SSH 会话');
    }
    if (record.jumpHost != null) {
      throw ArgumentError.value(record.name, 'record', '不支持多层 SSH 跳转');
    }
    if (record.address.trim().isEmpty ||
        record.port < 1 ||
        record.port > 65535) {
      throw ArgumentError.value(record.address, 'record', 'SSH 主机地址或端口无效');
    }
    return SshJumpHost(
      name: record.name,
      address: record.address,
      port: record.port,
      webSocketUrl: record.webSocketUrl,
      portKnockActions: record.portKnockActions,
      authenticationMode: record.authenticationMode,
      username: record.username,
      identityFile: record.identityFile,
      sshConfigAlias: record.sshConfigAlias,
    );
  }
}

class SessionRecord {
  const SessionRecord({
    required this.id,
    required this.name,
    required this.protocol,
    required this.address,
    required this.port,
    this.dataBits = 8,
    this.parity = 'none',
    this.stopBits = 1,
    this.flowControl = 'none',
    this.webSocketUrl = '',
    this.portKnockActions = const [],
    this.authenticationMode = SshAuthenticationMode.automatic,
    this.username = '',
    this.identityFile,
    this.sshConfigAlias,
    this.jumpHost,
    this.group = '',
    required this.lastConnectedAt,
  });

  final String id;
  final String name;
  final SessionProtocol protocol;
  final String address;
  // Serial sessions use this for baud rate; Telnet sessions use TCP port.
  final int port;
  final int dataBits;
  final String parity;
  final int stopBits;
  final String flowControl;
  final String webSocketUrl;
  final List<PortKnockAction> portKnockActions;
  final SshAuthenticationMode authenticationMode;
  final String username;
  final String? identityFile;
  final String? sshConfigAlias;
  final SshJumpHost? jumpHost;
  final String group;
  final DateTime lastConnectedAt;

  String get endpointKey => switch (protocol) {
    SessionProtocol.telnet =>
      '${protocol.name}:${address.trim().toLowerCase()}:$port',
    SessionProtocol.serial =>
      '${protocol.name}:${address.trim().toLowerCase()}:$port:$dataBits:$parity:$stopBits:$flowControl',
    SessionProtocol.ssh =>
      '${protocol.name}:${address.trim().toLowerCase()}:$port:$webSocketUrl:${sshConfigAlias?.toLowerCase() ?? ''}:jump:${jumpHost?.endpointKey ?? ''}',
  };

  String get endpointLabel => switch (protocol) {
    SessionProtocol.serial => '$address · $port baud',
    SessionProtocol.telnet => '$address:$port',
    SessionProtocol.ssh =>
      jumpHost == null
          ? '$address:$port'
          : '$address:$port · 经 ${jumpHost!.name}',
  };

  String get credentialKey => protocol == SessionProtocol.ssh
      ? 'ssh:${address.trim().toLowerCase()}:$port${sshConfigAlias == null ? '' : ':config:${sshConfigAlias!.toLowerCase()}'}'
      : endpointKey;

  SessionRecord copyWith({
    String? id,
    String? name,
    String? group,
    DateTime? lastConnectedAt,
    SshJumpHost? jumpHost,
  }) => SessionRecord(
    id: id ?? this.id,
    name: name ?? this.name,
    protocol: protocol,
    address: address,
    port: port,
    dataBits: dataBits,
    parity: parity,
    stopBits: stopBits,
    flowControl: flowControl,
    webSocketUrl: webSocketUrl,
    portKnockActions: portKnockActions,
    authenticationMode: authenticationMode,
    username: username,
    identityFile: identityFile,
    sshConfigAlias: sshConfigAlias,
    jumpHost: jumpHost ?? this.jumpHost,
    group: group ?? this.group,
    lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'protocol': protocol.name,
    'address': address,
    'port': port,
    'dataBits': dataBits,
    'parity': parity,
    'stopBits': stopBits,
    'flowControl': flowControl,
    'webSocketUrl': webSocketUrl,
    'portKnockActions': portKnockActions
        .map((action) => action.toJson())
        .toList(),
    'authenticationMode': authenticationMode.name,
    if (username.isNotEmpty) 'username': username,
    'identityFile': ?identityFile,
    'sshConfigAlias': ?sshConfigAlias,
    if (jumpHost != null) 'jumpHost': jumpHost!.toJson(),
    if (group.isNotEmpty) 'group': group,
    'lastConnectedAt': lastConnectedAt.toIso8601String(),
  };

  factory SessionRecord.fromJson(String encoded) {
    final value = jsonDecode(encoded);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('会话记录格式无效');
    }
    final protocol = SessionProtocol.values.firstWhere(
      (item) => item.name == value['protocol'],
    );
    return SessionRecord(
      id: value['id'] as String,
      name: value['name'] as String,
      protocol: protocol,
      address: value['address'] as String,
      port: value['port'] as int,
      dataBits: value['dataBits'] as int? ?? 8,
      parity: value['parity'] as String? ?? 'none',
      stopBits: value['stopBits'] as int? ?? 1,
      flowControl: value['flowControl'] as String? ?? 'none',
      webSocketUrl: value['webSocketUrl'] as String? ?? '',
      portKnockActions:
          (value['portKnockActions'] as List<Object?>? ?? const [])
              .map(PortKnockAction.fromJson)
              .toList(),
      authenticationMode: SshAuthenticationMode.values.firstWhere(
        (item) => item.name == value['authenticationMode'],
        orElse: () => SshAuthenticationMode.automatic,
      ),
      username: value['username'] as String? ?? '',
      identityFile: value['identityFile'] as String?,
      sshConfigAlias: value['sshConfigAlias'] as String?,
      jumpHost: value['jumpHost'] == null
          ? null
          : SshJumpHost.fromJson(value['jumpHost']),
      group: value['group'] as String? ?? '',
      lastConnectedAt: DateTime.parse(value['lastConnectedAt'] as String),
    );
  }
}

class CommandSnippet {
  const CommandSnippet({
    required this.id,
    required this.name,
    required this.command,
  });

  final String id;
  final String name;
  final String command;

  Map<String, Object> toJson() => {'id': id, 'name': name, 'command': command};

  factory CommandSnippet.fromJson(String encoded) {
    final value = jsonDecode(encoded);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('命令片段格式无效');
    }
    final id = value['id'];
    final name = value['name'];
    final command = value['command'];
    if (id is! String ||
        name is! String ||
        name.trim().isEmpty ||
        command is! String ||
        command.trim().isEmpty ||
        command.contains('\n') ||
        command.contains('\r')) {
      throw const FormatException('命令片段需要名称和单行命令');
    }
    return CommandSnippet(id: id, name: name, command: command);
  }

  @override
  bool operator ==(Object other) =>
      other is CommandSnippet &&
      other.id == id &&
      other.name == name &&
      other.command == command;

  @override
  int get hashCode => Object.hash(id, name, command);
}

class SessionStore {
  SessionStore() : _preferences = SharedPreferencesAsync();

  static const _savedKey = 'geekcore_term.saved_sessions.v1';
  static const _recentKey = 'geekcore_term.recent_sessions.v1';
  static const _groupsKey = 'geekcore_term.session_groups.v1';
  static const _snippetsKey = 'geekcore_term.command_snippets.v1';
  static const _macrosKey = 'geekcore_term.command_macros.v1';
  static const _sshHostKeysKey = 'geekcore_term.ssh_host_keys.v1';
  static const _terminalSplitModeKey = 'geekcore_term.terminal_split_mode.v1';

  final SharedPreferencesAsync _preferences;
  Future<void> _writeQueue = Future<void>.value();

  Future<List<SessionRecord>> loadSaved() => _load(_savedKey);

  Future<List<SessionRecord>> loadRecent() => _load(_recentKey);

  Future<List<String>> loadGroups() async =>
      await _preferences.getStringList(_groupsKey) ?? const [];

  Future<TerminalSplitMode> loadTerminalSplitMode() async =>
      TerminalSplitMode.fromName(
        await _preferences.getString(_terminalSplitModeKey),
      );

  Future<List<CommandSnippet>> loadCommandSnippets() async {
    final encodedSnippets =
        await _preferences.getStringList(_snippetsKey) ?? const [];
    final snippets = <CommandSnippet>[];
    for (final encoded in encodedSnippets) {
      try {
        snippets.add(CommandSnippet.fromJson(encoded));
      } on Object {
        // Ignore a malformed snippet without losing the remaining library.
      }
    }
    return snippets;
  }

  Future<List<TerminalMacro>> loadTerminalMacros() async {
    final encodedMacros =
        await _preferences.getStringList(_macrosKey) ?? const [];
    final macros = <TerminalMacro>[];
    for (final encoded in encodedMacros) {
      try {
        macros.add(TerminalMacro.fromJson(encoded));
      } on Object {
        // Ignore a malformed macro without losing the remaining library.
      }
    }
    return macros;
  }

  Future<void> saveSaved(List<SessionRecord> records) =>
      _save(_savedKey, records);

  Future<void> saveRecent(List<SessionRecord> records) =>
      _save(_recentKey, records);

  Future<void> saveGroups(List<String> groups) =>
      _enqueueWrite(() => _preferences.setStringList(_groupsKey, groups));

  Future<void> saveTerminalSplitMode(TerminalSplitMode mode) => _enqueueWrite(
    () => _preferences.setString(_terminalSplitModeKey, mode.name),
  );

  Future<void> saveCommandSnippets(List<CommandSnippet> snippets) =>
      _enqueueWrite(
        () => _preferences.setStringList(
          _snippetsKey,
          snippets.map((snippet) => jsonEncode(snippet.toJson())).toList(),
        ),
      );

  Future<void> saveTerminalMacros(List<TerminalMacro> macros) => _enqueueWrite(
    () => _preferences.setStringList(
      _macrosKey,
      macros.map((macro) => jsonEncode(macro.toJson())).toList(),
    ),
  );

  Future<void> clear() => _enqueueWrite(() async {
    await _preferences.remove(_savedKey);
    await _preferences.remove(_recentKey);
    await _preferences.remove(_groupsKey);
    await _preferences.remove(_snippetsKey);
    await _preferences.remove(_macrosKey);
    await _preferences.remove(_sshHostKeysKey);
    await _preferences.remove(_terminalSplitModeKey);
    await _preferences.remove(RemoteTransferQueueStore.storageKey);
  });

  Future<String?> loadSshHostKey(String endpointKey) async {
    final encoded = await _preferences.getString(_sshHostKeysKey);
    if (encoded == null) return null;
    final decoded = jsonDecode(encoded);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('SSH 主机密钥记录格式无效');
    }
    return decoded[endpointKey] as String?;
  }

  Future<void> saveSshHostKey(String endpointKey, String fingerprint) =>
      _enqueueWrite(() async {
        final encoded = await _preferences.getString(_sshHostKeysKey);
        final Map<String, dynamic> values;
        if (encoded == null) {
          values = {};
        } else {
          final decoded = jsonDecode(encoded);
          if (decoded is! Map<String, dynamic>) {
            throw const FormatException('SSH 主机密钥记录格式无效');
          }
          values = decoded;
        }
        values[endpointKey] = fingerprint;
        await _preferences.setString(_sshHostKeysKey, jsonEncode(values));
      });

  Future<List<SessionRecord>> _load(String key) async {
    final encodedRecords = await _preferences.getStringList(key) ?? const [];
    final records = <SessionRecord>[];
    for (final encoded in encodedRecords) {
      try {
        records.add(SessionRecord.fromJson(encoded));
      } on Object {
        // Ignore a malformed record without losing the other saved sessions.
      }
    }
    return records;
  }

  Future<void> _save(String key, List<SessionRecord> records) => _enqueueWrite(
    () => _preferences.setStringList(
      key,
      records.map((record) => jsonEncode(record.toJson())).toList(),
    ),
  );

  Future<void> _enqueueWrite(Future<void> Function() operation) {
    final queued = _writeQueue.then((_) => operation());
    _writeQueue = queued.catchError((Object _) {});
    return queued;
  }
}
