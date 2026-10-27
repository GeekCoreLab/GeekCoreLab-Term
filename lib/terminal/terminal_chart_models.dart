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
  });

  final String id;
  final String command;
  final CommandChartType type;
  final int startBufferLine;
  int endBufferLine;
  final String rawOutput;
  final List<DfFsEntry> dfEntries;
  final FreeMemStats? freeStats;

  bool isRenderMode = true;
}

/// Parser for terminal commands and outputs to build GUI charts
class TerminalCommandChartParser {
  static final RegExp _dfHeaderRegex = RegExp(
    r'Filesystem\s+(?:Size|1K-blocks|1M-blocks|1G-blocks)\s+Used\s+Avail(?:able)?\s+Use%\s+Mounted\s+on',
    caseSensitive: false,
  );

  static final RegExp _freeHeaderRegex = RegExp(
    r'\btotal\s+used\s+free\s+shared\s+(?:buff/cache|buffers\s+cached)\s+available\b',
    caseSensitive: false,
  );

  /// Tests if a command is candidate for chart capture (e.g. `df -h`, `free -h`)
  static CommandChartType? matchCommandType(String commandLine) {
    final clean = commandLine.trim().toLowerCase();
    if (clean == 'df' ||
        clean.startsWith('df ') ||
        clean.startsWith('df\t')) {
      return CommandChartType.df;
    }
    if (clean == 'free' ||
        clean.startsWith('free ') ||
        clean.startsWith('free\t')) {
      return CommandChartType.free;
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
            (line.contains('Filesystem') && line.contains('Use%'))) {
          headerFound = true;
        }
        continue;
      }

      final parts = line.split(RegExp(r'\s+'));
      if (parts.length >= 6) {
        final fs = parts[0];
        final size = parts[1];
        final used = parts[2];
        final avail = parts[3];
        final usePercentStr = parts[4].replaceAll('%', '');
        final usePercent = (double.tryParse(usePercentStr) ?? 0) / 100.0;
        final mountedOn = parts.sublist(5).join(' ');
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

      final rowName = parts[0].replaceAll(':', '').toLowerCase();
      if (rowName == 'mem') {
        if (parts.length >= 4) {
          totalMem = parts[1];
          usedMem = parts[2];
          freeMem = parts[3];
        }
        if (parts.length >= 5) sharedMem = parts[4];
        if (parts.length >= 6) buffCacheMem = parts[5];
        if (parts.length >= 7) availableMem = parts[6];
      } else if (rowName == 'swap') {
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

  static String _stripAnsi(String text) {
    return text.replaceAll(RegExp(r'\x1b\[[0-9;]*[a-zA-Z]|\x1b\].*?(\x07|\x1b\\)'), '');
  }
}
