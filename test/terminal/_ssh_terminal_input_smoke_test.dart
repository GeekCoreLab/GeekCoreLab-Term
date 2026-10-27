import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'keeps an interactive SSH terminal alive across consecutive inputs',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'geekcore-ssh-terminal-',
      );
      await Process.run('chmod', ['700', root.path]);
      final user = Platform.environment['USER']!;
      final userKey = '${root.path}/user_key';
      final hostKey = '${root.path}/host_key';
      final authorizedKeys = File('${root.path}/authorized_keys');
      final privateKey = File(userKey);
      final pidFile = '${root.path}/sshd.pid';
      final config = File('${root.path}/sshd_config');
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = listener.port;
      await listener.close();

      Process? server;
      SSHClient? sshClient;
      SSHSession? session;
      StreamSubscription<Uint8List>? stdoutSubscription;
      StreamSubscription<Uint8List>? stderrSubscription;
      final output = StringBuffer();
      final serverLog = StringBuffer();
      final outputChanged = Completer<void>();
      var channelDone = false;

      void appendOutput(List<int> bytes) {
        output.write(utf8.decode(bytes, allowMalformed: true));
        if (!outputChanged.isCompleted) outputChanged.complete();
      }

      Future<void> waitForOutput(String value) async {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (!output.toString().contains(value)) {
          if (DateTime.now().isAfter(deadline)) {
            fail(
              'Timed out waiting for "$value"; output was: $output; '
              'channel done: $channelDone; exit code: ${session?.exitCode}; '
              'server log: $serverLog',
            );
          }
          if (outputChanged.isCompleted) {
            // Give the next SSH packet an independent wake-up signal.
            await Future<void>.delayed(const Duration(milliseconds: 20));
          } else {
            await outputChanged.future.timeout(
              const Duration(milliseconds: 500),
              onTimeout: () {},
            );
          }
        }
      }

      try {
        for (final keyPath in [userKey, hostKey]) {
          final result = await Process.run('ssh-keygen', [
            '-q',
            '-t',
            'ed25519',
            '-N',
            '',
            '-f',
            keyPath,
          ]);
          expect(result.exitCode, 0, reason: '${result.stderr}');
        }
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
PermitRootLogin yes
PermitTTY yes
AllowUsers $user
Subsystem sftp internal-sftp
''');

        server = await Process.start('/usr/bin/sshd', [
          '-D',
          '-e',
          '-f',
          config.path,
        ]);
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
        final sftp = await sshClient.sftp();
        await sftp.listdir('/tmp');
        await sftp.close();
        session = await sshClient.shell(
          pty: const SSHPtyConfig(width: 100, height: 30),
        );
        stdoutSubscription = session.stdout.listen(
          appendOutput,
          onError: (Object error) =>
              serverLog.write('SSH stdout error: $error'),
        );
        stderrSubscription = session.stderr.listen(
          appendOutput,
          onError: (Object error) =>
              serverLog.write('SSH stderr error: $error'),
        );
        unawaited(session.done.then((_) => channelDone = true));

        await session.stdin.addStream(
          Stream<Uint8List>.value(
            Uint8List.fromList(utf8.encode("printf 'first-input-ok\\n'\n")),
          ),
        );
        await session.flush();
        await waitForOutput('first-input-ok');
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(
          channelDone,
          isFalse,
          reason: 'SSH channel closed after first input',
        );

        await session.stdin.addStream(
          Stream<Uint8List>.value(
            Uint8List.fromList(utf8.encode("printf 'second-input-ok\\n'\n")),
          ),
        );
        await session.flush();
        await waitForOutput('second-input-ok');
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(
          channelDone,
          isFalse,
          reason: 'SSH channel closed after second input',
        );
      } finally {
        await stdoutSubscription?.cancel();
        await stderrSubscription?.cancel();
        session?.close();
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
            Platform.environment['RUN_SSH_TERMINAL_SMOKE'] != '1'
        ? 'Set RUN_SSH_TERMINAL_SMOKE=1 on Linux with openssh-server installed.'
        : false,
  );
}
