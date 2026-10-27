import 'dart:async';

import 'package:flutter/foundation.dart';

class TerminalAssistantFinding {
  TerminalAssistantFinding({
    required this.ruleId,
    required this.title,
    required this.evidence,
    required this.explanation,
    required List<String> verificationSteps,
    required List<String> suggestedCommands,
    required this.observedAt,
    required this.outputOffset,
  }) : verificationSteps = List.unmodifiable(verificationSteps),
       suggestedCommands = List.unmodifiable(suggestedCommands);

  final String ruleId;
  final String title;
  final String evidence;
  final String explanation;
  final List<String> verificationSteps;
  final List<String> suggestedCommands;
  final DateTime observedAt;

  /// Character offset in the analyzed output stream for this terminal session.
  final int outputOffset;
}

/// Local, bounded, text-only diagnostics. It never writes to a terminal.
class TerminalAssistantAnalyzer extends ChangeNotifier {
  TerminalAssistantAnalyzer({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static const maxFindings = 50;
  static const maxContextCharacters = 256;
  static const _dedupeWindow = Duration(seconds: 30);
  static const _recentFingerprintLimit = 128;

  static final List<_TerminalAssistantRule> _rules = [
    _TerminalAssistantRule(
      id: 'port-in-use',
      pattern: RegExp(
        r'\b(?:Address already in use|EADDRINUSE)\b',
        caseSensitive: false,
      ),
      title: '监听地址可能已被占用',
      explanation: '程序报告绑定地址失败。仅凭这条输出无法确定占用进程或实际监听状态。',
      verificationSteps: const [
        '核对程序尝试绑定的地址和端口。',
        '检查是否已有服务监听同一端口；不要只凭此提示结束进程。',
      ],
      suggestedCommands: const ['ss -ltnp', 'ss -lunp'],
    ),
    _TerminalAssistantRule(
      id: 'storage-full',
      pattern: RegExp(
        r'\b(?:No space left on device|ENOSPC)\b',
        caseSensitive: false,
      ),
      title: '程序报告存储空间不足',
      explanation: '该输出可能指磁盘空间或 inode 用尽；需要在目标文件系统上分别核对。',
      verificationSteps: const [
        '确认报错路径属于哪个挂载点。',
        '同时检查可用容量和 inode；不要假设删除文件是安全的。',
      ],
      suggestedCommands: const ['df -h', 'df -i'],
    ),
    _TerminalAssistantRule(
      id: 'permission-denied',
      pattern: RegExp(r'\bPermission denied\b', caseSensitive: false),
      title: '访问或认证被拒绝',
      explanation: '这条提示可能来自 SSH 认证、文件权限或服务策略，需结合相邻输出判断。',
      verificationSteps: const [
        '确认当前用户、认证方式和目标资源。',
        '核对路径各级目录权限及服务端策略，不要直接放宽权限。',
      ],
      suggestedCommands: const ['id', 'ls -ld PATH'],
    ),
    _TerminalAssistantRule(
      id: 'dns-lookup-failed',
      pattern: RegExp(
        r'\b(?:Could not resolve (?:hostname|host)|Temporary failure in name resolution|Name or service not known|nodename nor servname provided)\b',
        caseSensitive: false,
      ),
      title: '主机名解析失败',
      explanation: '输出显示名称解析未成功；主机名拼写、解析器配置和网络路径都可能相关。',
      verificationSteps: const ['核对主机名和当前网络环境。', '检查本机或远端解析器配置，并与已知可用域名比较。'],
      suggestedCommands: const [
        'getent ahosts HOSTNAME',
        'cat /etc/resolv.conf',
      ],
    ),
    _TerminalAssistantRule(
      id: 'connection-refused',
      pattern: RegExp(
        r'\b(?:Connection refused|ECONNREFUSED)\b',
        caseSensitive: false,
      ),
      title: '连接被目标拒绝',
      explanation: '目标或中间设备返回拒绝；这不能单独证明主机不可达。',
      verificationSteps: const ['核对目标地址和端口。', '确认目标服务正在监听，并检查主动拒绝连接的防火墙规则。'],
      suggestedCommands: const ['ss -ltn', 'nc -vz HOST PORT'],
    ),
    _TerminalAssistantRule(
      id: 'connection-timeout',
      pattern: RegExp(
        r'\b(?:Connection timed out|Operation timed out|ETIMEDOUT)\b',
        caseSensitive: false,
      ),
      title: '连接等待超时',
      explanation: '超时可能来自路由、防火墙、拥塞或对端无响应；不能仅据此判定主机宕机。',
      verificationSteps: const ['确认目标地址、端口和预期网络路径。', '分别检查路由、访问控制和服务端日志。'],
      suggestedCommands: const [
        'ip route get ADDRESS',
        'nc -vz -w 3 HOST PORT',
      ],
    ),
    _TerminalAssistantRule(
      id: 'systemd-unit-failed',
      pattern: RegExp(r'\bActive:\s*failed\b', caseSensitive: false),
      title: '输出中出现 systemd failed 状态',
      explanation: '终端文本显示一个 failed 状态，但可能是旧输出；需查询当前服务状态和日志。',
      verificationSteps: const [
        '从输出中确认具体 unit 名称。',
        '检查当前状态、退出信息和该 unit 的近期日志。',
      ],
      suggestedCommands: const [
        'systemctl status UNIT --no-pager',
        'journalctl -u UNIT -n 50 --no-pager',
      ],
    ),
    _TerminalAssistantRule(
      id: 'command-not-found',
      pattern: RegExp(r'\bcommand not found\b', caseSensitive: false),
      title: 'Shell 未找到命令',
      explanation: '可能是命令名拼写错误、程序未安装或当前 PATH 未包含其目录。',
      verificationSteps: const [
        '核对命令名称和当前 shell。',
        '确认软件安装位置及 PATH；不要盲目安装同名软件包。',
      ],
      suggestedCommands: const [
        'command -v COMMAND',
        "printf '%s\\n' \"\$PATH\"",
      ],
    ),
  ];

  final DateTime Function() _clock;
  final _AnsiOutputFilter _ansiFilter = _AnsiOutputFilter();
  final List<TerminalAssistantFinding> _findings = [];
  final Map<String, DateTime> _recentFingerprints = {};
  String _context = '';
  int _streamOffset = 0;
  int _scannedThroughOffset = 0;

  List<TerminalAssistantFinding> get findings =>
      List.unmodifiable(_findings.reversed);
  int get bufferedContextCharacters => _context.length;

  List<TerminalAssistantFinding> observe(String outputChunk) {
    if (outputChunk.isEmpty) return const [];
    final plainText = _ansiFilter
        .strip(outputChunk)
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    if (plainText.isEmpty) return const [];

    final scanStartOffset = _streamOffset - _context.length;
    final scanWindow = '$_context$plainText';
    final now = _clock();
    _recentFingerprints.removeWhere(
      (_, lastSeen) => now.difference(lastSeen) > _dedupeWindow,
    );
    final newFindings = <TerminalAssistantFinding>[];

    for (final rule in _rules) {
      for (final match in rule.pattern.allMatches(scanWindow)) {
        final absoluteEnd = scanStartOffset + match.end;
        if (absoluteEnd <= _scannedThroughOffset) continue;
        final evidence = _trimEvidence(match.group(0) ?? '');
        final fingerprint = '${rule.id}:${evidence.toLowerCase()}';
        final lastSeen = _recentFingerprints[fingerprint];
        _recentFingerprints[fingerprint] = now;
        if (lastSeen != null && now.difference(lastSeen) <= _dedupeWindow) {
          continue;
        }
        newFindings.add(
          TerminalAssistantFinding(
            ruleId: rule.id,
            title: rule.title,
            evidence: evidence,
            explanation: rule.explanation,
            verificationSteps: rule.verificationSteps,
            suggestedCommands: rule.suggestedCommands,
            observedAt: now,
            outputOffset: scanStartOffset + match.start,
          ),
        );
      }
    }

    _streamOffset += plainText.length;
    _scannedThroughOffset = _streamOffset;
    _context = scanWindow.length <= maxContextCharacters
        ? scanWindow
        : scanWindow.substring(scanWindow.length - maxContextCharacters);
    while (_recentFingerprints.length > _recentFingerprintLimit) {
      _recentFingerprints.remove(_recentFingerprints.keys.first);
    }

    if (newFindings.isNotEmpty) {
      newFindings.sort(
        (first, second) => first.outputOffset.compareTo(second.outputOffset),
      );
      _findings.addAll(newFindings);
      if (_findings.length > maxFindings) {
        _findings.removeRange(0, _findings.length - maxFindings);
      }
      notifyListeners();
    }
    return List.unmodifiable(newFindings);
  }

  void clear() {
    if (_findings.isEmpty && _recentFingerprints.isEmpty) return;
    _findings.clear();
    _recentFingerprints.clear();
    notifyListeners();
  }

  /// Clears evidence and parser context when the tab reconnects to a session.
  void reset() {
    _findings.clear();
    _recentFingerprints.clear();
    _context = '';
    _streamOffset = 0;
    _scannedThroughOffset = 0;
    _ansiFilter.reset();
    notifyListeners();
  }

  static String _trimEvidence(String value) {
    final trimmed = value.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (trimmed.length <= 180) return trimmed;
    return '${trimmed.substring(0, 177)}…';
  }
}

class _TerminalAssistantRule {
  const _TerminalAssistantRule({
    required this.id,
    required this.pattern,
    required this.title,
    required this.explanation,
    required this.verificationSteps,
    required this.suggestedCommands,
  });

  final String id;
  final RegExp pattern;
  final String title;
  final String explanation;
  final List<String> verificationSteps;
  final List<String> suggestedCommands;
}

class _AnsiOutputFilter {
  static const _plain = 0;
  static const _escape = 1;
  static const _csi = 2;
  static const _osc = 3;
  static const _controlString = 4;
  static const _stringEscape = 5;

  int _state = _plain;
  int _stringReturnState = _plain;

  String strip(String input) {
    final output = StringBuffer();
    for (final unit in input.codeUnits) {
      switch (_state) {
        case _plain:
          if (unit == 0x1b) {
            _state = _escape;
          } else if (unit == 0x9b) {
            _state = _csi;
          } else if (unit == 0x9d) {
            _state = _osc;
          } else if (unit == 0x90 ||
              unit == 0x98 ||
              unit == 0x9e ||
              unit == 0x9f) {
            _state = _controlString;
          } else if (unit != 0x07) {
            output.writeCharCode(unit);
          }
        case _escape:
          if (unit == 0x5b) {
            _state = _csi;
          } else if (unit == 0x5d) {
            _state = _osc;
          } else if (unit == 0x50 ||
              unit == 0x58 ||
              unit == 0x5e ||
              unit == 0x5f) {
            _state = _controlString;
          } else {
            _state = _plain;
          }
        case _csi:
          if (unit >= 0x40 && unit <= 0x7e) _state = _plain;
        case _osc:
          if (unit == 0x07) {
            _state = _plain;
          } else if (unit == 0x1b) {
            _stringReturnState = _osc;
            _state = _stringEscape;
          }
        case _controlString:
          if (unit == 0x1b) {
            _stringReturnState = _controlString;
            _state = _stringEscape;
          }
        case _stringEscape:
          if (unit == 0x5c) {
            _state = _plain;
          } else if (unit == 0x1b) {
            _state = _stringEscape;
          } else {
            _state = _stringReturnState;
          }
      }
    }
    return output.toString();
  }

  void reset() {
    _state = _plain;
    _stringReturnState = _plain;
  }
}

class _PendingHintSpan {
  _PendingHintSpan(this.start, this.text);
  final int start;
  final String text;
}

/// Transforms terminal output stream to insert inline GUI-styled hints
/// when enabled for status keywords (e.g. enabled, active, running),
/// UTC timestamps, and elapsed times (xxx ago).
class TerminalInlineHintTransformer {
  String _lineBuffer = '';
  Timer? _flushTimer;

  /// Whether we are currently inside the output of a whitelisted command
  /// (e.g. systemctl status/service ... status).
  bool _isWhitelistedCommand = false;

  /// Patterns that activate inline hint transformation
  static final List<RegExp> _whitelistPatterns = [
    RegExp(r'\bsystemctl\s+(?:status|is-active|is-enabled)\b', caseSensitive: false),
    RegExp(r'\bservice\s+\S+\s+status\b', caseSensitive: false),
    RegExp(r'\b(?:Loaded:\s*(?:loaded|masked)|Active:\s*(?:active|inactive|failed))\b', caseSensitive: false),
  ];

  /// Patterns that indicate a shell prompt has returned (ending the command output)
  static final RegExp _promptPattern = RegExp(
    r'(?:^|[\r\n])(?:[\w.\-]+@[\w.\-]+:[^#$]*[#$]|\$ |# )\s*$',
  );

  /// Callback invoked when buffered text (e.g. an unfinished line or shell prompt)
  /// is flushed asynchronously after a brief pause so terminal displays stay instant.
  void Function(String)? onFlush;

  /// Notify the transformer about user keyboard input (e.g. commands typed in terminal)
  void notifyUserInput(String input) {
    for (final pattern in _whitelistPatterns) {
      if (pattern.hasMatch(input)) {
        _isWhitelistedCommand = true;
        break;
      }
    }
  }

  String transform(String chunk, {DateTime Function()? clock}) {
    if (chunk.isEmpty) return chunk;

    _flushTimer?.cancel();
    _flushTimer = null;

    final combined = '$_lineBuffer$chunk';
    final lineBreakRegex = RegExp(r'[^\r\n]*(?:\r\n|\n|\r)');
    final matches = lineBreakRegex.allMatches(combined).toList();

    if (matches.isEmpty) {
      _lineBuffer = combined;
      _scheduleFlush(clock: clock);
      return '';
    }

    final lastMatch = matches.last;
    _lineBuffer = combined.substring(lastMatch.end);

    if (_lineBuffer.isNotEmpty) {
      _scheduleFlush(clock: clock);
    }

    final buffer = StringBuffer();
    for (final match in matches) {
      final line = match.group(0)!;
      buffer.write(_processLineStateful(line, clock: clock));
    }
    return buffer.toString();
  }

  void _scheduleFlush({DateTime Function()? clock}) {
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: 20), () {
      if (_lineBuffer.isNotEmpty) {
        final pending = _processLineStateful(_lineBuffer, clock: clock);
        _lineBuffer = '';
        onFlush?.call(pending);
      }
    });
  }

  String flush({DateTime Function()? clock}) {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_lineBuffer.isEmpty) return '';
    final res = _processLineStateful(_lineBuffer, clock: clock);
    _lineBuffer = '';
    return res;
  }

  void reset() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _lineBuffer = '';
    _isWhitelistedCommand = false;
  }

  void dispose() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _lineBuffer = '';
    _isWhitelistedCommand = false;
    onFlush = null;
  }

  String _processLineStateful(String line, {DateTime Function()? clock}) {
    final plainText = _stripAnsi(line);

    // 1. Check if line is command echo that triggers whitelist
    for (final pattern in _whitelistPatterns) {
      if (pattern.hasMatch(plainText)) {
        _isWhitelistedCommand = true;
        break;
      }
    }

    // 2. If active, perform inline hints decoration
    final output = _isWhitelistedCommand
        ? _processLine(line, clock: clock)
        : line;

    // 3. Check if shell prompt returned, which ends the whitelisted command output
    if (_promptPattern.hasMatch(plainText.trimRight())) {
      _isWhitelistedCommand = false;
    }

    return output;
  }

  static String _stripAnsi(String text) {
    return text.replaceAll(
      RegExp(r'\x1b\[[0-9;]*[a-zA-Z]|\x1b\].*?(\x07|\x1b\\)'),
      '',
    );
  }

  static String _processLine(String line, {DateTime Function()? clock}) {
    // 1. Strip ANSI escape codes to plain text while building plainIndex -> rawIndex map
    final plainToRawMap = <int>[];
    final plainBuffer = StringBuffer();

    final ansiRegex = RegExp(r'\x1b\[[0-9;]*[a-zA-Z]|\x1b\].*?(\x07|\x1b\\)');
    var lastEnd = 0;
    for (final match in ansiRegex.allMatches(line)) {
      for (var i = lastEnd; i < match.start; i++) {
        plainToRawMap.add(i);
        plainBuffer.write(line[i]);
      }
      lastEnd = match.end;
    }
    for (var i = lastEnd; i < line.length; i++) {
      plainToRawMap.add(i);
      plainBuffer.write(line[i]);
    }
    plainToRawMap.add(line.length);

    final plainText = plainBuffer.toString();

    if (!plainText.contains('enabled') &&
        !plainText.contains('disabled') &&
        !plainText.contains('active') &&
        !plainText.contains('running') &&
        !plainText.contains('inactive') &&
        !plainText.contains('dead') &&
        !plainText.contains('failed') &&
        !plainText.contains('UTC') &&
        !plainText.contains('ago')) {
      return line;
    }

    final insertions = <_PendingHintSpan>[];

    void addWordMatches(String word, String hint, String bg, String fg) {
      final reg = RegExp('\\b$word\\b');
      for (final m in reg.allMatches(plainText)) {
        final rawIndex = plainToRawMap[m.end];
        insertions.add(_PendingHintSpan(
          rawIndex,
          ' \x1b[$bg;$fg;1m $hint \x1b[0m',
        ));
      }
    }

    addWordMatches('enabled', '已启用', '48;2;49;196;141', '38;2;255;255;255');
    addWordMatches('disabled', '已禁用', '48;2;240;82;82', '38;2;255;255;255');
    addWordMatches('active', '活跃', '48;2;49;196;141', '38;2;255;255;255');
    addWordMatches('running', '运行中', '48;2;49;196;141', '38;2;255;255;255');
    addWordMatches('inactive', '未激活', '48;2;120;130;140', '38;2;255;255;255');
    addWordMatches('dead', '已停止', '48;2;120;130;140', '38;2;255;255;255');
    addWordMatches('failed', '失败', '48;2;240;82;82', '38;2;255;255;255');

    final utcReg = RegExp(
      r'\b(?:[A-Za-z]{3}\s+)?(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})\s+UTC\b',
    );
    for (final m in utcReg.allMatches(plainText)) {
      final dateStr = m.group(1)!;
      final iso = '${dateStr.replaceAll(' ', 'T')}Z';
      try {
        final dt = DateTime.parse(iso).toLocal();
        String twoDigits(int n) => n.toString().padLeft(2, '0');
        final formatted =
            '${dt.year}-${twoDigits(dt.month)}-${twoDigits(dt.day)} '
            '${twoDigits(dt.hour)}:${twoDigits(dt.minute)}:${twoDigits(dt.second)}';
        final rawIndex = plainToRawMap[m.end];
        insertions.add(_PendingHintSpan(
          rawIndex,
          ' \x1b[48;2;85;169;232;38;2;255;255;255;1m 本地 $formatted \x1b[0m',
        ));
      } catch (_) {}
    }

    final agoReg = RegExp(
      r'\b((?:\d+\s*(?:years?|y|months?|mo|weeks?|w|days?|d|hours?|hr|h|minutes?|min|m|seconds?|sec|s)\s*)+ago)\b',
      caseSensitive: false,
    );
    for (final m in agoReg.allMatches(plainText)) {
      final matchedText = m.group(1)!;
      final inner = matchedText
          .replaceAll(RegExp(r'\s*ago$', caseSensitive: false), '')
          .trim();
      final buffer = StringBuffer();
      final partRegex = RegExp(r'(\d+)\s*([a-zA-Z]+)');
      for (final p in partRegex.allMatches(inner)) {
        final num = p.group(1)!;
        final unit = p.group(2)!.toLowerCase();
        String unitCn = unit;
        if (unit.startsWith('year') || unit == 'y') {
          unitCn = '年';
        } else if (unit.startsWith('month') || unit == 'mo') {
          unitCn = '个月';
        } else if (unit.startsWith('week') || unit == 'w') {
          unitCn = '周';
        } else if (unit.startsWith('day') || unit == 'd') {
          unitCn = '天';
        } else if (unit.startsWith('hour') || unit == 'hr' || unit == 'h') {
          unitCn = '小时';
        } else if (unit.startsWith('min') || unit == 'm') {
          unitCn = '分钟';
        } else if (unit.startsWith('sec') || unit == 's') {
          unitCn = '秒';
        }
        buffer.write('$num$unitCn');
      }
      final cn = buffer.isEmpty ? '$inner前' : '${buffer.toString()}前';
      final rawIndex = plainToRawMap[m.end];
      insertions.add(_PendingHintSpan(
        rawIndex,
        ' \x1b[48;2;227;160;8;38;2;255;255;255;1m $cn \x1b[0m',
      ));
    }

    if (insertions.isEmpty) return line;

    insertions.sort((a, b) => b.start.compareTo(a.start));
    var res = line;
    for (final item in insertions) {
      res = res.substring(0, item.start) + item.text + res.substring(item.start);
    }
    return res;
  }
}
