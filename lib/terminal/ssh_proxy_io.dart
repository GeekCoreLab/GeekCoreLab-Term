import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'ssh_proxy_config.dart';

Future<SSHSocket> connectSshThroughProxy({
  required SshProxyConfig proxy,
  required String targetHost,
  required int targetPort,
  String? password,
  required Duration timeout,
}) async {
  final proxyError = proxy.validate();
  if (proxyError != null) throw ArgumentError.value(proxy, 'proxy', proxyError);
  if (targetPort < 1 || targetPort > 65535) {
    throw ArgumentError.value(targetPort, 'targetPort', '端口范围为 1 到 65535');
  }
  final host = targetHost.trim();
  if (host.isEmpty || host.contains(RegExp(r'[\s/\\?#@\u0000-\u001f]'))) {
    throw ArgumentError.value(targetHost, 'targetHost', 'SSH 主机名无效');
  }

  final socket = await Socket.connect(
    proxy.address.trim(),
    proxy.port,
    timeout: timeout,
  );
  final tunnel = _ProxyTunnelSocket(socket);
  try {
    await (switch (proxy.type) {
      SshProxyType.socks5 => _negotiateSocks5(
        tunnel,
        proxy,
        host,
        targetPort,
        password,
      ),
      SshProxyType.httpConnect => _negotiateHttpConnect(
        tunnel,
        proxy,
        host,
        targetPort,
        password,
      ),
    }).timeout(timeout);
    tunnel.releaseToSsh();
    return tunnel;
  } on Object {
    tunnel.destroy();
    rethrow;
  }
}

Future<void> _negotiateSocks5(
  _ProxyTunnelSocket tunnel,
  SshProxyConfig proxy,
  String targetHost,
  int targetPort,
  String? password,
) async {
  final username = proxy.username;
  final hasUsername = username.isNotEmpty;
  final hasPassword = password != null && password.isNotEmpty;
  if (hasUsername != hasPassword) {
    throw const FormatException('SOCKS5 代理认证需要同时提供用户名和密码');
  }
  final methods = hasUsername ? const [0x00, 0x02] : const [0x00];
  tunnel.write([0x05, methods.length, ...methods]);
  final greeting = await tunnel.readExactly(2);
  if (greeting[0] != 0x05) {
    throw const FormatException('SOCKS5 代理返回了无效版本');
  }
  switch (greeting[1]) {
    case 0x00:
      break;
    case 0x02:
      if (!hasUsername || !hasPassword) {
        throw const FormatException('SOCKS5 代理要求用户名和密码');
      }
      final usernameBytes = utf8.encode(username);
      final passwordBytes = utf8.encode(password);
      if (usernameBytes.isEmpty ||
          usernameBytes.length > 255 ||
          passwordBytes.isEmpty ||
          passwordBytes.length > 255) {
        throw const FormatException('SOCKS5 用户名和密码长度必须为 1 到 255 字节');
      }
      tunnel.write([
        0x01,
        usernameBytes.length,
        ...usernameBytes,
        passwordBytes.length,
        ...passwordBytes,
      ]);
      final authentication = await tunnel.readExactly(2);
      if (authentication[0] != 0x01 || authentication[1] != 0x00) {
        throw const FormatException('SOCKS5 代理认证失败');
      }
      break;
    case 0xff:
      throw const FormatException('SOCKS5 代理不接受已配置的认证方式');
    default:
      throw const FormatException('SOCKS5 代理选择了不支持的认证方式');
  }

  final address = _socksAddress(targetHost);
  tunnel.write([
    0x05,
    0x01,
    0x00,
    ...address,
    targetPort >> 8,
    targetPort & 0xff,
  ]);
  final response = await tunnel.readExactly(4);
  if (response[0] != 0x05 || response[2] != 0x00) {
    throw const FormatException('SOCKS5 代理返回了无效连接响应');
  }
  if (response[1] != 0x00) {
    throw FormatException('SOCKS5 代理连接目标失败（状态 ${response[1]}）');
  }
  switch (response[3]) {
    case 0x01:
      await tunnel.readExactly(4);
      break;
    case 0x04:
      await tunnel.readExactly(16);
      break;
    case 0x03:
      final length = (await tunnel.readExactly(1))[0];
      if (length == 0) throw const FormatException('SOCKS5 响应域名为空');
      await tunnel.readExactly(length);
      break;
    default:
      throw const FormatException('SOCKS5 代理返回了未知地址类型');
  }
  await tunnel.readExactly(2);
}

List<int> _socksAddress(String host) {
  final normalized = host.startsWith('[') && host.endsWith(']')
      ? host.substring(1, host.length - 1)
      : host;
  final ip = InternetAddress.tryParse(normalized);
  if (ip != null) {
    if (ip.type == InternetAddressType.IPv4) {
      return [0x01, ...ip.rawAddress];
    }
    if (ip.type == InternetAddressType.IPv6) {
      return [0x04, ...ip.rawAddress];
    }
  }
  final domainBytes = utf8.encode(normalized);
  if (domainBytes.isEmpty ||
      domainBytes.length > 255 ||
      domainBytes.any((byte) => byte > 0x7f)) {
    throw const FormatException('SOCKS5 代理要求 ASCII 主机名；国际域名请先转换为 Punycode');
  }
  return [0x03, domainBytes.length, ...domainBytes];
}

Future<void> _negotiateHttpConnect(
  _ProxyTunnelSocket tunnel,
  SshProxyConfig proxy,
  String targetHost,
  int targetPort,
  String? password,
) async {
  final username = proxy.username;
  final hasUsername = username.isNotEmpty;
  final hasPassword = password != null && password.isNotEmpty;
  if (hasUsername != hasPassword) {
    throw const FormatException('HTTP 代理认证需要同时提供用户名和密码');
  }
  final authorityHost = _httpAuthorityHost(targetHost);
  final authority = '$authorityHost:$targetPort';
  final authorization = hasUsername
      ? 'Proxy-Authorization: Basic ${base64Encode(utf8.encode('$username:$password'))}\r\n'
      : '';
  final request =
      'CONNECT $authority HTTP/1.1\r\n'
      'Host: $authority\r\n'
      'Proxy-Connection: Keep-Alive\r\n'
      '$authorization\r\n';
  tunnel.write(ascii.encode(request));

  final header = BytesBuilder(copy: false);
  var matchedEnding = 0;
  const ending = [0x0d, 0x0a, 0x0d, 0x0a];
  while (header.length < 16384) {
    final byte = (await tunnel.readExactly(1))[0];
    header.addByte(byte);
    if (byte == ending[matchedEnding]) {
      matchedEnding++;
      if (matchedEnding == ending.length) break;
    } else {
      matchedEnding = byte == ending[0] ? 1 : 0;
    }
  }
  final bytes = header.takeBytes();
  if (bytes.length >= 16384 || matchedEnding != ending.length) {
    throw const FormatException('HTTP 代理响应头超过 16 KiB 或未结束');
  }
  final response = ascii.decode(bytes, allowInvalid: true);
  final statusLine = response.split('\r\n').firstOrNull ?? '';
  final parts = statusLine.split(RegExp(r'\s+'));
  final status = parts.length > 1 ? int.tryParse(parts[1]) : null;
  if (status == 407) throw const FormatException('HTTP 代理认证失败（407）');
  if ((parts.first != 'HTTP/1.0' && parts.first != 'HTTP/1.1') ||
      status != 200) {
    throw FormatException('HTTP 代理 CONNECT 失败：$statusLine');
  }
}

String _httpAuthorityHost(String host) {
  final normalized = host.startsWith('[') && host.endsWith(']')
      ? host.substring(1, host.length - 1)
      : host;
  final ip = InternetAddress.tryParse(normalized);
  if (ip?.type == InternetAddressType.IPv6) return '[$normalized]';
  if (normalized.codeUnits.any((unit) => unit > 0x7f)) {
    throw const FormatException('HTTP CONNECT 要求 ASCII 主机名；国际域名请先转换为 Punycode');
  }
  return normalized;
}

class _ProxyTunnelSocket implements SSHSocket {
  _ProxyTunnelSocket(this._socket) {
    _subscription = _socket.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: false,
    );
  }

  final Socket _socket;
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  final List<int> _pending = [];
  late final StreamSubscription<Uint8List> _subscription;
  Completer<void>? _changed;
  Object? _socketError;
  bool _handshaking = true;
  bool _socketDone = false;

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> get done => _socket.done;

  void write(List<int> bytes) {
    _socket.add(bytes);
  }

  Future<Uint8List> readExactly(int length) async {
    if (length < 0) throw RangeError.value(length, 'length');
    while (_pending.length < length) {
      if (_socketDone) {
        final error = _socketError;
        if (error != null) Error.throwWithStackTrace(error, StackTrace.current);
        throw const SocketException('代理在完成协商前关闭了连接');
      }
      final changed = _changed ??= Completer<void>();
      await changed.future;
    }
    final result = Uint8List.fromList(_pending.take(length).toList());
    _pending.removeRange(0, length);
    return result;
  }

  void releaseToSsh() {
    _handshaking = false;
    if (_pending.isNotEmpty) {
      _incoming.add(Uint8List.fromList(_pending));
      _pending.clear();
    }
    if (_socketDone && !_incoming.isClosed) unawaited(_incoming.close());
  }

  void _onData(Uint8List bytes) {
    if (_handshaking) {
      _pending.addAll(bytes);
      _notifyReader();
    } else if (!_incoming.isClosed) {
      _incoming.add(Uint8List.fromList(bytes));
    }
  }

  void _onError(Object error, StackTrace stackTrace) {
    _socketError = error;
    _socketDone = true;
    if (!_handshaking && !_incoming.isClosed) {
      _incoming.addError(error, stackTrace);
    }
    _notifyReader();
  }

  void _onDone() {
    _socketDone = true;
    _notifyReader();
    if (!_handshaking && !_incoming.isClosed) unawaited(_incoming.close());
  }

  void _notifyReader() {
    final changed = _changed;
    _changed = null;
    if (changed != null && !changed.isCompleted) changed.complete();
  }

  @override
  Future<void> close() async {
    _handshaking = false;
    await _socket.flush();
    await _subscription.cancel();
    await _socket.close();
    if (!_incoming.isClosed) unawaited(_incoming.close());
  }

  @override
  void destroy() {
    _socket.destroy();
    unawaited(_subscription.cancel());
    if (!_incoming.isClosed) unawaited(_incoming.close());
  }

  @override
  Future<void> flush() => _socket.flush();
}
