import 'dart:typed_data';

import 'package:geekcore_term/terminal/remote_file_transfer.dart';

export 'local_file_system_models.dart';

import 'local_file_system_models.dart';
import 'local_file_system_stub.dart'
    if (dart.library.io) 'local_file_system_io.dart'
    as platform;

bool get localFileSystemSupported => platform.localFileSystemSupported;

Future<String?> defaultLocalDirectory() => platform.defaultLocalDirectory();

Future<List<LocalFileEntry>> listLocalDirectory(String path) =>
    platform.listLocalDirectory(path);

Future<bool> localFileExists(String path) => platform.localFileExists(path);

String localParentDirectory(String path) => platform.localParentDirectory(path);

String localJoinPath(String directory, String name) =>
    platform.localJoinPath(directory, name);

String localFileName(String path) => platform.localFileName(path);

Future<RemoteFileSource> localFileSource(String path) =>
    platform.localFileSource(path);

Future<void> writeLocalFileAtomically(
  String path,
  Uint8List bytes, {
  required bool overwriteConfirmed,
}) => platform.writeLocalFileAtomically(
  path,
  bytes,
  overwriteConfirmed: overwriteConfirmed,
);

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
}) => platform.writeResumableLocalDownload(
  path: path,
  transferIdentity: transferIdentity,
  sourceVersion: sourceVersion,
  expectedLength: expectedLength,
  openRead: openRead,
  overwriteConfirmed: overwriteConfirmed,
  validateSource: validateSource,
  beforeCommit: beforeCommit,
  onProgress: onProgress,
);
