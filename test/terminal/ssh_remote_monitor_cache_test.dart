import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/ssh_remote_monitor.dart';
import 'package:geekcore_term/terminal/ssh_remote_monitor_cache.dart';

void main() {
  test(
    'pause drops in-flight samples and resets the next traffic rate',
    () async {
      final socket = _FakeSshSocket();
      final client = SSHClient(
        socket,
        username: 'monitor-test',
        disableHostkeyVerification: true,
      );
      final pendingSamples = [
        Completer<SshRemoteMetrics>(),
        Completer<SshRemoteMetrics>(),
        Completer<SshRemoteMetrics>(),
      ];
      final cache = SshRemoteMonitorCache(
        monitor: _FakeMonitor(pendingSamples),
      );

      try {
        cache.watch(client);
        expect(cache.isSampling, isTrue);
        cache.unwatch(client);
        expect(cache.isSampling, isFalse);

        pendingSamples[0].complete(_metrics(DateTime.utc(2026), 100, 200));
        await _settleAsyncWork();
        expect(cache.history, isEmpty);

        cache.watch(client);
        pendingSamples[1].complete(
          _metrics(DateTime.utc(2026, 10, 27, 4), 1000, 2000),
        );
        await _settleAsyncWork();
        expect(cache.history, hasLength(1));
        expect(cache.trafficRate, isNull);

        unawaited(cache.refresh());
        pendingSamples[2].complete(
          _metrics(DateTime.utc(2026, 10, 27, 4, 0, 5), 1500, 3000),
        );
        await _settleAsyncWork();
        expect(cache.trafficRate?.receivedBytesPerSecond, 100);
        expect(cache.trafficRate?.transmittedBytesPerSecond, 200);
      } finally {
        cache.dispose();
        await client.close();
      }
    },
  );
}

SshRemoteMetrics _metrics(DateTime sampledAt, int received, int transmitted) =>
    SshRemoteMetrics(
      sampledAt: sampledAt,
      networkReceivedBytes: received,
      networkTransmittedBytes: transmitted,
    );

Future<void> _settleAsyncWork() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class _FakeMonitor implements SshRemoteMonitor {
  _FakeMonitor(this.pendingSamples);

  final List<Completer<SshRemoteMetrics>> pendingSamples;
  var _nextSample = 0;

  @override
  Future<SshRemoteMetrics> sample(SSHClient client) =>
      pendingSamples[_nextSample++].future;
}

class _FakeSshSocket implements SSHSocket {
  _FakeSshSocket() {
    _outgoing.stream.listen((_) {});
  }

  final StreamController<Uint8List> _incoming = StreamController();
  final StreamController<List<int>> _outgoing = StreamController();
  final Completer<void> _done = Completer<void>();

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  StreamSink<List<int>> get sink => _outgoing.sink;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    if (!_incoming.isClosed) await _incoming.close();
    if (!_outgoing.isClosed) await _outgoing.close();
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void destroy() {
    unawaited(close());
  }
}
