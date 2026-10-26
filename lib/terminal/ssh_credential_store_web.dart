import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SshCredentialStorePlatform {
  static const _keyPrefix = 'geekcore_term.ssh.credentials.';
  final FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  Future<void> _writeQueue = Future<void>.value();

  Future<Map<String, Object?>?> read(String endpointKey) async {
    final value = await _secureStorage.read(key: '$_keyPrefix$endpointKey');
    if (value == null) return null;
    final decoded = jsonDecode(value);
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  Future<void> write(String endpointKey, Map<String, String> value) =>
      _enqueueWrite(
        () => _secureStorage.write(
          key: '$_keyPrefix$endpointKey',
          value: jsonEncode(value),
        ),
      );

  Future<void> delete(String endpointKey) => _enqueueWrite(
    () => _secureStorage.delete(key: '$_keyPrefix$endpointKey'),
  );

  Future<void> clearAll() => _enqueueWrite(() async {
    final values = await _secureStorage.readAll();
    for (final key in values.keys.where((key) => key.startsWith(_keyPrefix))) {
      await _secureStorage.delete(key: key);
    }
  });

  Future<void> _enqueueWrite(Future<void> Function() operation) {
    final queued = _writeQueue.then((_) => operation());
    _writeQueue = queued.catchError((Object _) {});
    return queued;
  }
}
