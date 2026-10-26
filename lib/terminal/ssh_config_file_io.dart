import 'dart:convert';
import 'dart:io';

import 'ssh_config_file_data.dart';

Future<SshConfigFileData?> readDefaultSshConfig() async {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.trim().isEmpty) return null;
  final config = File(
    '$home${Platform.pathSeparator}.ssh${Platform.pathSeparator}config',
  );
  if (!await config.exists()) return null;
  if (await config.length() > 2 * 1024 * 1024) {
    throw const FormatException('SSH 配置文件不能大于 2 MiB');
  }
  return SshConfigFileData(
    path: config.path,
    content: await config.readAsString(encoding: utf8),
  );
}
