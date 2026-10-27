import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/ssh_remote_monitor.dart';

void main() {
  group('SshRemoteMetrics.parse', () {
    test('parses Linux load, memory, disk and top process rows', () {
      final sampledAt = DateTime.utc(2026, 10, 26, 17, 0);
      final metrics = SshRemoteMetrics.parse('''login banner
__GEEKCORE_TERM_MONITOR_V1__
MEM\t8000000\t2000000
LOAD\t0.25\t0.40\t0.60
DISK\t1000000\t400000\t600000\t40%
PROC\t123\t12.5\t3.2\tsshd
PROC\t456\t1.0\t0.5\tworker
COUNT\t42
''', sampledAt: sampledAt);

      expect(metrics.sampledAt, sampledAt);
      expect(metrics.load1, 0.25);
      expect(metrics.load5, 0.4);
      expect(metrics.load15, 0.6);
      expect(metrics.memoryTotalKiB, 8000000);
      expect(metrics.memoryAvailableKiB, 2000000);
      expect(metrics.memoryUsedKiB, 6000000);
      expect(metrics.memoryUsedPercent, 75);
      expect(metrics.diskTotalKiB, 1000000);
      expect(metrics.diskUsedKiB, 400000);
      expect(metrics.diskAvailableKiB, 600000);
      expect(metrics.diskPercent, 40);
      expect(metrics.processCount, 42);
      expect(metrics.topProcesses, hasLength(2));
      expect(metrics.topProcesses.first.pid, 123);
      expect(metrics.topProcesses.first.name, 'sshd');
      expect(metrics.topProcesses.first.cpuPercent, 12.5);
    });

    test('rejects unsupported hosts with an actionable message', () {
      expect(
        () => SshRemoteMetrics.parse(
          '__GEEKCORE_TERM_MONITOR_V1__\nUNSUPPORTED\tno proc\n',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('只支持 Linux'),
          ),
        ),
      );
    });

    test('rejects responses without the protocol marker or usable metrics', () {
      expect(
        () => SshRemoteMetrics.parse('login banner only'),
        throwsFormatException,
      );
      expect(
        () => SshRemoteMetrics.parse('__GEEKCORE_TERM_MONITOR_V1__\n'),
        throwsFormatException,
      );
    });
  });

  test('collector command reads system state without mutating it', () {
    final command = SshRemoteMonitor.sampleCommand;
    expect(command, contains('/proc/meminfo'));
    expect(command, contains('/proc/loadavg'));
    expect(command, contains('df -Pk /'));
    expect(command, contains('ps -eo'));
    expect(command, isNot(contains('sudo')));
    expect(command, isNot(contains('rm ')));
    expect(command, isNot(contains('kill ')));
    expect(command, isNot(contains('systemctl')));
  });

  test(
    'fixed collector script runs on Linux and returns live metrics',
    () async {
      if (!Platform.isLinux) return;
      final result = await Process.run('/bin/sh', [
        '-c',
        SshRemoteMonitor.sampleCommand,
      ]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final metrics = SshRemoteMetrics.parse(result.stdout.toString());
      expect(metrics.load1, isNotNull);
      expect(metrics.memoryTotalKiB, greaterThan(0));
      expect(metrics.diskTotalKiB, greaterThan(0));
      expect(metrics.processCount, greaterThan(0));
    },
  );
}
