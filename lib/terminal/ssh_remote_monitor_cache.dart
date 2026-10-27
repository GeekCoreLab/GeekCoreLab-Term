import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import 'ssh_remote_monitor.dart';

/// Per-session monitor state shared by the terminal strip and detail dialog.
class SshRemoteMonitorCache extends ChangeNotifier {
  SshRemoteMonitorCache({this.monitor = const SshRemoteMonitor()});

  static const sampleInterval = Duration(seconds: 5);
  static const historyLimit = 24;

  final SshRemoteMonitor monitor;
  final List<SshRemoteMetrics> _history = [];

  SSHClient? _client;
  Timer? _timer;
  SshRemoteMetrics? _metrics;
  String? _error;
  bool _watching = false;
  bool _sampling = false;
  bool _disposed = false;
  int _generation = 0;
  int? _trafficBreakBeforeIndex;

  SshRemoteMetrics? get metrics => _metrics;
  String? get error => _error;
  bool get isSampling => _sampling;
  List<SshRemoteMetrics> get history => List.unmodifiable(_history);
  SshRemoteTrafficRate? get trafficRate {
    if (_history.length < 2) return null;
    if (_trafficBreakBeforeIndex == _history.length - 1) return null;
    return _history.last.trafficRateSince(_history[_history.length - 2]);
  }

  List<double?> get receiveRates =>
      _trafficRateHistory((rate) => rate?.receivedBytesPerSecond);

  List<double?> get transmitRates =>
      _trafficRateHistory((rate) => rate?.transmittedBytesPerSecond);

  List<double?> _trafficRateHistory(
    double? Function(SshRemoteTrafficRate?) select,
  ) => List<double?>.generate(_history.length, (index) {
    if (index == 0) return null;
    if (_trafficBreakBeforeIndex == index) return null;
    final rate = _history[index].trafficRateSince(_history[index - 1]);
    return select(rate);
  }, growable: false);

  /// Starts sampling while this session is shown in the monitor strip.
  void watch(SSHClient? client) {
    if (_disposed) return;
    if (client == null) {
      unwatch(_client);
      return;
    }
    if (identical(_client, client) && _watching) return;

    _timer?.cancel();
    _timer = null;
    if (!identical(_client, client)) {
      _generation++;
      _sampling = false;
      _client = client;
      _metrics = null;
      _error = null;
      _history.clear();
      _trafficBreakBeforeIndex = null;
    }

    _watching = true;
    _timer = Timer.periodic(sampleInterval, (_) => unawaited(refresh()));
    notifyListeners();
    unawaited(refresh());
  }

  /// Pauses sampling when another session becomes active, retaining its cache.
  void unwatch(SSHClient? client) {
    if (_disposed) return;
    if (!_watching || (client != null && !identical(_client, client))) return;
    _watching = false;
    _timer?.cancel();
    _timer = null;
    _generation++;
    _sampling = false;
    if (_history.isNotEmpty) _trafficBreakBeforeIndex = _history.length;
    notifyListeners();
  }

  Future<void> refresh() async {
    final client = _client;
    if (!_watching || client == null || _sampling || _disposed) return;
    if (client.isClosed) {
      _error = 'SSH 会话已断开';
      unwatch(client);
      return;
    }

    final generation = _generation;
    _sampling = true;
    notifyListeners();
    try {
      final metrics = await monitor.sample(client);
      if (generation != _generation || !identical(_client, client)) return;
      _metrics = metrics;
      _error = null;
      _history.add(metrics);
      if (_history.length > historyLimit) {
        _history.removeAt(0);
        final trafficBreak = _trafficBreakBeforeIndex;
        if (trafficBreak != null) {
          _trafficBreakBeforeIndex = trafficBreak == 0
              ? null
              : trafficBreak - 1;
        }
      }
    } catch (error) {
      if (generation != _generation || !identical(_client, client)) return;
      _error = error.toString().replaceFirst('Bad state: ', '');
    } finally {
      if (generation == _generation && !_disposed) {
        _sampling = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _timer?.cancel();
    _timer = null;
    _watching = false;
    super.dispose();
  }
}
