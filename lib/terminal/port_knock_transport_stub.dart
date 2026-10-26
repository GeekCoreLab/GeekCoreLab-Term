import 'session_store.dart';

Future<void> knockOnce(
  String host,
  PortKnockProtocol protocol,
  int port, {
  Uri? webSocketUri,
}) async {
  throw UnsupportedError('当前平台不支持端口敲门');
}
