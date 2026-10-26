import 'dart:async';
import 'dart:convert';
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
  void Function(int bytesSent)? onProgress,
}) async {
  final name = source.name;
  if (name.isEmpty || name.contains('/')) {
    throw ArgumentError.value(name, 'source.name', '无效的文件名');
  }
  if (name.contains('\u0000') ||
      (protocol == RemoteTransferProtocol.scp &&
          (name.contains('\n') || name.contains('\r')))) {
    throw ArgumentError.value(name, 'source.name', '文件名包含传输协议不支持的控制字符');
  }

  final destination = _joinRemotePath(remoteDirectory, name);
  switch (protocol) {
    case RemoteTransferProtocol.sftp:
      final sftp = sftpClient ?? await client.sftp();
      final ownsClient = sftpClient == null;
      try {
        final remoteFile = await sftp.open(
          destination,
          mode:
              SftpFileOpenMode.create |
              SftpFileOpenMode.truncate |
              SftpFileOpenMode.write,
        );
        try {
          await remoteFile
              .write(source.openRead(), onProgress: onProgress)
              .done;
        } finally {
          await remoteFile.close();
        }
      } finally {
        if (ownsClient) await sftp.close();
      }
      return;
    case RemoteTransferProtocol.scp:
      await _scpUpload(client, remoteDirectory, source, onProgress: onProgress);
      return;
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
