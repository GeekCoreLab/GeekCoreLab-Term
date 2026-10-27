import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'ssh_tunnel.dart' show SshTunnelHandle, SshTunnelSpec, SshTunnelType;

Future<SshTunnelHandle> startSshTunnel(
  SSHClient client,
  SshTunnelSpec spec,
) async {
  switch (spec.type) {
    case SshTunnelType.local:
      return _startLocalTunnel(client, spec);
    case SshTunnelType.remote:
      return _startRemoteTunnel(client, spec);
    case SshTunnelType.dynamic:
      final forward = await client.forwardDynamic(
        bindHost: spec.bindHost,
        bindPort: spec.bindPort,
      );
      return _IoSshTunnelHandle(
        spec: spec,
        boundHost: forward.host,
        boundPort: forward.port,
        close: forward.close,
        isClosed: () => forward.isClosed,
      );
  }
}

Future<SshTunnelHandle> _startLocalTunnel(
  SSHClient client,
  SshTunnelSpec spec,
) async {
  final server = await ServerSocket.bind(
    spec.bindHost,
    spec.bindPort,
    shared: false,
  );
  final bridges = <_SocketBridge>{};
  var closing = false;

  Future<void> accept(Socket socket) async {
    try {
      final channel = await client
          .forwardLocal(spec.targetHost, spec.targetPort)
          .timeout(const Duration(seconds: 15));
      if (closing) {
        socket.destroy();
        channel.destroy();
        return;
      }
      late final _SocketBridge bridge;
      bridge = _SocketBridge(
        socket,
        channel,
        onClosed: () => bridges.remove(bridge),
      );
      bridges.add(bridge);
    } catch (_) {
      socket.destroy();
    }
  }

  final subscription = server.listen((socket) => unawaited(accept(socket)));
  return _IoSshTunnelHandle(
    spec: spec,
    boundHost: server.address.address,
    boundPort: server.port,
    close: () async {
      closing = true;
      await subscription.cancel();
      await server.close();
      await Future.wait(bridges.toList().map((bridge) => bridge.close()));
    },
  );
}

Future<SshTunnelHandle> _startRemoteTunnel(
  SSHClient client,
  SshTunnelSpec spec,
) async {
  final forward = await client.forwardRemote(
    host: spec.bindHost,
    port: spec.bindPort,
    filter: (_, _) => true,
  );
  if (forward == null) {
    throw StateError('SSH 服务器拒绝了远程端口转发');
  }

  final bridges = <_SocketBridge>{};
  var closing = false;
  Future<void> accept(SSHForwardChannel channel) async {
    try {
      final socket = await Socket.connect(
        spec.targetHost,
        spec.targetPort,
        timeout: const Duration(seconds: 15),
      );
      if (closing) {
        socket.destroy();
        channel.destroy();
        return;
      }
      late final _SocketBridge bridge;
      bridge = _SocketBridge(
        socket,
        channel,
        onClosed: () => bridges.remove(bridge),
      );
      bridges.add(bridge);
    } catch (_) {
      channel.destroy();
    }
  }

  final subscription = forward.connections.listen(
    (channel) => unawaited(accept(channel)),
  );
  return _IoSshTunnelHandle(
    spec: spec,
    boundHost: forward.host.isEmpty ? '127.0.0.1' : forward.host,
    boundPort: forward.port,
    close: () async {
      closing = true;
      await subscription.cancel();
      await Future.wait(bridges.toList().map((bridge) => bridge.close()));
      try {
        await client.cancelForwardRemote(forward);
      } finally {
        forward.close();
      }
    },
  );
}

class _IoSshTunnelHandle implements SshTunnelHandle {
  _IoSshTunnelHandle({
    required this.spec,
    required this.boundHost,
    required this.boundPort,
    required Future<void> Function() close,
    bool Function()? isClosed,
  }) : _closeOperation = close,
       _isClosedOperation = isClosed;

  @override
  final SshTunnelSpec spec;

  @override
  final String boundHost;

  @override
  final int boundPort;

  final Future<void> Function() _closeOperation;
  final bool Function()? _isClosedOperation;
  bool _closed = false;

  @override
  bool get isClosed => _closed || (_isClosedOperation?.call() ?? false);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _closeOperation();
  }
}

class _SocketBridge {
  _SocketBridge(this._socket, this._channel, {required this.onClosed}) {
    _localSubscription = _socket.listen(
      _channel.sink.add,
      onError: (_) => unawaited(close()),
      onDone: () => unawaited(_closeChannelInput()),
      cancelOnError: true,
    );
    _remoteSubscription = _channel.stream.listen(
      _socket.add,
      onError: (_) => unawaited(close()),
      onDone: () => unawaited(close()),
      cancelOnError: true,
    );
    unawaited(_channel.done.then((_) => close()).catchError((_) => close()));
  }

  final Socket _socket;
  final SSHForwardChannel _channel;
  final void Function() onClosed;
  late final StreamSubscription<List<int>> _localSubscription;
  late final StreamSubscription<Uint8List> _remoteSubscription;
  bool _closed = false;

  Future<void> _closeChannelInput() async {
    try {
      await _channel.sink.close();
    } catch (_) {
      await close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await Future.wait([
      _localSubscription.cancel(),
      _remoteSubscription.cancel(),
    ]);
    _channel.destroy();
    _socket.destroy();
    onClosed();
  }
}
