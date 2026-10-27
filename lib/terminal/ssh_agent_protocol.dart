import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

const _maxAgentFrameSize = 256 * 1024;
const _requestIdentities = 11;
const _identitiesAnswer = 12;
const _signRequest = 13;
const _signResponse = 14;
const _failure = 5;
const _rsaSha2_256 = 2;
const _rsaSha2_512 = 4;

class SshAgentIdentityDescriptor {
  const SshAgentIdentityDescriptor({
    required this.publicKeyBlob,
    required this.keyType,
    required this.comment,
  });

  final Uint8List publicKeyBlob;
  final String keyType;
  final String comment;
}

Uint8List encodeSshAgentPacket(Uint8List payload) {
  if (payload.isEmpty || payload.length > _maxAgentFrameSize) {
    throw const FormatException('SSH Agent 请求长度无效');
  }
  final frame = Uint8List(4 + payload.length);
  ByteData.sublistView(frame).setUint32(0, payload.length);
  frame.setRange(4, frame.length, payload);
  return frame;
}

Uint8List buildSshAgentIdentityRequest() =>
    Uint8List.fromList([_requestIdentities]);

List<SshAgentIdentityDescriptor> parseSshAgentIdentityResponse(
  Uint8List response,
) {
  final reader = _SshAgentReader(response);
  final type = reader.readByte();
  if (type == _failure) throw const FormatException('SSH Agent 拒绝了密钥查询');
  if (type != _identitiesAnswer) {
    throw const FormatException('SSH Agent 返回了未知响应');
  }
  final count = reader.readUint32();
  if (count > 1024) throw const FormatException('SSH Agent 返回的密钥数量过多');
  final identities = <SshAgentIdentityDescriptor>[];
  for (var i = 0; i < count; i++) {
    final blob = reader.readString();
    if (blob.isEmpty) throw const FormatException('SSH Agent 返回了空公钥');
    final comment = utf8.decode(reader.readString(), allowMalformed: true);
    identities.add(
      SshAgentIdentityDescriptor(
        publicKeyBlob: blob,
        keyType: SSHHostKey.getType(blob),
        comment: comment,
      ),
    );
  }
  reader.expectEnd();
  return List.unmodifiable(identities);
}

List<SSHIdentity> createSshAgentIdentities(
  Iterable<SshAgentIdentityDescriptor> descriptors, {
  required Future<Uint8List> Function(
    SshAgentIdentityDescriptor descriptor,
    Uint8List challenge,
    int flags,
  )
  sign,
}) {
  final identities = <SSHIdentity>[];
  for (final descriptor in descriptors) {
    final algorithms = descriptor.keyType == 'ssh-rsa'
        ? const <(String, int)>[
            ('rsa-sha2-512', _rsaSha2_512),
            ('rsa-sha2-256', _rsaSha2_256),
            ('ssh-rsa', 0),
          ]
        : <(String, int)>[(descriptor.keyType, 0)];
    for (final (type, flags) in algorithms) {
      identities.add(
        SSHIdentity.custom(
          type: type,
          publicKey: SSHRawHostKey(descriptor.publicKeyBlob),
          comment: descriptor.comment,
          shouldProbe: true,
          signer: (challenge) async =>
              SSHRawSignature(await sign(descriptor, challenge, flags)),
        ),
      );
    }
  }
  return List.unmodifiable(identities);
}

Uint8List buildSshAgentSignRequest(
  Uint8List publicKeyBlob,
  Uint8List challenge,
  int flags,
) {
  final writer = _SshAgentWriter()..writeByte(_signRequest);
  writer
    ..writeString(publicKeyBlob)
    ..writeString(challenge)
    ..writeUint32(flags);
  return writer.takeBytes();
}

Uint8List parseSshAgentSignResponse(Uint8List response) {
  final reader = _SshAgentReader(response);
  final type = reader.readByte();
  if (type == _failure) throw const FormatException('SSH Agent 签名失败');
  if (type != _signResponse) {
    throw const FormatException('SSH Agent 返回了未知签名响应');
  }
  final signature = reader.readString();
  if (signature.isEmpty) throw const FormatException('SSH Agent 返回了空签名');
  reader.expectEnd();
  return signature;
}

class _SshAgentReader {
  _SshAgentReader(this.bytes);

  final Uint8List bytes;
  var _offset = 0;

  int readByte() {
    _require(1);
    return bytes[_offset++];
  }

  int readUint32() {
    _require(4);
    final value = ByteData.sublistView(
      bytes,
      _offset,
      _offset + 4,
    ).getUint32(0);
    _offset += 4;
    return value;
  }

  Uint8List readString() {
    final length = readUint32();
    if (length > _maxAgentFrameSize) {
      throw const FormatException('SSH Agent 字段长度超过限制');
    }
    _require(length);
    final value = Uint8List.sublistView(bytes, _offset, _offset + length);
    _offset += length;
    return value;
  }

  void expectEnd() {
    if (_offset != bytes.length) {
      throw const FormatException('SSH Agent 响应包含多余数据');
    }
  }

  void _require(int length) {
    if (length < 0 || _offset + length > bytes.length) {
      throw const FormatException('SSH Agent 响应被截断');
    }
  }
}

class _SshAgentWriter {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  void writeByte(int value) => _builder.add([value]);

  void writeUint32(int value) {
    final bytes = Uint8List(4);
    ByteData.sublistView(bytes).setUint32(0, value);
    _builder.add(bytes);
  }

  void writeString(Uint8List value) {
    writeUint32(value.length);
    _builder.add(value);
  }

  Uint8List takeBytes() => _builder.takeBytes();
}
