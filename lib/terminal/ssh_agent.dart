import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'ssh_agent_stub.dart'
    if (dart.library.io) 'ssh_agent_io.dart'
    as platform;

Future<List<SSHIdentity>> loadSshAgentIdentities() =>
    platform.loadSshAgentIdentities();

Future<Uint8List> requestSshAgentSignature({
  required String socketPath,
  required Uint8List publicKeyBlob,
  required Uint8List challenge,
  required int flags,
}) => platform.requestSshAgentSignature(
  socketPath: socketPath,
  publicKeyBlob: publicKeyBlob,
  challenge: challenge,
  flags: flags,
);
