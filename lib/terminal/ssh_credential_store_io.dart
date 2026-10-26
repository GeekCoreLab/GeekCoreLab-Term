import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

class SshCredentialStorePlatform {
  static const _secureKeyPrefix = 'geekcore_term.ssh.credentials.';
  final FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  Future<void> _writeQueue = Future<void>.value();

  Future<Map<String, Object?>?> read(String endpointKey) async {
    if (Platform.isAndroid) {
      final value = await _secureStorage.read(
        key: '$_secureKeyPrefix$endpointKey',
      );
      if (value == null) return null;
      final decoded = jsonDecode(value);
      return decoded is Map<String, dynamic> ? decoded : null;
    }

    final file = await _credentialsFile();
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('SSH 凭据文件格式无效');
    }
    final value = decoded[endpointKey];
    return value is Map<String, dynamic> ? value : null;
  }

  Future<void> write(String endpointKey, Map<String, String> value) {
    if (Platform.isAndroid) {
      return _secureStorage.write(
        key: '$_secureKeyPrefix$endpointKey',
        value: jsonEncode(value),
      );
    }

    final operation = _writeQueue.then(
      (_) => _writeDesktop(endpointKey, value),
    );
    _writeQueue = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> delete(String endpointKey) {
    if (Platform.isAndroid) {
      return _secureStorage.delete(key: '$_secureKeyPrefix$endpointKey');
    }

    final operation = _writeQueue.then((_) => _deleteDesktop(endpointKey));
    _writeQueue = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _deleteDesktop(String endpointKey) async {
    final file = await _credentialsFile();
    if (!await file.exists()) return;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('SSH 凭据文件格式无效');
    }
    if (decoded.remove(endpointKey) == null) return;
    final directory = file.parent;
    await _restrictDirectory(directory);
    final temporaryFile = File('${file.path}.tmp');
    try {
      await temporaryFile.writeAsString(jsonEncode(decoded), flush: true);
      await _restrictFile(temporaryFile);
      await temporaryFile.rename(file.path);
    } finally {
      if (await temporaryFile.exists()) await temporaryFile.delete();
    }
    await _restrictFile(file);
  }

  Future<void> _writeDesktop(
    String endpointKey,
    Map<String, String> value,
  ) async {
    final file = await _credentialsFile();
    final directory = file.parent;
    await directory.create(recursive: true);
    await _restrictDirectory(directory);

    Map<String, dynamic> records = {};
    if (await file.exists()) {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('SSH 凭据文件格式无效');
      }
      records = decoded;
    }
    records[endpointKey] = value;

    final temporaryFile = File('${file.path}.tmp');
    try {
      await temporaryFile.writeAsString(jsonEncode(records), flush: true);
      await _restrictFile(temporaryFile);
      await temporaryFile.rename(file.path);
    } finally {
      if (await temporaryFile.exists()) await temporaryFile.delete();
    }
    await _restrictFile(file);
  }

  Future<File> _credentialsFile() async {
    final directory = await getApplicationSupportDirectory();
    return File(
      '${directory.path}${Platform.pathSeparator}ssh'
      '${Platform.pathSeparator}credentials.json',
    );
  }

  Future<void> _restrictDirectory(Directory directory) async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final result = await Process.run('chmod', ['700', directory.path]);
    if (result.exitCode != 0) {
      throw FileSystemException('无法限制 SSH 凭据目录权限', directory.path);
    }
  }

  Future<void> _restrictFile(File file) async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final result = await Process.run('chmod', ['600', file.path]);
    if (result.exitCode != 0) {
      throw FileSystemException('无法限制 SSH 凭据文件权限', file.path);
    }
  }
}
