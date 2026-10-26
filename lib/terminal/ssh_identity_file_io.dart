import 'dart:convert';
import 'dart:io';

Future<String> readSshIdentityFile(String configuredPath) async {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  var resolvedPath = configuredPath.trim();
  if (home != null &&
      (resolvedPath == '~' ||
          resolvedPath.startsWith('~/') ||
          resolvedPath.startsWith(r'~\'))) {
    final suffix = resolvedPath == '~' ? '' : resolvedPath.substring(2);
    resolvedPath = _join(home, suffix);
  } else if (home != null && !File(resolvedPath).isAbsolute) {
    resolvedPath = _join(home, resolvedPath);
  }

  final file = File(resolvedPath);
  if (!await file.exists()) {
    throw FileSystemException('IdentityFile 不存在', resolvedPath);
  }
  if (await file.length() > 1024 * 1024) {
    throw const FormatException('SSH 私钥文件不能大于 1 MiB');
  }
  final content = await file.readAsString(encoding: utf8);
  if (!content.contains('PRIVATE KEY')) {
    throw const FormatException('IdentityFile 中未找到受支持的私钥内容');
  }
  return content;
}

String _join(String directory, String path) {
  final normalizedPath = Platform.isWindows
      ? path.replaceAll('/', Platform.pathSeparator)
      : path;
  final relative = normalizedPath.replaceFirst(RegExp(r'^[\\/]'), '');
  if (directory.endsWith('/') || directory.endsWith(r'\')) {
    return '$directory$relative';
  }
  return '$directory${Platform.pathSeparator}$relative';
}
