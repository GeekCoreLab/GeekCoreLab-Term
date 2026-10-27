import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

Future<List<SSHIdentity>> loadSshAgentIdentities() async => const [];

Future<Uint8List> requestSshAgentSignature({
  required String socketPath,
  required Uint8List publicKeyBlob,
  required Uint8List challenge,
  required int flags,
}) => Future.error(UnsupportedError('SSH Agent 在此平台不可用'));
