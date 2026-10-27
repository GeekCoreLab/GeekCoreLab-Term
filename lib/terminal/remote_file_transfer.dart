import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

enum RemoteTransferProtocol { sftp, scp }

class RemoteTransferCancelled implements Exception {
  const RemoteTransferCancelled();

  @override
  String toString() => '用户取消传输';
}

class RemoteFileSourceChanged implements Exception {
  const RemoteFileSourceChanged(this.message);

  final String message;

  @override
  String toString() => message;
}

class RemoteTransferCancellation {
  final StreamController<void> _cancelEvents = StreamController<void>.broadcast(
    sync: true,
  );
  bool _isCancelled = false;
  bool _canCancel = true;

  bool get isCancelled => _isCancelled;
  bool get canCancel => _canCancel && !_isCancelled;
  Stream<void> get onCancel => _cancelEvents.stream;

  bool cancel() {
    if (!canCancel) return false;
    _isCancelled = true;
    _cancelEvents.add(null);
    return true;
  }

  void beginCommit() {
    _canCancel = false;
  }

  void throwIfCancelled() {
    if (_isCancelled) throw const RemoteTransferCancelled();
  }

  Future<void> dispose() => _cancelEvents.close();
}

class RemoteFileSource {
  const RemoteFileSource({
    required this.name,
    required this.length,
    required this.openRead,
    this.openReadFromOffset,
    this.localPath,
    this.localLength,
    this.localModifiedAtMillis,
  });

  final String name;
  final Future<int> Function() length;
  final Stream<Uint8List> Function() openRead;
  final Stream<Uint8List> Function(int offset)? openReadFromOffset;
  final String? localPath;
  final int? localLength;
  final int? localModifiedAtMillis;

  bool get canResumeFromLocalPath =>
      localPath != null && localPath!.isNotEmpty && openReadFromOffset != null;
}

String createRemoteTransferResumeToken() => _randomTransferToken();

Future<void> uploadRemoteFile({
  required SSHClient client,
  required String remoteDirectory,
  required RemoteFileSource source,
  required RemoteTransferProtocol protocol,
  SftpClient? sftpClient,
  bool overwriteConfirmed = false,
  RemoteTransferCancellation? cancellation,
  String? resumeToken,
  void Function(int bytesSent)? onProgress,
}) async {
  cancellation?.throwIfCancelled();
  final name = source.name;
  validateRemoteFileName(name, protocol);

  final destination = _joinRemotePath(remoteDirectory, name);
  switch (protocol) {
    case RemoteTransferProtocol.sftp:
      final sftp = sftpClient ?? await client.sftp();
      final ownsClient = sftpClient == null;
      try {
        await _uploadSftpFile(
          sftp: sftp,
          destination: destination,
          remoteDirectory: remoteDirectory,
          source: source,
          overwriteConfirmed: overwriteConfirmed,
          cancellation: cancellation,
          resumeToken: resumeToken,
          onProgress: onProgress,
        );
      } finally {
        if (ownsClient) await sftp.close();
      }
      return;
    case RemoteTransferProtocol.scp:
      final sftp = sftpClient ?? await client.sftp();
      final ownsClient = sftpClient == null;
      try {
        final target = await _statRemoteFile(sftp, destination);
        if (target != null && !target.isFile) {
          throw StateError('远端同名目标不是普通文件，已取消上传');
        }
        if (target != null && !overwriteConfirmed) {
          throw StateError('远端已存在同名文件，请确认覆盖后重试');
        }
      } finally {
        if (ownsClient) await sftp.close();
      }
      await _scpUpload(
        client,
        remoteDirectory,
        source,
        cancellation: cancellation,
        onProgress: onProgress,
      );
      return;
  }
}

Future<void> _uploadSftpFile({
  required SftpClient sftp,
  required String destination,
  required String remoteDirectory,
  required RemoteFileSource source,
  required bool overwriteConfirmed,
  RemoteTransferCancellation? cancellation,
  String? resumeToken,
  void Function(int bytesSent)? onProgress,
}) async {
  cancellation?.throwIfCancelled();
  final initialTarget = await _statRemoteFile(sftp, destination);
  if (initialTarget != null) {
    if (!overwriteConfirmed) {
      throw StateError('远端已存在同名文件，请确认覆盖后重试');
    }
    if (!initialTarget.isFile) {
      throw StateError('远端同名目标不是普通文件，已取消上传');
    }
    if (!await _supportsAtomicReplace(sftp)) {
      throw StateError('远端 SFTP 服务不支持安全覆盖，原文件未修改');
    }
  }

  final length = await source.length();
  final canResume =
      source.canResumeFromLocalPath &&
      resumeToken != null &&
      RegExp(r'^[a-f0-9]{24}$').hasMatch(resumeToken);
  final temporaryPath = canResume
      ? _remoteUploadPartialPath(destination, resumeToken)
      : _joinRemotePath(
          remoteDirectory,
          '.geekcore-upload-${_randomTransferToken()}.tmp',
        );
  final metadataPath = canResume ? '$temporaryPath.meta' : null;
  var keepPartial = false;
  var offset = 0;
  var resumePartExists = false;
  if (canResume) {
    final sourceMetadata = _uploadResumeMetadata(source, length);
    final metadataMatches = await _remoteUploadMetadataMatches(
      sftp,
      metadataPath!,
      sourceMetadata,
    );
    final existingPart = await _statRemoteFile(sftp, temporaryPath);
    if (!metadataMatches ||
        existingPart == null ||
        !existingPart.isFile ||
        existingPart.size == null ||
        existingPart.size! > length) {
      await _removeRemoteFileIfExists(sftp, temporaryPath);
      await _removeRemoteFileIfExists(sftp, metadataPath);
    } else {
      offset = existingPart.size!;
      resumePartExists = true;
    }

    if (offset == 0) {
      await _createRemoteUploadMetadata(sftp, metadataPath, sourceMetadata);
    }
    keepPartial = true;
  }
  var committed = false;
  var discardPartial = false;
  try {
    final remoteFile = await sftp.open(
      temporaryPath,
      mode: resumePartExists
          ? SftpFileOpenMode.write
          : SftpFileOpenMode.create |
                SftpFileOpenMode.exclusive |
                SftpFileOpenMode.write,
    );
    try {
      var bytesRead = offset;
      Stream<Uint8List> validatedSource() async* {
        cancellation?.throwIfCancelled();
        final chunks = offset > 0
            ? source.openReadFromOffset!(offset)
            : source.openRead();
        await for (final chunk in chunks) {
          cancellation?.throwIfCancelled();
          bytesRead += chunk.length;
          if (bytesRead > length) {
            throw StateError('本地文件大小在传输期间发生变化');
          }
          yield chunk;
        }
        if (bytesRead != length) {
          throw StateError('本地文件大小在传输期间发生变化');
        }
      }

      if (offset < length) {
        final writer = remoteFile.write(
          validatedSource(),
          offset: offset,
          onProgress: (bytes) => onProgress?.call(offset + bytes),
        );
        Future<void>? abortFuture;
        final cancellationSubscription = cancellation?.onCancel.listen((_) {
          abortFuture ??= writer.abort();
        });
        if (cancellation?.isCancelled ?? false) {
          abortFuture ??= writer.abort();
        }
        try {
          onProgress?.call(offset);
          await writer.done;
          cancellation?.throwIfCancelled();
        } finally {
          await cancellationSubscription?.cancel();
          await abortFuture;
        }
      }
      cancellation?.throwIfCancelled();
      final originalMode = initialTarget?.mode;
      if (originalMode != null) {
        // Preserve the ordinary rwx permissions while keeping special bits
        // from being carried across to a newly owned inode.
        await remoteFile.setStat(
          SftpFileAttrs(mode: SftpFileMode.value(originalMode.value & 0x1ff)),
        );
      }
    } finally {
      await remoteFile.close();
    }

    final uploadedPart = await _statRemoteFile(sftp, temporaryPath);
    if (uploadedPart?.size != length) {
      throw StateError('远端临时文件长度与本地文件不一致');
    }

    final currentTarget = await _statRemoteFile(sftp, destination);
    if (currentTarget != null && !currentTarget.isFile) {
      throw StateError('传输期间远端目标类型发生变化，已取消替换');
    }
    if (initialTarget == null && currentTarget != null) {
      throw StateError('传输期间远端出现了同名文件，已保留原文件');
    }
    if (initialTarget != null &&
        currentTarget != null &&
        !_sameRemoteVersion(initialTarget, currentTarget)) {
      throw StateError('传输期间远端文件已变化，已保留新版本');
    }
    if (currentTarget != null && !await _supportsAtomicReplace(sftp)) {
      throw StateError('远端 SFTP 服务不支持安全覆盖，原文件未修改');
    }

    cancellation?.throwIfCancelled();
    onProgress?.call(offset);
    cancellation?.beginCommit();
    await sftp.rename(temporaryPath, destination);
    committed = true;
    if (metadataPath != null) {
      try {
        await _removeRemoteFileIfExists(sftp, metadataPath);
      } on Object {
        // A completed upload should not be reported as failed if cleanup alone
        // cannot remove its hidden metadata file.
      }
    }
  } on RemoteFileSourceChanged {
    discardPartial = true;
    rethrow;
  } finally {
    if (!committed &&
        (!keepPartial ||
            discardPartial ||
            (cancellation?.isCancelled ?? false))) {
      try {
        await _removeRemoteFileIfExists(sftp, temporaryPath);
      } on Object {
        // Keep the original transfer error; a disconnected server may leave
        // an orphaned sibling temporary file for manual cleanup.
      }
      if (metadataPath != null) {
        try {
          await _removeRemoteFileIfExists(sftp, metadataPath);
        } on Object {
          // Preserve the primary transfer or cancellation result.
        }
      }
    }
  }
}

String _remoteUploadPartialPath(String destination, String token) {
  final separator = destination.lastIndexOf('/');
  final directory = separator <= 0 ? '/' : destination.substring(0, separator);
  final name = '.geekcore-upload-$token.part';
  return _joinRemotePath(directory, name);
}

Map<String, Object?> _uploadResumeMetadata(
  RemoteFileSource source,
  int length,
) => {
  'version': 1,
  'name': source.name,
  'length': length,
  'modifiedAtMillis': source.localModifiedAtMillis,
};

Future<bool> _remoteUploadMetadataMatches(
  SftpClient sftp,
  String metadataPath,
  Map<String, Object?> expected,
) async {
  final attrs = await _statRemoteFile(sftp, metadataPath);
  if (attrs == null ||
      !attrs.isFile ||
      attrs.size == null ||
      attrs.size! > 4096) {
    return false;
  }
  final file = await sftp.open(metadataPath, mode: SftpFileOpenMode.read);
  try {
    final bytes = await file.readBytes(length: attrs.size);
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) return false;
    return decoded.length == expected.length &&
        expected.entries.every((entry) => decoded[entry.key] == entry.value);
  } on FormatException {
    return false;
  } finally {
    await file.close();
  }
}

Future<void> _createRemoteUploadMetadata(
  SftpClient sftp,
  String metadataPath,
  Map<String, Object?> metadata,
) async {
  final file = await sftp.open(
    metadataPath,
    mode:
        SftpFileOpenMode.create |
        SftpFileOpenMode.exclusive |
        SftpFileOpenMode.write,
  );
  try {
    await file.writeBytes(
      Uint8List.fromList(utf8.encode(jsonEncode(metadata))),
    );
  } finally {
    await file.close();
  }
}

Future<void> _removeRemoteFileIfExists(SftpClient sftp, String path) async {
  try {
    await sftp.remove(path);
  } on SftpStatusError catch (error) {
    if (error.code != SftpStatusCode.noSuchFile) rethrow;
  }
}

Future<void> removeRemoteUploadResumeArtifacts({
  required SftpClient sftp,
  required String destination,
  required String resumeToken,
}) async {
  if (!RegExp(r'^[a-f0-9]{24}$').hasMatch(resumeToken)) return;
  final partialPath = _remoteUploadPartialPath(destination, resumeToken);
  await _removeRemoteFileIfExists(sftp, partialPath);
  await _removeRemoteFileIfExists(sftp, '$partialPath.meta');
}

Future<SftpFileAttrs?> _statRemoteFile(SftpClient sftp, String path) async {
  try {
    return await sftp.stat(path, followLink: false);
  } on SftpStatusError catch (error) {
    if (error.code == SftpStatusCode.noSuchFile) return null;
    rethrow;
  }
}

Future<bool> _supportsAtomicReplace(SftpClient sftp) async {
  final handshake = await sftp.handshake;
  return handshake.extensions['posix-rename@openssh.com'] == '1';
}

bool _sameRemoteVersion(SftpFileAttrs original, SftpFileAttrs current) {
  var compared = false;
  if (original.size != current.size) return false;
  if (original.size != null) {
    compared = true;
  }
  if (original.modifyTime != current.modifyTime) return false;
  if (original.modifyTime != null) {
    compared = true;
  }
  return compared;
}

String _randomTransferToken() {
  final random = Random.secure();
  return List.generate(
    3,
    (_) => random.nextInt(0x7fffffff).toRadixString(16).padLeft(8, '0'),
  ).join();
}

void validateRemoteFileName(String name, RemoteTransferProtocol protocol) {
  if (name.isEmpty || name == '.' || name == '..' || name.contains('/')) {
    throw ArgumentError.value(name, 'name', '无效的文件名');
  }
  if (name.contains('\u0000') ||
      (protocol == RemoteTransferProtocol.scp &&
          (name.contains('\n') || name.contains('\r')))) {
    throw ArgumentError.value(name, 'name', '文件名包含传输协议不支持的控制字符');
  }
}

bool isRemoteTransferTemporaryFileName(String name) =>
    name.startsWith('.geekcore-upload-') &&
    (name.endsWith('.tmp') ||
        name.endsWith('.part') ||
        name.endsWith('.part.meta'));

Future<Uint8List> downloadRemoteFile({
  required SSHClient client,
  required String remotePath,
  required RemoteTransferProtocol protocol,
  SftpClient? sftpClient,
  RemoteTransferCancellation? cancellation,
  void Function(int bytesReceived)? onProgress,
}) async {
  cancellation?.throwIfCancelled();
  switch (protocol) {
    case RemoteTransferProtocol.sftp:
      final sftp = sftpClient ?? await client.sftp();
      final ownsClient = sftpClient == null;
      try {
        final file = await sftp.open(remotePath, mode: SftpFileOpenMode.read);
        Future<void>? cancellationClose;
        final cancellationSubscription = cancellation?.onCancel.listen((_) {
          cancellationClose ??= file.close();
        });
        if (cancellation?.isCancelled ?? false) {
          cancellationClose ??= file.close();
        }
        try {
          final output = BytesBuilder(copy: false);
          await for (final chunk in file.read(onProgress: onProgress)) {
            cancellation?.throwIfCancelled();
            output.add(chunk);
          }
          cancellation?.throwIfCancelled();
          return output.takeBytes();
        } finally {
          await cancellationSubscription?.cancel();
          await cancellationClose;
          await file.close();
        }
      } finally {
        if (ownsClient) await sftp.close();
      }
    case RemoteTransferProtocol.scp:
      return _scpDownload(
        client,
        remotePath,
        cancellation: cancellation,
        onProgress: onProgress,
      );
  }
}

Future<void> _scpUpload(
  SSHClient client,
  String remoteDirectory,
  RemoteFileSource source, {
  RemoteTransferCancellation? cancellation,
  void Function(int bytesSent)? onProgress,
}) async {
  cancellation?.throwIfCancelled();
  final length = await source.length();
  final session = await client.execute(
    'scp -t ${_shellQuote(remoteDirectory)}',
  );
  final cancellationSubscription = cancellation?.onCancel.listen((_) {
    session.close();
  });
  if (cancellation?.isCancelled ?? false) session.close();
  final reader = _SshByteReader(session.stdout);
  final stderr = BytesBuilder(copy: false);
  final stderrSubscription = session.stderr.listen(stderr.add);

  try {
    cancellation?.throwIfCancelled();
    await _expectScpAck(reader, stderr);
    final header = utf8.encode('C0644 $length ${source.name}\n');
    session.stdin.add(Uint8List.fromList(header));
    await session.flush();
    await _expectScpAck(reader, stderr);

    var sent = 0;
    await for (final chunk in source.openRead()) {
      cancellation?.throwIfCancelled();
      session.stdin.add(chunk);
      sent += chunk.length;
      onProgress?.call(sent);
    }
    if (sent != length) {
      throw StateError('本地文件大小在传输期间发生变化');
    }
    cancellation?.throwIfCancelled();
    cancellation?.beginCommit();
    session.stdin.add(Uint8List.fromList([0]));
    await session.flush();
    await _expectScpAck(reader, stderr);
    await session.stdin.close();
    await session.done;
    if (session.exitCode case final code? when code != 0) {
      throw StateError('远端 SCP 退出码：$code');
    }
  } catch (error) {
    final detail = _decodeError(stderr.takeBytes());
    if (detail.isNotEmpty) throw StateError('$error：$detail');
    rethrow;
  } finally {
    await cancellationSubscription?.cancel();
    await stderrSubscription.cancel();
    await reader.cancel();
    session.close();
  }
}

Future<Uint8List> _scpDownload(
  SSHClient client,
  String remotePath, {
  RemoteTransferCancellation? cancellation,
  void Function(int bytesReceived)? onProgress,
}) async {
  cancellation?.throwIfCancelled();
  final session = await client.execute('scp -f ${_shellQuote(remotePath)}');
  final cancellationSubscription = cancellation?.onCancel.listen((_) {
    session.close();
  });
  if (cancellation?.isCancelled ?? false) session.close();
  final reader = _SshByteReader(session.stdout);
  final stderr = BytesBuilder(copy: false);
  final stderrSubscription = session.stderr.listen(stderr.add);

  try {
    cancellation?.throwIfCancelled();
    session.stdin.add(Uint8List.fromList([0]));
    await session.flush();
    final messageType = await reader.readByte();
    if (messageType == null) throw StateError('远端 SCP 连接提前关闭');
    if (messageType != 0x43) {
      await _throwScpResponse(reader, messageType, stderr);
    }

    final header = await reader.readLine();
    final fields = header.split(' ');
    if (fields.length < 3 || !fields[1].contains(RegExp(r'^\d+$'))) {
      throw StateError('无法解析远端 SCP 文件信息');
    }
    final fileSize = int.parse(fields[1]);
    session.stdin.add(Uint8List.fromList([0]));
    await session.flush();

    final output = BytesBuilder(copy: false);
    var received = 0;
    while (received < fileSize) {
      cancellation?.throwIfCancelled();
      final chunk = await reader.readChunk(fileSize - received);
      output.add(chunk);
      received += chunk.length;
      onProgress?.call(received);
    }

    final trailer = await reader.readByte();
    if (trailer == null) throw StateError('远端 SCP 文件流提前结束');
    await _expectScpResponse(reader, trailer, stderr);
    session.stdin.add(Uint8List.fromList([0]));
    await session.flush();
    await session.stdin.close();
    await session.done;
    if (session.exitCode case final code? when code != 0) {
      throw StateError('远端 SCP 退出码：$code');
    }
    return output.takeBytes();
  } catch (error) {
    final detail = _decodeError(stderr.takeBytes());
    if (detail.isNotEmpty) throw StateError('$error：$detail');
    rethrow;
  } finally {
    await cancellationSubscription?.cancel();
    await stderrSubscription.cancel();
    await reader.cancel();
    session.close();
  }
}

Future<void> _expectScpAck(_SshByteReader reader, BytesBuilder stderr) async {
  final code = await reader.readByte();
  if (code == null) throw StateError('远端 SCP 连接提前关闭');
  await _expectScpResponse(reader, code, stderr);
}

Future<void> _expectScpResponse(
  _SshByteReader reader,
  int code,
  BytesBuilder stderr,
) async {
  if (code == 0) return;
  final message = await reader.readLine();
  final detail = _decodeError(stderr.takeBytes());
  throw StateError(
    '远端 SCP 错误${code == 2 ? '（致命）' : ''}：${message.trim()}${detail.isEmpty ? '' : ' $detail'}',
  );
}

Future<Never> _throwScpResponse(
  _SshByteReader reader,
  int code,
  BytesBuilder stderr,
) async {
  await _expectScpResponse(reader, code, stderr);
  throw StateError('远端 SCP 响应无效');
}

String _decodeError(Uint8List bytes) =>
    utf8.decode(bytes, allowMalformed: true).trim();

String _shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

String _joinRemotePath(String directory, String name) {
  if (directory.endsWith('/')) return '$directory$name';
  return '$directory/$name';
}

class _SshByteReader {
  _SshByteReader(Stream<Uint8List> stream) : _iterator = StreamIterator(stream);

  final StreamIterator<Uint8List> _iterator;
  Uint8List _chunk = Uint8List(0);
  int _offset = 0;

  Future<int?> readByte() async {
    while (_offset >= _chunk.length) {
      if (!await _iterator.moveNext()) return null;
      _chunk = _iterator.current;
      _offset = 0;
    }
    return _chunk[_offset++];
  }

  Future<String> readLine() async {
    final bytes = BytesBuilder(copy: false);
    while (true) {
      final byte = await readByte();
      if (byte == null) throw StateError('远端 SCP 响应行不完整');
      if (byte == 0x0a) break;
      bytes.addByte(byte);
    }
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }

  Future<Uint8List> readChunk(int maximumLength) async {
    if (_offset >= _chunk.length) {
      if (!await _iterator.moveNext()) throw StateError('远端 SCP 文件流提前结束');
      _chunk = _iterator.current;
      _offset = 0;
    }
    final length = (maximumLength < _chunk.length - _offset)
        ? maximumLength
        : _chunk.length - _offset;
    final result = Uint8List.sublistView(_chunk, _offset, _offset + length);
    _offset += length;
    return result;
  }

  Future<void> cancel() => _iterator.cancel();
}
