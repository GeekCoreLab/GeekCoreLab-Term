import 'session_store.dart';

import 'port_knock_transport_stub.dart'
    if (dart.library.io) 'port_knock_transport_io.dart'
    if (dart.library.js_interop) 'port_knock_transport_web.dart'
    as platform;

Future<void> knockOnce(
  String host,
  PortKnockProtocol protocol,
  int port, {
  Uri? webSocketUri,
}) => platform.knockOnce(host, protocol, port, webSocketUri: webSocketUri);
