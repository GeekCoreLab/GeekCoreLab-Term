import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

enum RemoteTransferProtocol { sftp, scp }

class RemoteFileSource {
  const RemoteFileSource({
    required this.name,
    required this.length,
    required this.openRead,
  });

  final String name;
  final Future<int> Function() length;
  final Stream<Uint8List> Function() openRead;
}

Future<void> uploadRemoteFile({
  required SSHClient client,
  required String remoteDirectory,
  required RemoteFileSource source,
  required RemoteTransferProtocol protocol,
  SftpClient? sftpClient,
  bool overwriteConfirmed = false,
  void Function(int bytesSent)? onProgress,
}) async {
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
      await _scpUpload(client, remoteDirectory, source, onProgress: onProgress);
      return;
  }
}

Future<void> _uploadSftpFile({
  required SftpClient sftp,
  required String destination,
  required String remoteDirectory,
  required RemoteFileSource source,
  required bool overwriteConfirmed,
  void Function(int bytesSent)? onProgress,
}) async {
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
  final temporaryPath = _joinRemotePath(
    remoteDirectory,
    '.geekcore-upload-${_randomTransferToken()}.tmp',
  );
  var temporaryExists = false;
  var committed = false;
  try {
    final remoteFile = await sftp.open(
      temporaryPath,
      mode:
          SftpFileOpenMode.create |
          SftpFileOpenMode.exclusive |
          SftpFileOpenMode.write,
    );
    temporaryExists = true;
    try {
      var bytesRead = 0;
      Stream<Uint8List> validatedSource() async* {
        await for (final chunk in source.openRead()) {
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

      await remoteFile.write(validatedSource(), onProgress: onProgress).done;
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

    await sftp.rename(temporaryPath, destination);
    committed = true;
  } finally {
    if (temporaryExists && !committed) {
      try {
        await sftp.remove(temporaryPath);
      } on Object {
        // Keep the original transfer error; a disconnected server may leave
        // an orphaned sibling temporary file for manual cleanup.
      }
    }
  }
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

Future<Uint8List> downloadRemoteFile({
  required SSHClient client,
  required String remotePath,
  required RemoteTransferProtocol protocol,
  SftpClient? sftpClient,
  void Function(int bytesReceived)? onProgress,
}) async {
  switch (protocol) {
    case RemoteTransferProtocol.sftp:
      final sftp = sftpClient ?? await client.sftp();
      final ownsClient = sftpClient == null;
      try {
        final output = BytesBuilder(copy: false);
        final sink = StreamController<List<int>>();
        final done = Completer<void>();
        final subscription = sink.stream.listen(
          (chunk) {
            output.add(chunk);
          },
          onError: done.completeError,
          onDone: done.complete,
        );
        try {
          await sftp.download(
            remotePath,
            sink.sink,
            onProgress: onProgress,
            closeDestination: true,
          );
          await done.future;
          return output.takeBytes();
        } finally {
          await subscription.cancel();
          if (!sink.isClosed) await sink.close();
        }
      } finally {
        if (ownsClient) await sftp.close();
      }
    case RemoteTransferProtocol.scp:
      return _scpDownload(client, remotePath, onProgress: onProgress);
  }
}

Future<void> _scpUpload(
  SSHClient client,
  String remoteDirectory,
  RemoteFileSource source, {
  void Function(int bytesSent)? onProgress,
}) async {
  final length = await source.length();
  final session = await client.execute(
    'scp -t ${_shellQuote(remoteDirectory)}',
  );
  final reader = _SshByteReader(session.stdout);
  final stderr = BytesBuilder(copy: false);
  final stderrSubscription = session.stderr.listen(stderr.add);

  try {
    await _expectScpAck(reader, stderr);
    final header = utf8.encode('C0644 $length ${source.name}\n');
    session.stdin.add(Uint8List.fromList(header));
    await session.flush();
    await _expectScpAck(reader, stderr);

    var sent = 0;
    await for (final chunk in source.openRead()) {
      session.stdin.add(chunk);
      sent += chunk.length;
      onProgress?.call(sent);
    }
    if (sent != length) {
      throw StateError('本地文件大小在传输期间发生变化');
    }
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
    await stderrSubscription.cancel();
    await reader.cancel();
    session.close();
  }
}

Future<Uint8List> _scpDownload(
  SSHClient client,
  String remotePath, {
  void Function(int bytesReceived)? onProgress,
}) async {
  final session = await client.execute('scp -f ${_shellQuote(remotePath)}');
  final reader = _SshByteReader(session.stdout);
  final stderr = BytesBuilder(copy: false);
  final stderrSubscription = session.stderr.listen(stderr.add);

  try {
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
