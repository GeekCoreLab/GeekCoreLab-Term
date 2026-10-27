import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'ssh_agent_protocol.dart';

const _agentTimeout = Duration(minutes: 2);

Future<List<SSHIdentity>> loadSshAgentIdentities() async {
  final socketPath = Platform.environment['SSH_AUTH_SOCK']?.trim();
  if (socketPath == null || socketPath.isEmpty) return const [];

  final response = await _requestAgent(
    socketPath,
    buildSshAgentIdentityRequest(),
  );
  final descriptors = parseSshAgentIdentityResponse(response);
  return createSshAgentIdentities(
    descriptors,
    sign: (descriptor, challenge, flags) => requestSshAgentSignature(
      socketPath: socketPath,
      publicKeyBlob: descriptor.publicKeyBlob,
      challenge: challenge,
      flags: flags,
    ),
  );
}

Future<Uint8List> requestSshAgentSignature({
  required String socketPath,
  required Uint8List publicKeyBlob,
  required Uint8List challenge,
  required int flags,
}) async {
  final request = buildSshAgentSignRequest(publicKeyBlob, challenge, flags);
  final response = await _requestAgent(socketPath, request);
  return parseSshAgentSignResponse(response);
}

Future<Uint8List> _requestAgent(String socketPath, Uint8List payload) async {
  final socket = await Socket.connect(
    InternetAddress(socketPath, type: InternetAddressType.unix),
    0,
    timeout: const Duration(seconds: 3),
  );
  final iterator = StreamIterator<Uint8List>(socket);
  final reader = _SshAgentSocketReader(iterator);
  try {
    socket.add(encodeSshAgentPacket(payload));
    await socket.flush();
    final frameLength = await reader.readUint32().timeout(_agentTimeout);
    if (frameLength == 0 || frameLength > 256 * 1024) {
      throw const FormatException('SSH Agent 响应帧长度无效');
    }
    return await reader.readExactly(frameLength).timeout(_agentTimeout);
  } finally {
    await iterator.cancel();
    await socket.close();
  }
}

class _SshAgentSocketReader {
  _SshAgentSocketReader(this._iterator);

  final StreamIterator<Uint8List> _iterator;
  Uint8List _buffer = Uint8List(0);

  Future<int> readUint32() async {
    final bytes = await readExactly(4);
    return ByteData.sublistView(bytes).getUint32(0);
  }

  Future<Uint8List> readExactly(int length) async {
    while (_buffer.length < length) {
      if (!await _iterator.moveNext()) {
        throw const FormatException('SSH Agent 在响应前关闭了连接');
      }
      final chunk = _iterator.current;
      final merged = Uint8List(_buffer.length + chunk.length)
        ..setRange(0, _buffer.length, _buffer)
        ..setRange(_buffer.length, _buffer.length + chunk.length, chunk);
      _buffer = merged;
    }
    final output = Uint8List.sublistView(_buffer, 0, length);
    _buffer = Uint8List.sublistView(_buffer, length);
    return output;
  }
}
