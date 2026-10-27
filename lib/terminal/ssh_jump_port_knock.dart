import 'dart:async';

import 'package:dartssh2/dartssh2.dart';

const _sshOpenConnectFailed = 2;

/// Opens and immediately closes a TCP channel through an authenticated SSH
/// jump host. A remote connect refusal still counts as a sent knock, matching
/// the direct TCP knock behavior.
Future<void> knockTcpThroughSshJump<T>({
  required Future<T> Function() openChannel,
  required FutureOr<void> Function(T channel) closeChannel,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final channelFuture = openChannel();
  try {
    final channel = await channelFuture.timeout(timeout);
    await closeChannel(channel);
  } on SSHChannelOpenError catch (error) {
    if (error.code != _sshOpenConnectFailed) rethrow;
  } on TimeoutException {
    unawaited(
      channelFuture.then<void>((channel) async {
        try {
          await closeChannel(channel);
        } catch (_) {
          // The jump client may have closed while the channel was pending.
        }
      }, onError: (Object _) {}),
    );
    rethrow;
  }
}
