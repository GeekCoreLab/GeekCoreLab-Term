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
  int? _pendingStartLine;
  final StringBuffer _outputBuffer = StringBuffer();

  static final RegExp _promptRegex = RegExp(
    r'(?:^|[\r\n])(?:[\w.\-]+@[\w.\-]+:[^#$]*[#$]|\$ |# )\s*$',
  );

  /// Called when user inputs characters into terminal
  void notifyUserInput(String input) {
    if (input.contains('\r') || input.contains('\n')) {
      _inputBuffer += input.split(RegExp(r'[\r\n]')).first;
      _handleCommandEntered(_inputBuffer);
      _inputBuffer = '';
    } else {
      _inputBuffer += input;
      if (_inputBuffer.length > 500) {
        _inputBuffer = _inputBuffer.substring(_inputBuffer.length - 500);
      }
    }
  }

  void _handleCommandEntered(String cmd) {
    final trimmed = cmd.trim();
    final type = TerminalCommandChartParser.matchCommandType(trimmed);
    if (type != null) {
      _pendingCommand = trimmed;
      _pendingStartLine = terminal.buffer.absoluteCursorY;
      _outputBuffer.clear();
    }
  }

  /// Called as raw output text arrives from terminal stream
  void observeOutput(String chunk) {
    final stripped = chunk.replaceAll(RegExp(r'\x1b\[[0-9;]*[a-zA-Z]|\x1b\].*?(\x07|\x1b\\)'), '');

    if (_pendingCommand == null) {
      // Check if command echo appears in the output
      final lines = stripped.split(RegExp(r'[\r\n]+'));
      for (final line in lines) {
        final trimmed = line.trim();
        final type = TerminalCommandChartParser.matchCommandType(trimmed);
        if (type != null) {
          _pendingCommand = trimmed;
          _pendingStartLine = terminal.buffer.absoluteCursorY;
          _outputBuffer.clear();
          break;
        }
      }
      return;
    }

    _outputBuffer.write(stripped);

    // If prompt is detected, the command output has finished
    if (_promptRegex.hasMatch(stripped.trimRight()) ||
        stripped.contains('\r\nroot@') ||
        stripped.contains('\r\n') && (stripped.endsWith('\$ ') || stripped.endsWith('# '))) {
      _finishPendingBlock();
    }
  }

  void _finishPendingBlock() {
    if (_pendingCommand == null) return;
    final cmd = _pendingCommand!;
    final start = _pendingStartLine ?? math.max(0, terminal.buffer.absoluteCursorY - 1);
    final end = math.max(start, terminal.buffer.absoluteCursorY);
    final output = _outputBuffer.toString();

    _pendingCommand = null;
    _pendingStartLine = null;
    _outputBuffer.clear();

    final type = TerminalCommandChartParser.matchCommandType(cmd);
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
    _blocks.clear();
    _pendingCommand = null;
    _pendingStartLine = null;
    _outputBuffer.clear();
    _inputBuffer = '';
    _updateHiddenLines();
    notifyListeners();
  }
}
