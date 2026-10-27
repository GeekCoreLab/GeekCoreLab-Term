import 'package:flutter/material.dart';

/// Represents a parsed disk filesystem entry from `df -h`
class DfFsEntry {
  const DfFsEntry({
    required this.filesystem,
    required this.size,
    required this.used,
    required this.avail,
    required this.usePercent,
    required this.mountedOn,
  });

  final String filesystem;
  final String size;
  final String used;
  final String avail;
  final double usePercent; // 0.0 - 1.0
  final String mountedOn;
}

/// Represents memory statistics from `free -h` or `free -m`
class FreeMemStats {
  const FreeMemStats({
    required this.totalMem,
    required this.usedMem,
    required this.freeMem,
    this.sharedMem = '',
    this.buffCacheMem = '',
    this.availableMem = '',
    this.totalSwap = '',
    this.usedSwap = '',
    this.freeSwap = '',
  });

  final String totalMem;
  final String usedMem;
  final String freeMem;
  final String sharedMem;
  final String buffCacheMem;
  final String availableMem;
  final String totalSwap;
  final String usedSwap;
  final String freeSwap;

  double get memUsageRatio {
    final t = _parseBytes(totalMem);
    final u = _parseBytes(usedMem);
    if (t > 0) return (u / t).clamp(0.0, 1.0);
    return 0.0;
  }

  double get swapUsageRatio {
    final t = _parseBytes(totalSwap);
    final u = _parseBytes(usedSwap);
    if (t > 0) return (u / t).clamp(0.0, 1.0);
    return 0.0;
  }

  static double _parseBytes(String s) {
    if (s.isEmpty) return 0;
    final clean = s.trim().replaceAll(',', '.');
    final match = RegExp(r'^([\d.]+)\s*([KMGTPEkmgtpe]i?B?|[B|b])?').firstMatch(clean);
    if (match == null) return 0;
    final val = double.tryParse(match.group(1) ?? '') ?? 0;
    final unit = (match.group(2) ?? '').toUpperCase();
    if (unit.startsWith('K')) return val * 1024;
    if (unit.startsWith('M')) return val * 1024 * 1024;
    if (unit.startsWith('G')) return val * 1024 * 1024 * 1024;
    if (unit.startsWith('T')) return val * 1024 * 1024 * 1024 * 1024;
    if (unit.startsWith('P')) return val * 1024 * 1024 * 1024 * 1024 * 1024;
    return val;
  }
}

/// Kind of command recognized for GUI chart rendering
enum CommandChartType {
  df,
  free,
  dockerPs,
}

/// Represents a parsed container entry from `docker ps`
class DockerContainerEntry {
  const DockerContainerEntry({
    required this.containerId,
    required this.image,
    required this.command,
    required this.created,
    required this.status,
    required this.ports,
    required this.names,
  });

  final String containerId;
  final String image;
  final String command;
  final String created;
  final String status;
  final String ports;
  final String names;

  bool get isRunning => status.toLowerCase().startsWith('up');
}

/// A captured command block with its range in terminal buffer lines and parsed data
class CapturedCommandBlock {
  CapturedCommandBlock({
    required this.id,
    required this.command,
    required this.type,
    required this.startBufferLine,
    required this.endBufferLine,
    required this.rawOutput,
    this.dfEntries = const [],
    this.freeStats,
    this.dockerEntries = const [],
  });

  final String id;
  final String command;
  final CommandChartType type;
  final int startBufferLine;
  int endBufferLine;
  final String rawOutput;
  final List<DfFsEntry> dfEntries;
  final FreeMemStats? freeStats;
  final List<DockerContainerEntry> dockerEntries;

  bool isRenderMode = true;
}

/// Parser for terminal commands and outputs to build GUI charts
class TerminalCommandChartParser {
  static final RegExp _dfHeaderRegex = RegExp(
    r'(?:Filesystem|文件系统)\s+(?:Size|1K-blocks|1M-blocks|1G-blocks|大小|容量)\s+(?:Used|已用)\s+(?:Avail(?:able)?|可用)\s+(?:Use%|已用%|Capacity)\s+(?:Mounted\s+on|挂载点)',
    caseSensitive: false,
  );

  static final RegExp _freeHeaderRegex = RegExp(
    r'(?:\btotal\s+used\s+free\s+shared\s+(?:buff/cache|buffers\s+cached)\s+available\b|总计\s+已用\s+空闲\s+共享\s+缓冲/缓存\s+可用)',
    caseSensitive: false,
  );

  static final RegExp _dockerHeaderRegex = RegExp(
    r'CONTAINER\s+ID\s+IMAGE\s+COMMAND\s+CREATED\s+STATUS\s+PORTS\s+NAMES',
    caseSensitive: false,
  );

  /// Tests if a command is candidate for chart capture (e.g. `df -h`, `free -h`, `docker ps`)
  static CommandChartType? matchCommandType(String commandLine) {
    var clean = _stripAnsi(commandLine).trim();
    // Strip leading sudo if present
    if (clean.toLowerCase().startsWith('sudo ')) {
      clean = clean.substring(5).trimLeft();
    }
    final lower = clean.toLowerCase();
    if (lower == 'df' ||
        lower.startsWith('df ') ||
        lower.startsWith('df\t')) {
      return CommandChartType.df;
    }
    if (lower == 'free' ||
        lower.startsWith('free ') ||
        lower.startsWith('free\t')) {
      return CommandChartType.free;
    }
    if (lower == 'docker ps' ||
        lower.startsWith('docker ps ') ||
        lower.startsWith('docker ps\t') ||
        lower == 'docker container ls' ||
        lower.startsWith('docker container ls ') ||
        lower.startsWith('docker container ls\t')) {
      return CommandChartType.dockerPs;
    }
    return null;
  }

  /// Parses raw output lines of `df`
  static List<DfFsEntry> parseDf(String text) {
    final lines = text.split(RegExp(r'\r?\n'));
    final results = <DfFsEntry>[];
    var headerFound = false;

    for (final rawLine in lines) {
      final line = _stripAnsi(rawLine).trim();
      if (line.isEmpty) continue;

      if (!headerFound) {
        if (_dfHeaderRegex.hasMatch(line) ||
            (line.contains('Filesystem') && line.contains('Use%')) ||
            (line.contains('文件系统') && line.contains('%'))) {
          headerFound = true;
        }
        continue;
      }

      final parts = line.split(RegExp(r'\s+'));
      // Find the token that ends with '%' (e.g. '48%' or '0%')
      var pctIndex = -1;
      for (var i = 0; i < parts.length; i++) {
        if (RegExp(r'^\d+%$').hasMatch(parts[i])) {
          pctIndex = i;
          break;
        }
      }

      if (pctIndex >= 3 && pctIndex + 1 < parts.length) {
        // Standard row: [fs..., size, used, avail, use%, mountedOn...]
        // Or when fs is empty: [size, used, avail, use%, mountedOn...]
        final size = parts[pctIndex - 3];
        final used = parts[pctIndex - 2];
        final avail = parts[pctIndex - 1];
        final fs = pctIndex >= 4 ? parts.sublist(0, pctIndex - 3).join(' ') : 'tmpfs';
        final usePercentStr = parts[pctIndex].replaceAll('%', '');
        final usePercent = (double.tryParse(usePercentStr) ?? 0) / 100.0;
        final mountedOn = parts.sublist(pctIndex + 1).join(' ');
        results.add(DfFsEntry(
          filesystem: fs,
          size: size,
          used: used,
          avail: avail,
          usePercent: usePercent.clamp(0.0, 1.0),
          mountedOn: mountedOn,
        ));
      }
    }
    return results;
  }

  /// Parses raw output lines of `free`
  static FreeMemStats? parseFree(String text) {
    final lines = text.split(RegExp(r'\r?\n'));
    String? totalMem, usedMem, freeMem, sharedMem, buffCacheMem, availableMem;
    String? totalSwap, usedSwap, freeSwap;

    for (final rawLine in lines) {
      final line = _stripAnsi(rawLine).trim();
      if (line.isEmpty) continue;

      final parts = line.split(RegExp(r'\s+'));
      if (parts.isEmpty) continue;

      final rowName = parts[0].replaceAll(':', '').replaceAll('：', '').toLowerCase();
      if (rowName == 'mem' || rowName == '内存') {
        if (parts.length >= 4) {
          totalMem = parts[1];
          usedMem = parts[2];
          freeMem = parts[3];
        }
        if (parts.length >= 5) sharedMem = parts[4];
        if (parts.length >= 6) buffCacheMem = parts[5];
        if (parts.length >= 7) availableMem = parts[6];
      } else if (rowName == 'swap' || rowName == '交换' || rowName == '交换空间') {
        if (parts.length >= 4) {
          totalSwap = parts[1];
          usedSwap = parts[2];
          freeSwap = parts[3];
        }
      }
    }

    if (totalMem != null && usedMem != null && freeMem != null) {
      return FreeMemStats(
        totalMem: totalMem,
        usedMem: usedMem,
        freeMem: freeMem,
        sharedMem: sharedMem ?? '',
        buffCacheMem: buffCacheMem ?? '',
        availableMem: availableMem ?? '',
        totalSwap: totalSwap ?? '',
        usedSwap: usedSwap ?? '',
        freeSwap: freeSwap ?? '',
      );
    }
    return null;
  }

  /// Tests if a line of output is the table header of a chartable command
  static CommandChartType? detectOutputHeader(String line) {
    final clean = _stripAnsi(line).trim();
    if (clean.isEmpty) return null;
    if (_freeHeaderRegex.hasMatch(clean)) {
      return CommandChartType.free;
    }
    if (_dfHeaderRegex.hasMatch(clean) ||
        (clean.contains('Filesystem') && clean.contains('Use%')) ||
        (clean.contains('文件系统') && clean.contains('已用%') && clean.contains('挂载点'))) {
      return CommandChartType.df;
    }
    if (_dockerHeaderRegex.hasMatch(clean) ||
        (clean.contains('CONTAINER ID') && clean.contains('IMAGE') && clean.contains('STATUS'))) {
      return CommandChartType.dockerPs;
    }
    return null;
  }

  /// Parses raw output lines of `docker ps`
  static List<DockerContainerEntry> parseDockerPs(String text) {
    final lines = text.split(RegExp(r'\r?\n'));
    final results = <DockerContainerEntry>[];
    int headerIndex = -1;
    String headerLine = '';

    for (var i = 0; i < lines.length; i++) {
      final line = _stripAnsi(lines[i]);
      if (_dockerHeaderRegex.hasMatch(line) ||
          (line.contains('CONTAINER ID') && line.contains('IMAGE') && line.contains('STATUS'))) {
        headerIndex = i;
        headerLine = line;
        break;
      }
    }

    if (headerIndex == -1) return results;

    // Use column offsets from header if available, or regex fallback
    final idStart = headerLine.indexOf('CONTAINER ID');
    final imgStart = headerLine.indexOf('IMAGE');
    final cmdStart = headerLine.indexOf('COMMAND');
    final crtStart = headerLine.indexOf('CREATED');
    final sttStart = headerLine.indexOf('STATUS');
    final prtStart = headerLine.indexOf('PORTS');
    final namStart = headerLine.indexOf('NAMES');

    final canSlice = idStart != -1 &&
        imgStart != -1 &&
        cmdStart != -1 &&
        crtStart != -1 &&
        sttStart != -1 &&
        prtStart != -1 &&
        namStart != -1;

    for (var i = headerIndex + 1; i < lines.length; i++) {
      final raw = _stripAnsi(lines[i]);
      if (raw.trim().isEmpty) continue;

      if (canSlice && raw.length >= sttStart) {
        String slice(int start, int next) {
          if (start >= raw.length) return '';
          final end = (next > 0 && next < raw.length) ? next : raw.length;
          return raw.substring(start, end).trim();
        }

        final id = slice(idStart, imgStart);
        final img = slice(imgStart, cmdStart);
        final cmd = slice(cmdStart, crtStart);
        final crt = slice(crtStart, sttStart);
        final stt = slice(sttStart, prtStart);
        final prt = slice(prtStart, namStart);
        final nam = namStart < raw.length ? raw.substring(namStart).trim() : '';

        if (id.isNotEmpty) {
          results.add(DockerContainerEntry(
            containerId: id,
            image: img,
            command: cmd,
            created: crt,
            status: stt,
            ports: prt,
            names: nam,
          ));
          continue;
        }
      }

      // Fallback split by 2 or more spaces
      final parts = raw.trim().split(RegExp(r'\s{2,}'));
      if (parts.length >= 4) {
        results.add(DockerContainerEntry(
          containerId: parts[0],
          image: parts.length > 1 ? parts[1] : '',
          command: parts.length > 2 ? parts[2] : '',
          created: parts.length > 3 ? parts[3] : '',
          status: parts.length > 4 ? parts[4] : '',
          ports: parts.length > 5 ? parts[5] : '',
          names: parts.length > 6 ? parts[6] : (parts.length > 5 ? parts[5] : ''),
        ));
      }
    }

    return results;
  }

  static String _stripAnsi(String text) {
    return text.replaceAll(RegExp(r'\x1b\[[0-9;]*[a-zA-Z]|\x1b\].*?(\x07|\x1b\\)'), '');
  }
}
