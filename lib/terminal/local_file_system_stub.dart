import 'dart:typed_data';

import 'package:geekcore_term/terminal/remote_file_transfer.dart';

import 'local_file_system_models.dart';

const bool localFileSystemSupported = false;

Future<String?> defaultLocalDirectory() async => null;

Future<List<LocalFileEntry>> listLocalDirectory(String path) =>
    Future.error(UnsupportedError('本地文件浏览在当前平台不可用'));

Future<int> localDirectoryModifiedAtMillis(String path) =>
    Future.error(UnsupportedError('本地文件浏览在当前平台不可用'));

Future<bool> localFileExists(String path) => Future.value(false);

String localParentDirectory(String path) => path;

String localJoinPath(String directory, String name) => '$directory/$name';

String localFileName(String path) => path.split('/').last;

Future<RemoteFileSource> localFileSource(String path) =>
    Future.error(UnsupportedError('本地文件读取在当前平台不可用'));

Future<void> writeLocalFileAtomically(
  String path,
  Uint8List bytes, {
  required bool overwriteConfirmed,
}) => Future.error(UnsupportedError('本地文件写入在当前平台不可用'));

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
}) => Future.error(UnsupportedError('本地文件写入在当前平台不可用'));
