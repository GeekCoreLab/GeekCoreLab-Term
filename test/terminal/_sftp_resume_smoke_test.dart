import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/local_file_system.dart';

void main() {
  test(
    'resumes a partial local download using a real local SFTP server',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'geekcore-sftp-resume-',
      );
      await Process.run('chmod', ['700', root.path]);
      final user = Platform.environment['USER']!;
      final userKey = '${root.path}/user_key';
      final hostKey = '${root.path}/host_key';
      final authorizedKeys = File('${root.path}/authorized_keys');
      final privateKey = File(userKey);
      final remoteFilePath = '${root.path}/remote.bin';
      final localFilePath = '${root.path}/local.bin';
      final pidFile = '${root.path}/sshd.pid';
      final config = File('${root.path}/sshd_config');
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = listener.port;
      await listener.close();

      Process? server;
      SSHClient? sshClient;
      SftpClient? sftp;
      try {
        final userKeyResult = await Process.run('ssh-keygen', [
          '-q',
          '-t',
          'ed25519',
          '-N',
          '',
          '-f',
          userKey,
        ]);
        expect(userKeyResult.exitCode, 0, reason: '${userKeyResult.stderr}');
        final hostKeyResult = await Process.run('ssh-keygen', [
          '-q',
          '-t',
          'ed25519',
          '-N',
          '',
          '-f',
          hostKey,
        ]);
        expect(hostKeyResult.exitCode, 0, reason: '${hostKeyResult.stderr}');
        await authorizedKeys.writeAsString(
          '${await File('$userKey.pub').readAsString()}\n',
        );
        await config.writeAsString('''
Port $port
ListenAddress 127.0.0.1
HostKey $hostKey
PidFile $pidFile
AuthorizedKeysFile $authorizedKeys
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
AllowUsers $user
Subsystem sftp internal-sftp
''');
        final data = Uint8List.fromList(
          List<int>.generate(300_123, (index) => (index * 17 + 31) & 0xff),
        );
        await File(remoteFilePath).writeAsBytes(data, flush: true);

        server = await Process.start('/usr/bin/sshd', [
          '-D',
          '-e',
          '-f',
          config.path,
        ]);
        final serverLog = StringBuffer();
        unawaited(
          server.stderr
              .transform(utf8.decoder)
              .listen(serverLog.write)
              .asFuture<void>(),
        );
        unawaited(
          server.stdout
              .transform(utf8.decoder)
              .listen(serverLog.write)
              .asFuture<void>(),
        );
        var ready = false;
        for (var attempt = 0; attempt < 60; attempt++) {
          try {
            final socket = await Socket.connect(
              InternetAddress.loopbackIPv4,
              port,
              timeout: const Duration(milliseconds: 200),
            );
            socket.destroy();
            ready = true;
            break;
          } on SocketException {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
        expect(ready, isTrue, reason: serverLog.toString());

        final socket = await SSHSocket.connect(
          InternetAddress.loopbackIPv4.address,
          port,
        );
        sshClient = SSHClient(
          socket,
          username: user,
          identities: SSHKeyPair.fromPem(await privateKey.readAsString()),
          onVerifyHostKey: (_, _) => true,
        );
        await sshClient.authenticated;
        sftp = await sshClient.sftp();
        final remoteFile = await sftp.open(
          remoteFilePath,
          mode: SftpFileOpenMode.read,
        );
        final remoteVersion = await remoteFile.stat();
        final transferIdentity = '127.0.0.1:$port:$user:$remoteFilePath';
        final version =
            '${remoteVersion.size}:${remoteVersion.modifyTime}:${remoteVersion.mode?.value}';
        await expectLater(
          writeResumableLocalDownload(
            path: localFilePath,
            transferIdentity: transferIdentity,
            sourceVersion: version,
            expectedLength: data.length,
            openRead: (offset) async* {
              await for (final chunk in remoteFile.read(
                offset: offset,
                length: data.length - offset,
              )) {
                yield chunk;
                throw StateError('injected stream interruption');
              }
            },
            overwriteConfirmed: false,
            validateSource: () async {},
          ),
          throwsStateError,
        );
        final partialFiles = await Directory(root.path)
            .list()
            .where((entity) => entity.path.endsWith('.part'))
            .cast<File>()
            .toList();
        final firstPartial = await partialFiles.single.length();
        expect(firstPartial, greaterThan(0));
        await remoteFile.close();

        final resumedRemote = await sftp.open(
          remoteFilePath,
          mode: SftpFileOpenMode.read,
        );
        await writeResumableLocalDownload(
          path: localFilePath,
          transferIdentity: transferIdentity,
          sourceVersion: version,
          expectedLength: data.length,
          openRead: (offset) =>
              resumedRemote.read(offset: offset, length: data.length - offset),
          overwriteConfirmed: false,
          validateSource: () async {
            final current = await resumedRemote.stat();
            expect(current.size, remoteVersion.size);
            expect(current.modifyTime, remoteVersion.modifyTime);
          },
        );
        await resumedRemote.close();

        expect(await File(localFilePath).readAsBytes(), data);
        expect(
          await Directory(root.path)
              .list()
              .where((entity) => entity.path.contains('.geekcore-resume-'))
              .isEmpty,
          isTrue,
        );
      } finally {
        await sftp?.close();
        await sshClient?.close();
        if (server != null) {
          server.kill(ProcessSignal.sigterm);
          await server.exitCode.timeout(
            const Duration(seconds: 3),
            onTimeout: () => -1,
          );
        }
        if (await root.exists()) await root.delete(recursive: true);
      }
    },
    skip:
        !Platform.isLinux ||
            Platform.environment['RUN_SFTP_RESUME_SMOKE'] != '1'
        ? 'Set RUN_SFTP_RESUME_SMOKE=1 on Linux with openssh-server installed.'
        : false,
  );
}
