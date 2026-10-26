import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class WebSocketSshSocket implements SSHSocket {
  WebSocketSshSocket._(this._channel) {
    _channel.stream.listen(
      _handleFrame,
      onError: (Object error, StackTrace stackTrace) {
        _input.addError(error, stackTrace);
        if (!_done.isCompleted) _done.completeError(error, stackTrace);
      },
      onDone: () {
        if (!_input.isClosed) unawaited(_input.close());
        if (!_done.isCompleted) _done.complete();
      },
    );
    _output.stream.listen(
      (data) => _channel.sink.add(Uint8List.fromList(data)),
      onError: (Object error, StackTrace stackTrace) {
        if (!_done.isCompleted) _done.completeError(error, stackTrace);
      },
      onDone: () => unawaited(_channel.sink.close()),
    );
  }

  final WebSocketChannel _channel;
  final StreamController<Uint8List> _input = StreamController<Uint8List>();
  final StreamController<List<int>> _output = StreamController<List<int>>();
  final Completer<void> _done = Completer<void>();

  static Future<WebSocketSshSocket> connect(Uri uri) async {
    final channel = WebSocketChannel.connect(uri);
    await channel.ready.timeout(const Duration(seconds: 15));
    return WebSocketSshSocket._(channel);
  }

  @override
  Stream<Uint8List> get stream => _input.stream;

  @override
  StreamSink<List<int>> get sink => _output.sink;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    await _output.close();
    await done;
  }

  @override
  void destroy() {
    unawaited(_channel.sink.close());
    if (!_input.isClosed) unawaited(_input.close());
    if (!_output.isClosed) unawaited(_output.close());
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> flush() async {}

  void _handleFrame(Object? frame) {
    if (frame is Uint8List) {
      _input.add(frame);
    } else if (frame is List<int>) {
      _input.add(Uint8List.fromList(frame));
    } else if (frame is ByteBuffer) {
      _input.add(frame.asUint8List());
    } else {
      _input.addError(const FormatException('SSH WebSocket 网关必须发送二进制数据帧'));
    }
  }
}
