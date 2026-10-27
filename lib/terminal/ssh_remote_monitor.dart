import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

const _monitorMarker = '__GEEKCORE_TERM_MONITOR_V1__';

/// A bounded, read-only snapshot from a Linux SSH host.
class SshRemoteMetrics {
  const SshRemoteMetrics({
    required this.sampledAt,
    this.load1,
    this.load5,
    this.load15,
    this.memoryTotalKiB,
    this.memoryAvailableKiB,
    this.diskTotalKiB,
    this.diskUsedKiB,
    this.diskAvailableKiB,
    this.diskPercent,
    this.processCount,
    this.networkReceivedBytes,
    this.networkTransmittedBytes,
    this.topProcesses = const [],
  });

  final DateTime sampledAt;
  final double? load1;
  final double? load5;
  final double? load15;
  final int? memoryTotalKiB;
  final int? memoryAvailableKiB;
  final int? diskTotalKiB;
  final int? diskUsedKiB;
  final int? diskAvailableKiB;
  final int? diskPercent;
  final int? processCount;
  final int? networkReceivedBytes;
  final int? networkTransmittedBytes;
  final List<SshRemoteProcessMetric> topProcesses;

  int? get memoryUsedKiB {
    final total = memoryTotalKiB;
    final available = memoryAvailableKiB;
    if (total == null || available == null) return null;
    return (total - available).clamp(0, total);
  }

  double? get memoryUsedPercent {
    final used = memoryUsedKiB;
    final total = memoryTotalKiB;
    if (used == null || total == null || total <= 0) return null;
    return used * 100 / total;
  }

  SshRemoteTrafficRate? trafficRateSince(SshRemoteMetrics previous) {
    final elapsedMicros = sampledAt
        .difference(previous.sampledAt)
        .inMicroseconds;
    if (elapsedMicros <= 0) return null;

    double? calculate(int? current, int? prior) {
      if (current == null || prior == null || current < prior) return null;
      return (current - prior) / elapsedMicros * Duration.microsecondsPerSecond;
    }

    final received = calculate(
      networkReceivedBytes,
      previous.networkReceivedBytes,
    );
    final transmitted = calculate(
      networkTransmittedBytes,
      previous.networkTransmittedBytes,
    );
    if (received == null && transmitted == null) return null;
    return SshRemoteTrafficRate(
      receivedBytesPerSecond: received,
      transmittedBytesPerSecond: transmitted,
    );
  }

  static SshRemoteMetrics parse(String output, {DateTime? sampledAt}) {
    final lines = const LineSplitter().convert(output);
    final markerIndex = lines.indexOf(_monitorMarker);
    if (markerIndex < 0) {
      throw const FormatException('远端监控响应格式无效');
    }

    double? load1;
    double? load5;
    double? load15;
    int? memoryTotal;
    int? memoryAvailable;
    int? diskTotal;
    int? diskUsed;
    int? diskAvailable;
    int? diskPercent;
    int? processCount;
    var networkReceivedBytes = 0;
    var networkTransmittedBytes = 0;
    var hasNetworkCounters = false;
    final processes = <SshRemoteProcessMetric>[];

    for (final line in lines.skip(markerIndex + 1)) {
      final fields = line.split('\t');
      if (fields.isEmpty) continue;
      switch (fields.first) {
        case 'UNSUPPORTED':
          throw const FormatException('远端主机未提供 Linux /proc 监控接口；当前监控只支持 Linux');
        case 'LOAD' when fields.length >= 4:
          load1 = double.tryParse(fields[1]);
          load5 = double.tryParse(fields[2]);
          load15 = double.tryParse(fields[3]);
        case 'MEM' when fields.length >= 3:
          memoryTotal = int.tryParse(fields[1]);
          memoryAvailable = int.tryParse(fields[2]);
        case 'DISK' when fields.length >= 5:
          diskTotal = int.tryParse(fields[1]);
          diskUsed = int.tryParse(fields[2]);
          diskAvailable = int.tryParse(fields[3]);
          diskPercent = int.tryParse(fields[4].replaceAll('%', ''));
        case 'COUNT' when fields.length >= 2:
          processCount = int.tryParse(fields[1]);
        case 'NET' when fields.length >= 4:
          if (fields[1] != 'lo') {
            final received = int.tryParse(fields[2]);
            final transmitted = int.tryParse(fields[3]);
            if (received != null && transmitted != null) {
              networkReceivedBytes += received;
              networkTransmittedBytes += transmitted;
              hasNetworkCounters = true;
            }
          }
        case 'PROC' when fields.length >= 5:
          final pid = int.tryParse(fields[1]);
          final cpu = double.tryParse(fields[2]);
          final memory = double.tryParse(fields[3]);
          if (pid != null && cpu != null && memory != null) {
            processes.add(
              SshRemoteProcessMetric(
                pid: pid,
                name: fields[4],
                cpuPercent: cpu,
                memoryPercent: memory,
              ),
            );
          }
      }
    }

    if (load1 == null &&
        memoryTotal == null &&
        diskTotal == null &&
        !hasNetworkCounters) {
      throw const FormatException('远端监控工具不可用或没有返回系统指标');
    }
    return SshRemoteMetrics(
      sampledAt: sampledAt ?? DateTime.now(),
      load1: load1,
      load5: load5,
      load15: load15,
      memoryTotalKiB: memoryTotal,
      memoryAvailableKiB: memoryAvailable,
      diskTotalKiB: diskTotal,
      diskUsedKiB: diskUsed,
      diskAvailableKiB: diskAvailable,
      diskPercent: diskPercent,
      processCount: processCount,
      networkReceivedBytes: hasNetworkCounters ? networkReceivedBytes : null,
      networkTransmittedBytes: hasNetworkCounters
          ? networkTransmittedBytes
          : null,
      topProcesses: List.unmodifiable(processes),
    );
  }
}

class SshRemoteTrafficRate {
  const SshRemoteTrafficRate({
    required this.receivedBytesPerSecond,
    required this.transmittedBytesPerSecond,
  });

  final double? receivedBytesPerSecond;
  final double? transmittedBytesPerSecond;
}

class SshRemoteProcessMetric {
  const SshRemoteProcessMetric({
    required this.pid,
    required this.name,
    required this.cpuPercent,
    required this.memoryPercent,
  });

  final int pid;
  final String name;
  final double cpuPercent;
  final double memoryPercent;
}

/// Collects bounded Linux metrics using a fixed read-only shell script.
class SshRemoteMonitor {
  const SshRemoteMonitor();

  static const networkCounterAwkProgram = r'''NR > 2 {
  separator = match($0, /:[[:space:]]+[0-9]/)
  if (!separator) next
  iface = substr($0, 1, RSTART - 1)
  countersText = substr($0, RSTART + 1)
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", iface)
  sub(/^[[:space:]]+/, "", countersText)
  split(countersText, counters, /[[:space:]]+/)
  if (iface != "lo") printf "NET\t%s\t%s\t%s\n", iface, counters[1], counters[9]
}''';

  static const _sampleCommandTemplate = r'''
if [ ! -r /proc/meminfo ] || [ ! -r /proc/loadavg ]; then
  printf '__GEEKCORE_TERM_MONITOR_V1__\n'
  printf 'UNSUPPORTED\tLinux /proc unavailable\n'
  exit 3
fi
printf '__GEEKCORE_TERM_MONITOR_V1__\n'
awk '/^MemTotal:/ { total = $2 } /^MemAvailable:/ { available = $2; seen = 1 } END { if (total > 0 && seen) printf "MEM\t%d\t%d\n", total, available }' /proc/meminfo
awk '{ printf "LOAD\t%s\t%s\t%s\n", $1, $2, $3 }' /proc/loadavg
df -Pk / 2>/dev/null | awk 'NR == 2 { print "DISK\t" $2 "\t" $3 "\t" $4 "\t" $5 }'
ps -eo pid=,pcpu=,pmem=,comm= --sort=-pcpu 2>/dev/null | awk '{ count++; if (count <= 5) printf "PROC\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4 } END { printf "COUNT\t%d\n", count }'
if [ -r /proc/net/dev ]; then
  awk '__GEEKCORE_TERM_NET_AWK__' /proc/net/dev 2>/dev/null
fi
''';

  static final sampleCommand = _sampleCommandTemplate.replaceAll(
    '__GEEKCORE_TERM_NET_AWK__',
    networkCounterAwkProgram,
  );

  Future<SshRemoteMetrics> sample(SSHClient client) async {
    if (client.isClosed) throw StateError('SSH 会话已断开');
    final result = await client
        .runWithResult(sampleCommand)
        .timeout(const Duration(seconds: 12));
    final stdout = utf8.decode(result.stdout, allowMalformed: true);
    final stderr = utf8.decode(result.stderr, allowMalformed: true).trim();
    if (stdout.contains('\nUNSUPPORTED\t')) {
      return SshRemoteMetrics.parse(stdout);
    }
    if (result.exitCode != null && result.exitCode != 0) {
      throw StateError(
        stderr.isEmpty ? '远端采集命令退出，状态码 ${result.exitCode}' : '远端采集失败：$stderr',
      );
    }
    return SshRemoteMetrics.parse(stdout);
  }
}
