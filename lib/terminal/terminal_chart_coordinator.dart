import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:geekcore_term/terminal/terminal_chart_models.dart';
import 'package:xterm/xterm.dart';

/// Coordinates chart capture, block tracking and floating badge calculation
class TerminalChartCoordinator extends ChangeNotifier {
  TerminalChartCoordinator({
    required this.terminal,
    required this.scrollController,
    TerminalController? terminalController,
  }) : _terminalController = terminalController {
    terminal.addListener(_onTerminalChanged);
  }

  final Terminal terminal;
  final ScrollController scrollController;
  TerminalController? _terminalController;
  set terminalController(TerminalController? controller) {
    if (_terminalController == controller) return;
    _terminalController = controller;
    _updateHiddenLines();
  }

  final List<CapturedCommandBlock> _blocks = [];
  List<CapturedCommandBlock> get blocks => List.unmodifiable(_blocks);

  String _inputBuffer = '';
  String? _pendingCommand;
  CommandChartType? _pendingType;
  int? _pendingStartLine;
  CellAnchor? _pendingStartAnchor;
  final StringBuffer _outputBuffer = StringBuffer();
  Timer? _idleFinishTimer;

  static final RegExp _promptRegex = RegExp(
    r'(?:^|[\r\n])(?:\[?[a-zA-Z0-9_.\-]+@[a-zA-Z0-9_.\-]+[^#$%>\]]*\]?[#$%>]|[\w.\-]+(?:[#$%>])|[#$%>])\s*$',
  );

  void _onTerminalChanged() {
    if (_blocks.isEmpty) return;
    // If any block's anchors detached or shifted (e.g. due to scrolling at bottom of buffer),
    // keep hidden line indices in sync.
    var needsNotify = false;
    for (var i = _blocks.length - 1; i >= 0; i--) {
      final b = _blocks[i];
      if ((b.startAnchor != null && !b.startAnchor!.attached) ||
          (b.endAnchor != null && !b.endAnchor!.attached)) {
        b.dispose();
        _blocks.removeAt(i);
        needsNotify = true;
      }
    }
    _updateHiddenLines();
    if (needsNotify) {
      notifyListeners();
    }
  }

  CellAnchor? _createLineAnchor(int lineY) {
    try {
      final lines = terminal.buffer.lines;
      if (lineY >= 0 && lineY < lines.length) {
        return lines[lineY].createAnchor(0);
      }
    } catch (_) {}
    return null;
  }

  /// Called when user inputs characters into terminal
  void notifyUserInput(String input) {
    if (input == '\x0c') {
      // Ctrl+L clears screen -> clear active chart blocks
      clear();
      return;
    }
    if (input.contains('\r') || input.contains('\n')) {
      final beforeEnter = input.split(RegExp(r'[\r\n]')).first;
      _inputBuffer += beforeEnter;
      // Read the actual line text from terminal buffer where the user typed the command
      final bufferLineText = _getCurrentCursorLineText();
      final candidate = _extractCommandFromPromptLine(bufferLineText);
      final typedCmd = _inputBuffer.trim();

      if (_isClearCommand(candidate) || _isClearCommand(typedCmd)) {
        _inputBuffer = '';
        clear();
        return;
      }

      // Prefer the buffer line if it matches a chart command (handles Tab completion, history, backspace),
      // otherwise fallback to _inputBuffer
      if (TerminalCommandChartParser.matchCommandType(candidate) != null) {
        _handleCommandEntered(candidate);
      } else {
        _handleCommandEntered(typedCmd);
      }
      _inputBuffer = '';
    } else if (input == '\x7f' || input == '\b') {
      if (_inputBuffer.isNotEmpty) {
        _inputBuffer = _inputBuffer.substring(0, _inputBuffer.length - 1);
      }
    } else if (input == '\x03' || input == '\x15') {
      // Ctrl+C or Ctrl+U clears input
      _inputBuffer = '';
    } else if (!input.startsWith('\x1b')) {
      _inputBuffer += input;
      if (_inputBuffer.length > 500) {
        _inputBuffer = _inputBuffer.substring(_inputBuffer.length - 500);
      }
    }
  }

  static bool _isClearCommand(String cmd) {
    final lower = cmd.trim().toLowerCase();
    return lower == 'clear' || lower == 'reset' || lower == 'cls';
  }

  String _getCurrentCursorLineText() {
    try {
      final y = terminal.buffer.absoluteCursorY;
      if (y >= 0 && y < terminal.buffer.lines.length) {
        return terminal.buffer.lines[y].getText().trim();
      }
    } catch (_) {}
    return '';
  }

  static String _extractCommandFromPromptLine(String line) {
    if (line.isEmpty) return '';
    // Strip common prompt prefixes like `[user@host dir]$ `, `user@host:~# `, `PS ...> `, `$ `, `# `, `% `, `❯ `
    final match = RegExp(r'^(?:.*?[#$%>❯➜]\s+)(.+)$').firstMatch(line);
    if (match != null) {
      return match.group(1)!.trim();
    }
    return line.trim();
  }

  void _handleCommandEntered(String cmd) {
    final trimmed = cmd.trim();
    final type = TerminalCommandChartParser.matchCommandType(trimmed);
    if (type != null) {
      _pendingCommand = trimmed;
      _pendingType = type;
      _pendingStartLine = terminal.buffer.absoluteCursorY;
      _pendingStartAnchor?.dispose();
      _pendingStartAnchor = _createLineAnchor(_pendingStartLine!);
      _outputBuffer.clear();
      _idleFinishTimer?.cancel();
    }
  }

  /// Called as raw output text arrives from terminal stream
  void observeOutput(String chunk) {
    // Check if output contains screen clear sequences: ESC[2J, ESC[3J, ESC[H+ESC[J, or ESC c
    if (chunk.contains('\x1b[2J') ||
        chunk.contains('\x1b[3J') ||
        chunk.contains('\x1bc') ||
        chunk.contains('\x1b[H\x1b[J')) {
      clear();
      return;
    }

    final stripped = chunk.replaceAll(RegExp(r'\x1b\[[0-9;?=]*[a-zA-Z]|\x1b\].*?(\x07|\x1b\\)|\x1b[()][AB012]'), '');

    if (_pendingCommand == null) {
      // 1. Check if command echo or output table header appears in the output
      final lines = stripped.split(RegExp(r'[\r\n]+'));
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;

        final cmdCandidate = _extractCommandFromPromptLine(trimmed);
        if (_isClearCommand(cmdCandidate)) {
          clear();
          return;
        }
        final cmdType = TerminalCommandChartParser.matchCommandType(cmdCandidate);
        if (cmdType != null) {
          _pendingCommand = cmdCandidate;
          _pendingType = cmdType;
          _pendingStartLine = _findCommandBufferLine(cmdType) ?? math.max(0, terminal.buffer.absoluteCursorY - 1);
          _pendingStartAnchor?.dispose();
          _pendingStartAnchor = _createLineAnchor(_pendingStartLine!);
          _outputBuffer.clear();
          _outputBuffer.write(stripped);
          _checkAndScheduleFinish(stripped);
          return;
        }

        final headerType = TerminalCommandChartParser.detectOutputHeader(trimmed);
        if (headerType != null) {
          _pendingType = headerType;
          _pendingCommand = switch (headerType) {
            CommandChartType.df => 'df -h',
            CommandChartType.free => 'free -h',
            CommandChartType.dockerPs => 'docker ps',
          };
          _pendingStartLine = _findCommandBufferLine(headerType) ?? math.max(0, terminal.buffer.absoluteCursorY - 2);
          _pendingStartAnchor?.dispose();
          _pendingStartAnchor = _createLineAnchor(_pendingStartLine!);
          _outputBuffer.clear();
          _outputBuffer.write(stripped);
          _checkAndScheduleFinish(stripped);
          return;
        }
      }
      return;
    }

    _outputBuffer.write(stripped);
    _checkAndScheduleFinish(stripped);
  }

  int? _findCommandBufferLine(CommandChartType type) {
    try {
      final curY = terminal.buffer.absoluteCursorY;
      final minSearch = math.max(0, curY - 250);
      for (var y = curY; y >= minSearch; y--) {
        if (y >= terminal.buffer.lines.length) continue;
        final text = terminal.buffer.lines[y].getText().trim();
        if (text.isEmpty) continue;
        final extracted = _extractCommandFromPromptLine(text);
        if (TerminalCommandChartParser.matchCommandType(extracted) == type) {
          return y;
        }
      }
      // Second pass: find latest header line and return 1 line above it
      for (var y = curY; y >= minSearch; y--) {
        if (y >= terminal.buffer.lines.length) continue;
        final text = terminal.buffer.lines[y].getText().trim();
        if (TerminalCommandChartParser.detectOutputHeader(text) == type) {
          return math.max(0, y - 1);
        }
      }
    } catch (_) {}
    return null;
  }

  void _checkAndScheduleFinish(String latestStrippedChunk) {
    _idleFinishTimer?.cancel();

    // Check if the accumulated output or latest chunk ends with a shell prompt
    final fullOut = _outputBuffer.toString();
    final hasNewline = fullOut.contains('\n');
    if (hasNewline &&
        (_promptRegex.hasMatch(fullOut.trimRight()) ||
            _promptRegex.hasMatch(latestStrippedChunk.trimRight()) ||
            latestStrippedChunk.contains('\r\nroot@') ||
            (latestStrippedChunk.contains('\n') &&
                (latestStrippedChunk.trimRight().endsWith('\$') ||
                    latestStrippedChunk.trimRight().endsWith('#') ||
                    latestStrippedChunk.trimRight().endsWith('%') ||
                    latestStrippedChunk.trimRight().endsWith('>'))))) {
      // Only finish immediately if we already have valid parsed data
      if (_hasValidParsedData(fullOut)) {
        _finishPendingBlock();
        return;
      }
    }

    // Fallback timer: if valid output has arrived and stream settles (e.g. custom prompt like Starship/zsh),
    // finalize the block automatically.
    _idleFinishTimer = Timer(const Duration(milliseconds: 120), () {
      if (_pendingCommand != null && _hasValidParsedData(_outputBuffer.toString())) {
        _finishPendingBlock();
      }
    });
  }

  bool _hasValidParsedData(String output) {
    final type = _pendingType ?? (_pendingCommand != null ? TerminalCommandChartParser.matchCommandType(_pendingCommand!) : null);
    if (type == null) return false;
    switch (type) {
      case CommandChartType.df:
        return TerminalCommandChartParser.parseDf(output).isNotEmpty;
      case CommandChartType.free:
        return TerminalCommandChartParser.parseFree(output) != null;
      case CommandChartType.dockerPs:
        return TerminalCommandChartParser.detectOutputHeader(output) == CommandChartType.dockerPs ||
            TerminalCommandChartParser.parseDockerPs(output).isNotEmpty;
    }
  }

  void _finishPendingBlock() {
    _idleFinishTimer?.cancel();
    _idleFinishTimer = null;
    if (_pendingCommand == null) return;
    final cmd = _pendingCommand!;
    final type = _pendingType ?? TerminalCommandChartParser.matchCommandType(cmd);

    int start;
    if (_pendingStartAnchor != null && _pendingStartAnchor!.attached) {
      start = _pendingStartAnchor!.y;
    } else {
      start = (type != null ? _findCommandBufferLine(type) : null) ??
          _pendingStartLine ??
          math.max(0, terminal.buffer.absoluteCursorY - 1);
    }

    // Verify start line: if a more accurate command line exists in the buffer near or after anchor, prefer it
    if (type != null) {
      final foundStart = _findCommandBufferLine(type);
      if (foundStart != null &&
          (_pendingStartAnchor == null ||
              !_pendingStartAnchor!.attached ||
              foundStart >= start - 2)) {
        start = foundStart;
      }
    }

    final end = math.max(start + 1, terminal.buffer.absoluteCursorY);
    final output = _outputBuffer.toString();

    _pendingStartAnchor?.dispose();
    _pendingStartAnchor = null;
    _pendingCommand = null;
    _pendingType = null;
    _pendingStartLine = null;
    _outputBuffer.clear();

    if (type == null) return;

    CapturedCommandBlock? newBlock;

    if (type == CommandChartType.df) {
      final entries = TerminalCommandChartParser.parseDf(output);
      if (entries.isNotEmpty) {
        newBlock = CapturedCommandBlock(
          id: 'df-${DateTime.now().millisecondsSinceEpoch}',
          command: cmd,
          type: type,
          startBufferLine: start,
          endBufferLine: end,
          startAnchor: _createLineAnchor(start),
          endAnchor: _createLineAnchor(end),
          rawOutput: output,
          dfEntries: entries,
        );
      }
    } else if (type == CommandChartType.free) {
      final stats = TerminalCommandChartParser.parseFree(output);
      if (stats != null) {
        newBlock = CapturedCommandBlock(
          id: 'free-${DateTime.now().millisecondsSinceEpoch}',
          command: cmd,
          type: type,
          startBufferLine: start,
          endBufferLine: end,
          startAnchor: _createLineAnchor(start),
          endAnchor: _createLineAnchor(end),
          rawOutput: output,
          freeStats: stats,
        );
      }
    } else if (type == CommandChartType.dockerPs) {
      final dockerEntries = TerminalCommandChartParser.parseDockerPs(output);
      final hasHeader = TerminalCommandChartParser.detectOutputHeader(output) == CommandChartType.dockerPs ||
          output.contains('CONTAINER ID');
      if (dockerEntries.isNotEmpty || hasHeader) {
        newBlock = CapturedCommandBlock(
          id: 'docker-${DateTime.now().millisecondsSinceEpoch}',
          command: cmd,
          type: type,
          startBufferLine: start,
          endBufferLine: end,
          startAnchor: _createLineAnchor(start),
          endAnchor: _createLineAnchor(end),
          rawOutput: output,
          dockerEntries: dockerEntries,
        );
      }
    }

    if (newBlock != null) {
      // Only keep the latest command chart! Previous blocks revert to raw terminal text and scroll normally.
      for (final old in _blocks) {
        old.dispose();
      }
      _blocks
        ..clear()
        ..add(newBlock);
      _updateHiddenLines();
      notifyListeners();
    }
  }

  void _updateHiddenLines() {
    final controller = _terminalController;
    if (controller == null) return;
    final hidden = <int>{};
    for (final block in _blocks) {
      if (block.isRenderMode) {
        final start = block.currentStartLine;
        final end = block.currentEndLine;
        // Hide the raw command output lines between the command line and the prompt
        for (var line = start + 1; line < end; line++) {
          hidden.add(line);
        }
      }
    }
    if (!_setsEqual(controller.hiddenLineIndices, hidden)) {
      controller.setHiddenLineIndices(hidden);
    }
  }

  static bool _setsEqual(Set<int> a, Set<int> b) {
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }

  void toggleBlockMode(CapturedCommandBlock block) {
    block.isRenderMode = !block.isRenderMode;
    _updateHiddenLines();
    notifyListeners();
  }

  void toggleBlockFullscreen(CapturedCommandBlock block, {required bool currentlyFullscreen}) {
    block.isFullscreenOverride = !currentlyFullscreen;
    notifyListeners();
  }

  void clear() {
    _idleFinishTimer?.cancel();
    _idleFinishTimer = null;
    _pendingStartAnchor?.dispose();
    _pendingStartAnchor = null;
    for (final b in _blocks) {
      b.dispose();
    }
    _blocks.clear();
    _pendingCommand = null;
    _pendingType = null;
    _pendingStartLine = null;
    _outputBuffer.clear();
    _inputBuffer = '';
    _updateHiddenLines();
    notifyListeners();
  }

  @override
  void dispose() {
    terminal.removeListener(_onTerminalChanged);
    _idleFinishTimer?.cancel();
    _pendingStartAnchor?.dispose();
    for (final b in _blocks) {
      b.dispose();
    }
    super.dispose();
  }
}
