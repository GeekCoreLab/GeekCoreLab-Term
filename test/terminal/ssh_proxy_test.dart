import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/ssh_proxy.dart';

void main() {
  test(
    'SOCKS5 no-auth CONNECT preserves bytes received with the reply',
    () async {
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(listener.close);
      final serverDone = Completer<void>();
      listener.listen((socket) {
        unawaited(
          () async {
            final reader = _SocketReader(socket);
            expect(await reader.readExactly(3), [0x05, 0x01, 0x00]);
            socket.add([0x05, 0x00]);
            await socket.flush();

            expect(await reader.readExactly(4), [0x05, 0x01, 0x00, 0x03]);
            final domainLength = (await reader.readExactly(1)).single;
            expect(
              utf8.decode(await reader.readExactly(domainLength)),
              'ssh.example',
            );
            expect(await reader.readExactly(2), [0x00, 0x16]);
            socket.add([
              0x05,
              0x00,
              0x00,
              0x01,
              127,
              0,
              0,
              1,
              0,
              0,
              ...utf8.encode('SSH!'),
            ]);
            await socket.flush();
            serverDone.complete();
          }().catchError((Object error, StackTrace stackTrace) {
            serverDone.completeError(error, stackTrace);
            return null;
          }),
        );
      });

      final tunnel = await connectSshThroughProxy(
        proxy: SshProxyConfig(
          type: SshProxyType.socks5,
          address: InternetAddress.loopbackIPv4.address,
          port: listener.port,
        ),
        targetHost: 'ssh.example',
        targetPort: 22,
      );
      addTearDown(tunnel.close);

      expect(await tunnel.stream.first, utf8.encode('SSH!'));
      await serverDone.future.timeout(const Duration(seconds: 2));
    },
  );

  test('SOCKS5 username/password authentication uses UTF-8 octets', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(listener.close);
    final serverDone = Completer<void>();
    listener.listen((socket) {
      unawaited(
        () async {
          final reader = _SocketReader(socket);
          expect(await reader.readExactly(4), [0x05, 0x02, 0x00, 0x02]);
          socket.add([0x05, 0x02]);
          await socket.flush();

          expect(await reader.readExactly(2), [0x01, 6]);
          expect(utf8.decode(await reader.readExactly(6)), '用戶');
          final passwordLength = (await reader.readExactly(1)).single;
          expect(utf8.decode(await reader.readExactly(passwordLength)), '密碼');
          socket.add([0x01, 0x00]);
          await socket.flush();

          expect(await reader.readExactly(10), [
            0x05,
            0x01,
            0x00,
            0x01,
            192,
            0,
            2,
            10,
            0x01,
            0xbb,
          ]);
          socket.add([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0, 0]);
          await socket.flush();
          serverDone.complete();
        }().catchError((Object error, StackTrace stackTrace) {
          serverDone.completeError(error, stackTrace);
          return null;
        }),
      );
    });

    final tunnel = await connectSshThroughProxy(
      proxy: SshProxyConfig(
        type: SshProxyType.socks5,
        address: InternetAddress.loopbackIPv4.address,
        port: listener.port,
        username: '用戶',
      ),
      targetHost: '192.0.2.10',
      targetPort: 443,
      password: '密碼',
    );
    await tunnel.close();
    await serverDone.future.timeout(const Duration(seconds: 2));
  });

  test(
    'HTTP CONNECT validates status and preserves tunneled payload',
    () async {
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(listener.close);
      final serverDone = Completer<void>();
      listener.listen((socket) {
        unawaited(
          () async {
            final reader = _SocketReader(socket);
            final request = ascii.decode(
              await reader.readUntil([13, 10, 13, 10]),
            );
            expect(request, contains('CONNECT ssh.example:2222 HTTP/1.1\r\n'));
            expect(request, contains('Host: ssh.example:2222\r\n'));
            socket.add(
              ascii.encode('HTTP/1.1 200 Connection established\r\n\r\n') +
                  utf8.encode('SSH!'),
            );
            await socket.flush();
            serverDone.complete();
          }().catchError((Object error, StackTrace stackTrace) {
            serverDone.completeError(error, stackTrace);
            return null;
          }),
        );
      });

      final tunnel = await connectSshThroughProxy(
        proxy: SshProxyConfig(
          type: SshProxyType.httpConnect,
          address: InternetAddress.loopbackIPv4.address,
          port: listener.port,
        ),
        targetHost: 'ssh.example',
        targetPort: 2222,
      );
      addTearDown(tunnel.close);

      expect(await tunnel.stream.first, utf8.encode('SSH!'));
      await serverDone.future.timeout(const Duration(seconds: 2));
    },
  );

  test(
    'HTTP CONNECT sends Basic credentials and rejects non-200 responses',
    () async {
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(listener.close);
      final serverDone = Completer<void>();
      listener.listen((socket) {
        unawaited(
          () async {
            final request = ascii.decode(
              await _SocketReader(socket).readUntil([13, 10, 13, 10]),
            );
            expect(
              request,
              contains(
                'Proxy-Authorization: Basic ${base64Encode(utf8.encode('user:pass'))}\r\n',
              ),
            );
            socket.add(
              ascii.encode(
                'HTTP/1.1 407 Proxy Authentication Required\r\n\r\n',
              ),
            );
            await socket.flush();
            serverDone.complete();
          }().catchError((Object error, StackTrace stackTrace) {
            serverDone.completeError(error, stackTrace);
            return null;
          }),
        );
      });

      await expectLater(
        connectSshThroughProxy(
          proxy: SshProxyConfig(
            type: SshProxyType.httpConnect,
            address: InternetAddress.loopbackIPv4.address,
            port: listener.port,
            username: 'user',
          ),
          targetHost: 'ssh.example',
          targetPort: 22,
          password: 'pass',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('407'),
          ),
        ),
      );
      await serverDone.future.timeout(const Duration(seconds: 2));
    },
  );

  test('proxy profile validation and JSON omit passwords', () {
    final proxy = SshProxyConfig(
      type: SshProxyType.socks5,
      address: 'proxy.example',
      port: 1080,
      username: 'operator',
    );

    expect(proxy.validate(), isNull);
    expect(proxy.toJson().containsKey('password'), isFalse);
    expect(SshProxyConfig.fromJson(proxy.toJson()), proxy);
    expect(
      const SshProxyConfig(
        type: SshProxyType.httpConnect,
        address: 'proxy.example',
        port: 0,
      ).validate(),
      isNotNull,
    );
  });
}

class _SocketReader {
  _SocketReader(this.socket) : _iterator = StreamIterator<Uint8List>(socket);

  final Socket socket;
  final StreamIterator<Uint8List> _iterator;
  final List<int> _buffer = [];

  Future<Uint8List> readExactly(int length) async {
    while (_buffer.length < length) {
      if (!await _iterator.moveNext()) {
        throw const SocketException('unexpected socket EOF');
      }
      _buffer.addAll(_iterator.current);
    }
    final bytes = Uint8List.fromList(_buffer.take(length).toList());
    _buffer.removeRange(0, length);
    return bytes;
  }

  Future<Uint8List> readUntil(List<int> suffix) async {
    final output = BytesBuilder(copy: false);
    var matched = 0;
    while (output.length < 16384) {
      final byte = (await readExactly(1)).single;
      output.addByte(byte);
      if (byte == suffix[matched]) {
        matched++;
        if (matched == suffix.length) return output.takeBytes();
      } else {
        matched = byte == suffix.first ? 1 : 0;
      }
    }
    throw const FormatException('response header too large');
  }
}
