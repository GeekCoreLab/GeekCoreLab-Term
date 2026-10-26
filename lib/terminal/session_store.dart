import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum SessionProtocol { serial, telnet, ssh }

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
  final DateTime lastConnectedAt;

  String get endpointKey => switch (protocol) {
    SessionProtocol.telnet =>
      '${protocol.name}:${address.trim().toLowerCase()}:$port',
    SessionProtocol.serial =>
      '${protocol.name}:${address.trim().toLowerCase()}:$port:$dataBits:$parity:$stopBits:$flowControl',
    SessionProtocol.ssh =>
      '${protocol.name}:${address.trim().toLowerCase()}:$port:$webSocketUrl',
  };

  String get endpointLabel => switch (protocol) {
    SessionProtocol.serial => '$address · $port baud',
    SessionProtocol.telnet => '$address:$port',
    SessionProtocol.ssh => '$address:$port',
  };

  SessionRecord copyWith({String? name, DateTime? lastConnectedAt}) =>
      SessionRecord(
        id: id,
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
      lastConnectedAt: DateTime.parse(value['lastConnectedAt'] as String),
    );
  }
}

class SessionStore {
  SessionStore() : _preferences = SharedPreferencesAsync();

  static const _savedKey = 'geekcore_term.saved_sessions.v1';
  static const _recentKey = 'geekcore_term.recent_sessions.v1';
  static const _sshHostKeysKey = 'geekcore_term.ssh_host_keys.v1';

  final SharedPreferencesAsync _preferences;

  Future<List<SessionRecord>> loadSaved() => _load(_savedKey);

  Future<List<SessionRecord>> loadRecent() => _load(_recentKey);

  Future<void> saveSaved(List<SessionRecord> records) =>
      _save(_savedKey, records);

  Future<void> saveRecent(List<SessionRecord> records) =>
      _save(_recentKey, records);

  Future<String?> loadSshHostKey(String endpointKey) async {
    final encoded = await _preferences.getString(_sshHostKeysKey);
    if (encoded == null) return null;
    final decoded = jsonDecode(encoded);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('SSH 主机密钥记录格式无效');
    }
    return decoded[endpointKey] as String?;
  }

  Future<void> saveSshHostKey(String endpointKey, String fingerprint) async {
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
  }

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

  Future<void> _save(String key, List<SessionRecord> records) =>
      _preferences.setStringList(
        key,
        records.map((record) => jsonEncode(record.toJson())).toList(),
      );
}
