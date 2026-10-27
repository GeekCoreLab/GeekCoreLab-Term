import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:geekcore_term/terminal/local_file_system_models.dart';
import 'package:geekcore_term/terminal/remote_file_transfer.dart';

const bool localFileSystemSupported = true;

Future<String?> defaultLocalDirectory() async {
  final environment = Platform.environment;
  final home = environment['HOME'] ?? environment['USERPROFILE'];
  if (home != null && home.trim().isNotEmpty) {
    final directory = Directory(home);
    if (await directory.exists()) return directory.absolute.path;
  }
  final current = Directory.current;
  return await current.exists() ? current.absolute.path : null;
}

Future<List<LocalFileEntry>> listLocalDirectory(String path) async {
  final directory = Directory(path);
  if (!await directory.exists()) throw FileSystemException('目录不存在', path);
  final entries = <LocalFileEntry>[];
  await for (final entity in directory.list(followLinks: false)) {
    final name = localFileName(entity.path);
    if (name.isEmpty || name.startsWith('.geekcore-resume-')) continue;
    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      entries.add(
        LocalFileEntry(name: name, path: entity.path, isDirectory: true),
      );
    } else if (type == FileSystemEntityType.file) {
      final stat = await entity.stat();
      entries.add(
        LocalFileEntry(
          name: name,
          path: entity.path,
          isDirectory: false,
          size: stat.size,
          modified: stat.modified,
        ),
      );
    }
  }
  entries.sort((left, right) {
    final typeOrder = (right.isDirectory ? 1 : 0) - (left.isDirectory ? 1 : 0);
    if (typeOrder != 0) return typeOrder;
    return left.name.toLowerCase().compareTo(right.name.toLowerCase());
  });
  return entries;
}

Future<bool> localFileExists(String path) async =>
    await FileSystemEntity.type(path, followLinks: false) ==
    FileSystemEntityType.file;

String localParentDirectory(String path) {
  final directory = Directory(path).absolute;
  final parent = directory.parent.path;
  return parent == directory.path ? directory.path : parent;
}

String localJoinPath(String directory, String name) {
  validateLocalFileName(name);
  final separator = Platform.pathSeparator;
  return directory.endsWith(separator)
      ? '$directory$name'
      : '$directory$separator$name';
}

String localFileName(String path) {
  final normalized = path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
  if (normalized.isEmpty) return '';
  return normalized.substring(normalized.lastIndexOf('/') + 1);
}

Future<RemoteFileSource> localFileSource(String path) async {
  final type = await FileSystemEntity.type(path, followLinks: false);
  if (type != FileSystemEntityType.file) {
    throw FileSystemException('只能上传普通文件，不支持符号链接或目录', path);
  }
  final file = File(path);
  final stat = await file.stat();
  if (stat.type != FileSystemEntityType.file) {
    throw FileSystemException('只能上传普通文件', path);
  }
  validateLocalFileName(localFileName(path));
  return RemoteFileSource(
    name: localFileName(path),
    length: () async => file.length(),
    openRead: () => file.openRead().map(Uint8List.fromList),
    localPath: file.absolute.path,
    localLength: stat.size,
    localModifiedAtMillis: stat.modified.millisecondsSinceEpoch,
  );
}

Future<void> writeLocalFileAtomically(
  String path,
  Uint8List bytes, {
  required bool overwriteConfirmed,
}) async {
  final destination = File(path).absolute;
  final parent = destination.parent;
  if (!await parent.exists()) {
    throw FileSystemException('本地目标目录不存在', parent.path);
  }
  validateLocalFileName(localFileName(destination.path));

  final initialType = await FileSystemEntity.type(
    destination.path,
    followLinks: false,
  );
  if (initialType == FileSystemEntityType.link ||
      initialType == FileSystemEntityType.directory) {
    throw FileSystemException('目标必须是普通文件，拒绝跟随链接或覆盖目录', path);
  }
  if (initialType == FileSystemEntityType.file && !overwriteConfirmed) {
    throw FileSystemException('目标文件已存在，需要明确确认覆盖', path);
  }

  final initialStat = initialType == FileSystemEntityType.file
      ? await destination.stat()
      : null;
  final token = _transferToken();
  final temporary = File(
    '${parent.path}${Platform.pathSeparator}.geekcore-$token.tmp',
  );
  final backup = File(
    '${parent.path}${Platform.pathSeparator}.geekcore-$token.bak',
  );
  var temporaryCreated = false;
  var backupCreated = false;
  var committed = false;
  try {
    await temporary.create(exclusive: true);
    temporaryCreated = true;
    final output = await temporary.open(mode: FileMode.writeOnly);
    try {
      await output.writeFrom(bytes);
      await output.flush();
    } finally {
      await output.close();
    }

    final currentType = await FileSystemEntity.type(
      destination.path,
      followLinks: false,
    );
    if (initialType == FileSystemEntityType.notFound &&
        currentType != FileSystemEntityType.notFound) {
      throw FileSystemException('下载期间本地出现了同名项目，已保留原项目', path);
    }
    if (initialType == FileSystemEntityType.file) {
      if (currentType != FileSystemEntityType.file ||
          !_sameFileVersion(initialStat!, await destination.stat())) {
        throw FileSystemException('下载期间本地文件已变化，已保留新版本', path);
      }
      await destination.rename(backup.path);
      backupCreated = true;
    }

    try {
      await temporary.rename(destination.path);
      committed = true;
    } catch (error) {
      if (backupCreated) {
        try {
          await backup.rename(destination.path);
          backupCreated = false;
        } on Object catch (restoreError) {
          throw FileSystemException(
            '提交下载失败且原文件恢复失败；原文件保存在 ${backup.path}：$restoreError',
            path,
          );
        }
      }
      rethrow;
    }
    if (backupCreated) {
      await backup.delete();
      backupCreated = false;
    }
  } finally {
    if (temporaryCreated && !committed) {
      try {
        await temporary.delete();
      } on Object {
        // Preserve the original error. A leftover uniquely named temp file is recoverable.
      }
    }
  }
}

Future<void> writeResumableLocalDownload({
  required String path,
  required String transferIdentity,
  required String sourceVersion,
  required int expectedLength,
  required Stream<Uint8List> Function(int offset) openRead,
  required bool overwriteConfirmed,
  required Future<void> Function() validateSource,
  void Function()? beforeCommit,
  void Function(int bytesReceived)? onProgress,
}) async {
  if (expectedLength < 0) {
    throw ArgumentError.value(expectedLength, 'expectedLength');
  }
  final destination = File(path).absolute;
  final parent = destination.parent;
  if (!await parent.exists()) {
    throw FileSystemException('本地目标目录不存在', parent.path);
  }
  validateLocalFileName(localFileName(destination.path));

  final initialType = await FileSystemEntity.type(
    destination.path,
    followLinks: false,
  );
  if (initialType == FileSystemEntityType.link ||
      initialType == FileSystemEntityType.directory) {
    throw FileSystemException('目标必须是普通文件，拒绝跟随链接或覆盖目录', path);
  }
  if (initialType == FileSystemEntityType.file && !overwriteConfirmed) {
    throw FileSystemException('目标文件已存在，需要明确确认覆盖', path);
  }
  final initialStat = initialType == FileSystemEntityType.file
      ? await destination.stat()
      : null;

  final identityHash = sha256
      .convert(utf8.encode('$transferIdentity\u0000${destination.path}'))
      .toString();
  final sourceHash = sha256
      .convert(utf8.encode('$sourceVersion\u0000$expectedLength'))
      .toString();
  final part = File(
    '${parent.path}${Platform.pathSeparator}.geekcore-resume-$identityHash.part',
  );
  final metadata = File(
    '${parent.path}${Platform.pathSeparator}.geekcore-resume-$identityHash.json',
  );

  final partType = await FileSystemEntity.type(part.path, followLinks: false);
  final metadataType = await FileSystemEntity.type(
    metadata.path,
    followLinks: false,
  );
  final partTypeIsSafe =
      partType == FileSystemEntityType.file ||
      partType == FileSystemEntityType.notFound;
  final metadataTypeIsSafe =
      metadataType == FileSystemEntityType.file ||
      metadataType == FileSystemEntityType.notFound;
  if (!partTypeIsSafe || !metadataTypeIsSafe) {
    throw FileSystemException('续传临时路径类型不安全，已停止写入', path);
  }

  var resumeOffset = 0;
  final metadataMatches = await _resumeMetadataMatches(
    metadata,
    metadataType,
    sourceHash,
    expectedLength,
  );
  if (metadataMatches && partType == FileSystemEntityType.file) {
    final partLength = await part.length();
    if (partLength <= expectedLength) resumeOffset = partLength;
  }
  if (resumeOffset == 0 || !metadataMatches) {
    if (partType == FileSystemEntityType.file) await part.delete();
    if (metadataType == FileSystemEntityType.file) await metadata.delete();
    await _writeResumeMetadata(metadata, sourceHash, expectedLength);
    await part.create(exclusive: true);
  }

  onProgress?.call(resumeOffset);
  if (resumeOffset < expectedLength) {
    final output = await part.open(mode: FileMode.append);
    var bytesReceived = resumeOffset;
    try {
      await for (final chunk in openRead(resumeOffset)) {
        if (bytesReceived + chunk.length > expectedLength) {
          throw StateError('远端文件大小在续传期间发生变化，部分文件已保留');
        }
        await output.writeFrom(chunk);
        bytesReceived += chunk.length;
        onProgress?.call(bytesReceived);
      }
      await output.flush();
    } finally {
      await output.close();
    }
    if (bytesReceived != expectedLength) {
      throw StateError('下载中断：已保存 $bytesReceived / $expectedLength 字节，可重试续传');
    }
  }

  if (await part.length() != expectedLength) {
    throw StateError('本地续传文件长度不匹配，已保留部分文件');
  }
  await validateSource();

  final currentType = await FileSystemEntity.type(
    destination.path,
    followLinks: false,
  );
  if (initialType == FileSystemEntityType.notFound &&
      currentType != FileSystemEntityType.notFound) {
    throw FileSystemException('下载期间本地出现了同名项目，已保留原项目', path);
  }
  if (initialType == FileSystemEntityType.file &&
      (currentType != FileSystemEntityType.file ||
          !_sameFileVersion(initialStat!, await destination.stat()))) {
    throw FileSystemException('下载期间本地文件已变化，已保留新版本', path);
  }

  beforeCommit?.call();
  final backup = File(
    '${parent.path}${Platform.pathSeparator}.geekcore-${_transferToken()}.bak',
  );
  var backupCreated = false;
  var committed = false;
  try {
    if (initialType == FileSystemEntityType.file) {
      await destination.rename(backup.path);
      backupCreated = true;
      if (!_sameFileVersion(initialStat!, await backup.stat())) {
        try {
          await backup.rename(destination.path);
          backupCreated = false;
        } on Object catch (restoreError) {
          throw FileSystemException(
            '下载期间本地文件已变化且恢复失败；原文件保存在 ${backup.path}：$restoreError',
            path,
          );
        }
        throw FileSystemException('下载期间本地文件已变化，已恢复原文件', path);
      }
    }
    try {
      await part.rename(destination.path);
      committed = true;
    } catch (error) {
      if (backupCreated) {
        try {
          await backup.rename(destination.path);
          backupCreated = false;
        } on Object catch (restoreError) {
          throw FileSystemException(
            '提交下载失败且原文件恢复失败；原文件保存在 ${backup.path}：$restoreError',
            path,
          );
        }
      }
      rethrow;
    }
  } finally {
    if (committed && backupCreated) {
      try {
        await backup.delete();
      } on Object {
        // The downloaded file is already committed; leave the old backup intact.
      }
    }
  }
  if (committed) {
    try {
      await metadata.delete();
    } on Object {
      // A retry sees no part file and discards this stale sidecar safely.
    }
  }
}

Future<bool> _resumeMetadataMatches(
  File metadata,
  FileSystemEntityType metadataType,
  String sourceHash,
  int expectedLength,
) async {
  if (metadataType != FileSystemEntityType.file) return false;
  try {
    final value = jsonDecode(await metadata.readAsString());
    return value is Map<String, dynamic> &&
        value['source'] == sourceHash &&
        value['length'] == expectedLength;
  } on Object {
    return false;
  }
}

Future<void> _writeResumeMetadata(
  File metadata,
  String sourceHash,
  int expectedLength,
) async {
  await metadata.writeAsString(
    jsonEncode({'source': sourceHash, 'length': expectedLength}),
    flush: true,
  );
}

bool _sameFileVersion(FileStat original, FileStat current) =>
    original.type == current.type &&
    original.size == current.size &&
    original.modified == current.modified &&
    original.changed == current.changed &&
    original.mode == current.mode;

String _transferToken() {
  final random = Random.secure();
  return List.generate(
    3,
    (_) => random.nextInt(0x7fffffff).toRadixString(16).padLeft(8, '0'),
  ).join();
}
