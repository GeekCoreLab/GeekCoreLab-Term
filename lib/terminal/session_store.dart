import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum SessionProtocol { serial, telnet }

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
  final DateTime lastConnectedAt;

  String get endpointKey => switch (protocol) {
    SessionProtocol.telnet =>
      '${protocol.name}:${address.trim().toLowerCase()}:$port',
    SessionProtocol.serial =>
      '${protocol.name}:${address.trim().toLowerCase()}:$port:$dataBits:$parity:$stopBits:$flowControl',
  };

  String get endpointLabel => switch (protocol) {
    SessionProtocol.serial => '$address · $port baud',
    SessionProtocol.telnet => '$address:$port',
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
      lastConnectedAt: DateTime.parse(value['lastConnectedAt'] as String),
    );
  }
}

class SessionStore {
  SessionStore() : _preferences = SharedPreferencesAsync();

  static const _savedKey = 'geekcore_term.saved_sessions.v1';
  static const _recentKey = 'geekcore_term.recent_sessions.v1';

  final SharedPreferencesAsync _preferences;

  Future<List<SessionRecord>> loadSaved() => _load(_savedKey);

  Future<List<SessionRecord>> loadRecent() => _load(_recentKey);

  Future<void> saveSaved(List<SessionRecord> records) =>
      _save(_savedKey, records);

  Future<void> saveRecent(List<SessionRecord> records) =>
      _save(_recentKey, records);

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
