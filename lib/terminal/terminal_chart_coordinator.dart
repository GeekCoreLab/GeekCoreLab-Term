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
  }) : _terminalController = terminalController;

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
  final StringBuffer _outputBuffer = StringBuffer();
  Timer? _idleFinishTimer;

  static final RegExp _promptRegex = RegExp(
    r'(?:^|[\r\n])(?:\[?[a-zA-Z0-9_.\-]+@[a-zA-Z0-9_.\-]+[^#$%>\]]*\]?[#$%>]|[\w.\-]+(?:[#$%>])|[#$%>])\s*$',
  );

  /// Called when user inputs characters into terminal
  void notifyUserInput(String input) {
    if (input.contains('\r') || input.contains('\n')) {
      final beforeEnter = input.split(RegExp(r'[\r\n]')).first;
      _inputBuffer += beforeEnter;
      // Read the actual line text from terminal buffer where the user typed the command
      final bufferLineText = _getCurrentCursorLineText();
      final candidate = _extractCommandFromPromptLine(bufferLineText);
      final typedCmd = _inputBuffer.trim();

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
    // Strip common prompt prefixes like `[user@host dir]$ `, `user@host:~# `, `PS ...> `, `$ `, `# `, `% `
    final match = RegExp(r'^(?:.*?[#$%>]\s+)(.+)$').firstMatch(line);
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
      _outputBuffer.clear();
      _idleFinishTimer?.cancel();
    }
  }

  /// Called as raw output text arrives from terminal stream
  void observeOutput(String chunk) {
    final stripped = chunk.replaceAll(RegExp(r'\x1b\[[0-9;?=]*[a-zA-Z]|\x1b\].*?(\x07|\x1b\\)|\x1b[()][AB012]'), '');

    if (_pendingCommand == null) {
      // 1. Check if command echo or output table header appears in the output
      final lines = stripped.split(RegExp(r'[\r\n]+'));
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;

        final cmdCandidate = _extractCommandFromPromptLine(trimmed);
        final cmdType = TerminalCommandChartParser.matchCommandType(cmdCandidate);
        if (cmdType != null) {
          _pendingCommand = cmdCandidate;
          _pendingType = cmdType;
          _pendingStartLine = _findCommandBufferLine(cmdType) ?? math.max(0, terminal.buffer.absoluteCursorY - 1);
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
      final minSearch = math.max(0, curY - 30);
      for (var y = curY; y >= minSearch; y--) {
        if (y >= terminal.buffer.lines.length) continue;
        final text = terminal.buffer.lines[y].getText().trim();
        if (text.isEmpty) continue;
        final extracted = _extractCommandFromPromptLine(text);
        if (TerminalCommandChartParser.matchCommandType(extracted) == type) {
          return y;
        }
      }
      // Second pass: find header line and return 1 line above it
      for (var y = minSearch; y <= curY; y++) {
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
    final start = _pendingStartLine ??
        (type != null ? _findCommandBufferLine(type) : null) ??
        math.max(0, terminal.buffer.absoluteCursorY - 1);
    final end = math.max(start, terminal.buffer.absoluteCursorY);
    final output = _outputBuffer.toString();

    _pendingCommand = null;
    _pendingType = null;
    _pendingStartLine = null;
    _outputBuffer.clear();

    if (type == null) return;

    if (type == CommandChartType.df) {
      final entries = TerminalCommandChartParser.parseDf(output);
      if (entries.isNotEmpty) {
        final block = CapturedCommandBlock(
          id: 'df-${DateTime.now().millisecondsSinceEpoch}',
          command: cmd,
          type: type,
          startBufferLine: start,
          endBufferLine: end,
          rawOutput: output,
          dfEntries: entries,
        );
        _blocks.add(block);
        if (_blocks.length > 20) _blocks.removeAt(0);
        _updateHiddenLines();
        notifyListeners();
      }
    } else if (type == CommandChartType.free) {
      final stats = TerminalCommandChartParser.parseFree(output);
      if (stats != null) {
        final block = CapturedCommandBlock(
          id: 'free-${DateTime.now().millisecondsSinceEpoch}',
          command: cmd,
          type: type,
          startBufferLine: start,
          endBufferLine: end,
          rawOutput: output,
          freeStats: stats,
        );
        _blocks.add(block);
        if (_blocks.length > 20) _blocks.removeAt(0);
        _updateHiddenLines();
        notifyListeners();
      }
    } else if (type == CommandChartType.dockerPs) {
      final dockerEntries = TerminalCommandChartParser.parseDockerPs(output);
      final hasHeader = TerminalCommandChartParser.detectOutputHeader(output) == CommandChartType.dockerPs ||
          output.contains('CONTAINER ID');
      if (dockerEntries.isNotEmpty || hasHeader) {
        final block = CapturedCommandBlock(
          id: 'docker-${DateTime.now().millisecondsSinceEpoch}',
          command: cmd,
          type: type,
          startBufferLine: start,
          endBufferLine: end,
          rawOutput: output,
          dockerEntries: dockerEntries,
        );
        _blocks.add(block);
        if (_blocks.length > 20) _blocks.removeAt(0);
        _updateHiddenLines();
        notifyListeners();
      }
    }
  }

  void _updateHiddenLines() {
    final controller = _terminalController;
    if (controller == null) return;
    final hidden = <int>{};
    for (final block in _blocks) {
      if (block.isRenderMode) {
        // Hide the raw command output lines between the command line and the prompt
        // startBufferLine is the command typed line; startBufferLine + 1 to endBufferLine - 1 is the output
        for (var line = block.startBufferLine + 1; line < block.endBufferLine; line++) {
          hidden.add(line);
        }
      }
    }
    controller.setHiddenLineIndices(hidden);
  }

  void toggleBlockMode(CapturedCommandBlock block) {
    block.isRenderMode = !block.isRenderMode;
    _updateHiddenLines();
    notifyListeners();
  }

  void clear() {
    _idleFinishTimer?.cancel();
    _idleFinishTimer = null;
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
    _idleFinishTimer?.cancel();
    super.dispose();
  }
}
