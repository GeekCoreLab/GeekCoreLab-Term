import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/ssh_jump_port_knock.dart';
import 'package:geekcore_term/terminal/session_store.dart';

void main() {
  test('allows TCP knocks and delays through an SSH jump', () {
    expect(
      canRunPortKnockActionsViaSshJump([
        const PortKnockAction.delay(100),
        const PortKnockAction.knock(22),
      ]),
      isTrue,
    );
  });

  test('rejects UDP and ICMP knocks through an SSH jump', () {
    for (final protocol in [PortKnockProtocol.udp, PortKnockProtocol.icmp]) {
      expect(
        canRunPortKnockActionsViaSshJump([
          PortKnockAction.knock(22, protocol: protocol),
        ]),
        isFalse,
      );
    }
  });

  test('closes a forwarded TCP channel immediately after opening', () async {
    final channel = _FakeChannel();

    await knockTcpThroughSshJump<_FakeChannel>(
      openChannel: () async => channel,
      closeChannel: (channel) {
        channel.closed = true;
      },
    );

    expect(channel.closed, isTrue);
  });

  test('treats a remote connection refusal as a completed knock', () async {
    await expectLater(
      knockTcpThroughSshJump<void>(
        openChannel: () async => throw SSHChannelOpenError(2, 'refused'),
        closeChannel: (_) => fail('no channel exists after refusal'),
      ),
      completes,
    );
  });

  test('does not hide SSH forwarding policy failures', () async {
    await expectLater(
      knockTcpThroughSshJump<void>(
        openChannel: () async => throw SSHChannelOpenError(1, 'prohibited'),
        closeChannel: (_) => fail('no channel exists after rejection'),
      ),
      throwsA(isA<SSHChannelOpenError>()),
    );
  });

  test('closes a channel if it arrives after the knock timed out', () async {
    final pending = Completer<_FakeChannel>();
    final channel = _FakeChannel();

    await expectLater(
      knockTcpThroughSshJump<_FakeChannel>(
        openChannel: () => pending.future,
        closeChannel: (channel) {
          channel.closed = true;
        },
        timeout: const Duration(milliseconds: 1),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(channel.closed, isFalse);

    pending.complete(channel);
    await Future<void>.delayed(Duration.zero);
    expect(channel.closed, isTrue);
  });
}

class _FakeChannel {
  bool closed = false;
}
