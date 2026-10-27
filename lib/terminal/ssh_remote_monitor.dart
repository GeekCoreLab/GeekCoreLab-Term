import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

const _monitorMarker = '__GEEKCORE_TERM_MONITOR_V1__';

enum SshRemotePlatform { linux, windows }

/// A bounded, read-only snapshot from a supported SSH host.
class SshRemoteMetrics {
  const SshRemoteMetrics({
    required this.sampledAt,
    this.platform = SshRemotePlatform.linux,
    this.load1,
    this.load5,
    this.load15,
    this.cpuPercent,
    this.memoryTotalKiB,
    this.memoryAvailableKiB,
    this.diskTotalKiB,
    this.diskUsedKiB,
    this.diskAvailableKiB,
    this.diskPercent,
    this.diskLabel,
    this.processCount,
    this.networkReceivedBytes,
    this.networkTransmittedBytes,
    this.topProcesses = const [],
  });

  final DateTime sampledAt;
  final SshRemotePlatform platform;
  final double? load1;
  final double? load5;
  final double? load15;
  final double? cpuPercent;
  final int? memoryTotalKiB;
  final int? memoryAvailableKiB;
  final int? diskTotalKiB;
  final int? diskUsedKiB;
  final int? diskAvailableKiB;
  final int? diskPercent;
  final String? diskLabel;
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
    double? cpuPercent;
    var platform = SshRemotePlatform.linux;
    int? memoryTotal;
    int? memoryAvailable;
    int? diskTotal;
    int? diskUsed;
    int? diskAvailable;
    int? diskPercent;
    String? diskLabel;
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
          throw const FormatException('远端主机未提供 Linux /proc 监控接口');
        case 'OS' when fields.length >= 2:
          platform = switch (fields[1].toLowerCase()) {
            'windows' => SshRemotePlatform.windows,
            _ => SshRemotePlatform.linux,
          };
        case 'LOAD' when fields.length >= 4:
          load1 = double.tryParse(fields[1]);
          load5 = double.tryParse(fields[2]);
          load15 = double.tryParse(fields[3]);
        case 'CPU' when fields.length >= 2:
          cpuPercent = double.tryParse(fields[1]);
        case 'MEM' when fields.length >= 3:
          memoryTotal = int.tryParse(fields[1]);
          memoryAvailable = int.tryParse(fields[2]);
        case 'DISK' when fields.length >= 6:
          diskLabel = fields[1];
          diskTotal = int.tryParse(fields[2]);
          diskUsed = int.tryParse(fields[3]);
          diskAvailable = int.tryParse(fields[4]);
          diskPercent = int.tryParse(fields[5].replaceAll('%', ''));
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
        cpuPercent == null &&
        memoryTotal == null &&
        diskTotal == null &&
        !hasNetworkCounters) {
      throw const FormatException('远端监控工具不可用或没有返回系统指标');
    }
    return SshRemoteMetrics(
      sampledAt: sampledAt ?? DateTime.now(),
      platform: platform,
      load1: load1,
      load5: load5,
      load15: load15,
      cpuPercent: cpuPercent,
      memoryTotalKiB: memoryTotal,
      memoryAvailableKiB: memoryAvailable,
      diskTotalKiB: diskTotal,
      diskUsedKiB: diskUsed,
      diskAvailableKiB: diskAvailable,
      diskPercent: diskPercent,
      diskLabel: diskLabel,
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

/// Collects bounded Linux or Windows metrics using fixed read-only scripts.
class SshRemoteMonitor {
  const SshRemoteMonitor();

  static const windowsProbeCommand =
      'cmd.exe /d /c echo __GEEKCORE_TERM_WINDOWS__';

  static final Expando<Future<SshRemotePlatform>> _platformByClient =
      Expando<Future<SshRemotePlatform>>('sshRemoteMonitorPlatform');

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

  static const windowsSampleScript = r'''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
Write-Output '__GEEKCORE_TERM_MONITOR_V1__'
Write-Output "OS`twindows"
$os = $null
try {
  $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
  $memoryTotalKiB = [int64]$os.TotalVisibleMemorySize
  $memoryAvailableKiB = [int64]$os.FreePhysicalMemory
  if ($memoryTotalKiB -gt 0 -and $memoryAvailableKiB -ge 0) {
    Write-Output ("MEM`t{0}`t{1}" -f $memoryTotalKiB, $memoryAvailableKiB)
  }
} catch {}
try {
  $systemDrive = [string]$env:SystemDrive
  $disk = Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop |
    Where-Object { $_.DeviceID -eq $systemDrive } | Select-Object -First 1
  if ($null -ne $disk -and [int64]$disk.Size -gt 0) {
    $totalKiB = [int64][Math]::Floor([double]$disk.Size / 1024)
    $freeKiB = [int64][Math]::Floor([double]$disk.FreeSpace / 1024)
    $usedKiB = [Math]::Max(0, $totalKiB - $freeKiB)
    $diskPercent = [int][Math]::Round($usedKiB * 100.0 / $totalKiB)
    Write-Output ("DISK`t{0}`t{1}`t{2}`t{3}`t{4}" -f $systemDrive, $totalKiB, $usedKiB, $freeKiB, $diskPercent)
  }
} catch {}
try {
  $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop |
    Measure-Object -Property LoadPercentage -Average
  if ($null -ne $cpu.Average) {
    $cpuText = ([double]$cpu.Average).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
    Write-Output ("CPU`t{0}" -f $cpuText)
  }
} catch {}
try {
  $processes = @(Get-Process -ErrorAction Stop)
  Write-Output ("COUNT`t{0}" -f $processes.Count)
} catch {}
try {
  if ($memoryTotalKiB -gt 0) {
    $topProcesses = @(Get-CimInstance -ClassName Win32_PerfFormattedData_PerfProc_Process -ErrorAction Stop |
      Where-Object { [int]$_.IDProcess -gt 0 } |
      Sort-Object -Property PercentProcessorTime -Descending |
      Select-Object -First 5)
    foreach ($process in $topProcesses) {
      $processId = [int]$process.IDProcess
      $cpuPercent = [Math]::Min(100.0, [double]$process.PercentProcessorTime / [Math]::Max(1, [Environment]::ProcessorCount))
      $memoryPercent = [double]$process.WorkingSetPrivate / ($memoryTotalKiB * 1024.0) * 100.0
      $cpuText = $cpuPercent.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
      $memoryText = $memoryPercent.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
      $name = ([string]$process.Name) -replace "[`r`n`t]", ' '
      Write-Output ("PROC`t{0}`t{1}`t{2}`t{3}" -f $processId, $cpuText, $memoryText, $name)
    }
  }
} catch {}
try {
  foreach ($adapter in @(Get-NetAdapterStatistics -ErrorAction Stop)) {
    $name = ([string]$adapter.Name) -replace "[`r`n`t]", ' '
    Write-Output ("NET`t{0}`t{1}`t{2}" -f $name, [uint64]$adapter.ReceivedBytes, [uint64]$adapter.SentBytes)
  }
} catch {}
''';

  static final String windowsSampleCommand =
      'powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand '
      '${_encodePowerShell(windowsSampleScript)}';

  static String _encodePowerShell(String script) {
    final units = script.codeUnits;
    final bytes = Uint8List(units.length * 2);
    for (var index = 0; index < units.length; index++) {
      bytes[index * 2] = units[index] & 0xff;
      bytes[index * 2 + 1] = (units[index] >> 8) & 0xff;
    }
    return base64Encode(bytes);
  }

  Future<SshRemoteMetrics> sample(SSHClient client) async {
    if (client.isClosed) throw StateError('SSH 会话已断开');
    var platformFuture = _platformByClient[client];
    if (platformFuture == null) {
      platformFuture = _detectPlatform(client);
      _platformByClient[client] = platformFuture;
    }
    final platform = await platformFuture;
    final command = platform == SshRemotePlatform.windows
        ? windowsSampleCommand
        : sampleCommand;
    final result = await _runWithTimeout(
      client,
      command,
      const Duration(seconds: 12),
    );
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

  Future<SshRemotePlatform> _detectPlatform(SSHClient client) async {
    final result = await _runWithTimeout(
      client,
      windowsProbeCommand,
      const Duration(seconds: 5),
    );
    final stdout = utf8.decode(result.stdout, allowMalformed: true);
    final hasWindowsMarker = const LineSplitter()
        .convert(stdout)
        .any((line) => line.trim() == '__GEEKCORE_TERM_WINDOWS__');
    return hasWindowsMarker
        ? SshRemotePlatform.windows
        : SshRemotePlatform.linux;
  }

  Future<SSHRunResult> _runWithTimeout(
    SSHClient client,
    String command,
    Duration timeout,
  ) async {
    final stopwatch = Stopwatch()..start();
    final sessionFuture = client.execute(command);
    late final SSHSession session;
    try {
      session = await sessionFuture.timeout(timeout);
    } on TimeoutException {
      unawaited(
        sessionFuture.then<void>(
          (lateSession) => lateSession.close(),
          onError: (Object _) {},
        ),
      );
      rethrow;
    }
    final remaining = timeout - stopwatch.elapsed;
    if (remaining <= Duration.zero) {
      session.close();
      throw TimeoutException('远端监控命令超时', timeout);
    }
    try {
      return await _collectSession(session).timeout(
        remaining,
        onTimeout: () {
          session.close();
          throw TimeoutException('远端监控命令超时', timeout);
        },
      );
    } catch (_) {
      session.close();
      rethrow;
    }
  }

  Future<SSHRunResult> _collectSession(SSHSession session) async {
    final stdoutFuture = _collectBytes(session.stdout);
    final stderrFuture = _collectBytes(session.stderr);
    final streams = await Future.wait<Uint8List>([
      stdoutFuture,
      stderrFuture,
    ], eagerError: true);
    await session.done;
    final combinedOutput = BytesBuilder(copy: false)
      ..add(streams[0])
      ..add(streams[1]);
    return SSHRunResult(
      output: combinedOutput.takeBytes(),
      stdout: streams[0],
      stderr: streams[1],
      exitCode: session.exitCode,
      exitSignal: session.exitSignal,
    );
  }

  Future<Uint8List> _collectBytes(Stream<Uint8List> stream) async {
    final output = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      output.add(chunk);
    }
    return output.takeBytes();
  }
}
