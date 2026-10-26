import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SshCredentialStorePlatform {
  static const _keyPrefix = 'geekcore_term.ssh.credentials.';
  final FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  Future<Map<String, Object?>?> read(String endpointKey) async {
    final value = await _secureStorage.read(key: '$_keyPrefix$endpointKey');
    if (value == null) return null;
    final decoded = jsonDecode(value);
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  Future<void> write(String endpointKey, Map<String, String> value) =>
      _secureStorage.write(
        key: '$_keyPrefix$endpointKey',
        value: jsonEncode(value),
      );

  Future<void> delete(String endpointKey) =>
      _secureStorage.delete(key: '$_keyPrefix$endpointKey');
}
