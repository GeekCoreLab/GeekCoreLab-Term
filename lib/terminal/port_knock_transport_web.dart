import 'package:geekcore_term/terminal/websocket_ssh_socket.dart';

import 'session_store.dart';

Future<void> knockOnce(
  String host,
  PortKnockProtocol protocol,
  int port, {
  Uri? webSocketUri,
}) async {
  if (webSocketUri == null) {
    throw const FormatException('浏览器端口敲门需要配置 WebSocket SSH 网关');
  }
  final socket = await WebSocketSshSocket.connect(webSocketUri);
  socket.destroy();
}
