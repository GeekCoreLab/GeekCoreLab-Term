import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/ssh_agent_protocol.dart';

void main() {
  test('parses bounded SSH Agent identity answers', () {
    final keyBlob = _hostKey('ssh-ed25519', [1, 2, 3, 4]);
    final identities = parseSshAgentIdentityResponse(
      _identityAnswer([(keyBlob, 'ci key')]),
    );

    expect(identities, hasLength(1));
    expect(identities.single.keyType, 'ssh-ed25519');
    expect(identities.single.comment, 'ci key');
    expect(identities.single.publicKeyBlob, keyBlob);
  });

  test('creates RSA identities with SHA-2 choices and agent flags', () async {
    final keyBlob = _hostKey('ssh-rsa', [5, 6, 7]);
    final descriptor = parseSshAgentIdentityResponse(
      _identityAnswer([(keyBlob, 'legacy rsa')]),
    ).single;
    final signRequests = <(String, int)>[];
    final identities = createSshAgentIdentities(
      [descriptor],
      sign: (descriptor, challenge, flags) async {
        signRequests.add((descriptor.keyType, flags));
        return Uint8List.fromList([0, 0, 0, 0]);
      },
    );

    expect(identities.map((identity) => identity.type), [
      'rsa-sha2-512',
      'rsa-sha2-256',
      'ssh-rsa',
    ]);
    for (final identity in identities) {
      await identity.sign(Uint8List.fromList([9]));
    }
    expect(signRequests.map((request) => request.$2), [4, 2, 0]);
  });

  test('encodes sign requests and rejects malformed responses', () {
    final keyBlob = _hostKey('ssh-ed25519', [1, 2, 3]);
    final packet = encodeSshAgentPacket(
      buildSshAgentSignRequest(keyBlob, Uint8List.fromList([8, 9]), 0),
    );
    expect(ByteData.sublistView(packet).getUint32(0), packet.length - 4);
    expect(packet[4], 13);

    expect(
      () => parseSshAgentIdentityResponse(Uint8List.fromList([5])),
      throwsFormatException,
    );
    expect(
      () => parseSshAgentSignResponse(Uint8List.fromList([14, 0, 0, 0, 9, 1])),
      throwsFormatException,
    );
  });
}

Uint8List _hostKey(String type, List<int> body) =>
    _concat([_wireString(utf8.encode(type)), _wireString(body)]);

Uint8List _identityAnswer(List<(Uint8List, String)> identities) {
  final writer = BytesBuilder(copy: false)
    ..add([12])
    ..add(_uint32(identities.length));
  for (final (key, comment) in identities) {
    writer
      ..add(_wireString(key))
      ..add(_wireString(utf8.encode(comment)));
  }
  return writer.takeBytes();
}

Uint8List _wireString(List<int> bytes) =>
    _concat([_uint32(bytes.length), bytes]);

Uint8List _uint32(int value) {
  final bytes = Uint8List(4);
  ByteData.sublistView(bytes).setUint32(0, value);
  return bytes;
}

Uint8List _concat(List<List<int>> values) {
  final writer = BytesBuilder(copy: false);
  for (final value in values) {
    writer.add(value);
  }
  return writer.takeBytes();
}
