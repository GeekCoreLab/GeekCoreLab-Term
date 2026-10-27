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
