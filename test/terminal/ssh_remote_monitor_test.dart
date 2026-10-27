import 'dart:io';
import 'dart:convert';

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
NET\teth0\t1000\t2000
NET\twlan0\t300\t500
NET\tlo\t9000\t12000
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
      expect(metrics.networkReceivedBytes, 1300);
      expect(metrics.networkTransmittedBytes, 2500);
      expect(metrics.processCount, 42);
      expect(metrics.topProcesses, hasLength(2));
      expect(metrics.topProcesses.first.pid, 123);
      expect(metrics.topProcesses.first.name, 'sshd');
      expect(metrics.topProcesses.first.cpuPercent, 12.5);
    });

    test('parses Windows CPU, memory, system drive and adapter counters', () {
      final sampledAt = DateTime.utc(2026, 10, 27, 6, 0);
      final metrics = SshRemoteMetrics.parse('''
__GEEKCORE_TERM_MONITOR_V1__
OS\twindows
CPU\t12.5
MEM\t16000000\t4000000
DISK\tC:\\\t1000000\t700000\t300000\t70
NET\tEthernet\t4000\t6000
PROC\t1234\t8.5\t1.2\tsshd
COUNT\t128
''', sampledAt: sampledAt);

      expect(metrics.platform, SshRemotePlatform.windows);
      expect(metrics.sampledAt, sampledAt);
      expect(metrics.load1, isNull);
      expect(metrics.cpuPercent, 12.5);
      expect(metrics.memoryUsedPercent, 75);
      expect(metrics.diskLabel, r'C:\');
      expect(metrics.diskTotalKiB, 1000000);
      expect(metrics.diskUsedKiB, 700000);
      expect(metrics.diskAvailableKiB, 300000);
      expect(metrics.diskPercent, 70);
      expect(metrics.networkReceivedBytes, 4000);
      expect(metrics.networkTransmittedBytes, 6000);
      expect(metrics.processCount, 128);
      expect(metrics.topProcesses.single.name, 'sshd');
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
            contains('Linux /proc'),
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

  group('SshRemoteMetrics.trafficRateSince', () {
    final start = DateTime.utc(2026, 10, 26, 17, 0);

    test('calculates actual RX/TX rates from adjacent counter snapshots', () {
      final previous = SshRemoteMetrics(
        sampledAt: start,
        networkReceivedBytes: 10_000,
        networkTransmittedBytes: 20_000,
      );
      final current = SshRemoteMetrics(
        sampledAt: start.add(const Duration(seconds: 5)),
        networkReceivedBytes: 15_000,
        networkTransmittedBytes: 30_000,
      );

      final rate = current.trafficRateSince(previous);
      expect(rate?.receivedBytesPerSecond, 1000);
      expect(rate?.transmittedBytesPerSecond, 2000);
    });

    test('handles counter reset and invalid sample intervals', () {
      final previous = SshRemoteMetrics(
        sampledAt: start,
        networkReceivedBytes: 10_000,
        networkTransmittedBytes: 20_000,
      );
      final reset = SshRemoteMetrics(
        sampledAt: start.add(const Duration(seconds: 5)),
        networkReceivedBytes: 100,
        networkTransmittedBytes: 30_000,
      );
      final rate = reset.trafficRateSince(previous);
      expect(rate?.receivedBytesPerSecond, isNull);
      expect(rate?.transmittedBytesPerSecond, 2000);

      final sameTime = SshRemoteMetrics(
        sampledAt: start,
        networkReceivedBytes: 15_000,
        networkTransmittedBytes: 30_000,
      );
      expect(sameTime.trafficRateSince(previous), isNull);
    });
  });

  test('collector command reads system state without mutating it', () {
    final command = SshRemoteMonitor.sampleCommand;
    expect(command, contains('/proc/meminfo'));
    expect(command, contains('/proc/loadavg'));
    expect(command, contains('df -Pk /'));
    expect(command, contains('ps -eo'));
    expect(command, contains('/proc/net/dev'));
    expect(command, isNot(contains('sudo')));
    expect(command, isNot(contains('rm ')));
    expect(command, isNot(contains('kill ')));
    expect(command, isNot(contains('systemctl')));
  });

  test('Windows collector is a fixed encoded read-only PowerShell script', () {
    expect(SshRemoteMonitor.windowsProbeCommand, isNot(contains('\n')));
    expect(
      SshRemoteMonitor.windowsProbeCommand,
      contains('cmd.exe /d /c echo'),
    );
    expect(SshRemoteMonitor.windowsSampleCommand.length, lessThan(8000));

    final match = RegExp(
      r'-EncodedCommand ([A-Za-z0-9+/=]+)$',
    ).firstMatch(SshRemoteMonitor.windowsSampleCommand);
    expect(match, isNotNull);
    final bytes = base64Decode(match!.group(1)!);
    expect(bytes.length.isEven, isTrue);
    final units = <int>[];
    for (var index = 0; index < bytes.length; index += 2) {
      units.add(bytes[index] | (bytes[index + 1] << 8));
    }
    final script = String.fromCharCodes(units);

    expect(
      script,
      contains('Get-CimInstance -ClassName Win32_OperatingSystem'),
    );
    expect(script, contains('Get-NetAdapterStatistics'));
    expect(script, contains('Win32_PerfFormattedData_PerfProc_Process'));
    expect(script, isNot(contains('Stop-Process')));
    expect(script, isNot(contains('Remove-Item')));
    expect(script, isNot(contains('Set-Service')));
    expect(script, isNot(contains('Invoke-Expression')));
  });

  test(
    'network counter parser handles aliases and excludes loopback',
    () async {
      if (!Platform.isLinux) return;
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'geekcore-monitor-network-',
      );
      try {
        final fixture = File('${temporaryDirectory.path}/net-dev')
          ..writeAsStringSync('''Inter-| Receive | Transmit
 face |bytes packets errs drop fifo frame compressed multicast|bytes packets errs drop fifo colls carrier compressed
 eth0:1: 100 1 0 0 0 0 0 0 200 2 0 0 0 0 0 0
 wlan0: 300 3 0 0 0 0 0 0 400 4 0 0 0 0 0 0
 lo: 900 9 0 0 0 0 0 0 900 9 0 0 0 0 0 0
''');
        final result = await Process.run('awk', [
          SshRemoteMonitor.networkCounterAwkProgram,
          fixture.path,
        ]);

        expect(result.exitCode, 0, reason: result.stderr.toString());
        expect(
          result.stdout.toString(),
          'NET\teth0:1\t100\t200\nNET\twlan0\t300\t400\n',
        );
      } finally {
        await temporaryDirectory.delete(recursive: true);
      }
    },
  );

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
