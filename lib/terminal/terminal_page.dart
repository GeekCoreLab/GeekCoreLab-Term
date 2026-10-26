import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geekcore_term/src/rust/api/terminal.dart';
import 'package:xterm/xterm.dart';

class LocalTerminalPage extends StatefulWidget {
  const LocalTerminalPage({super.key});

  @override
  State<LocalTerminalPage> createState() => _LocalTerminalPageState();
}

class _LocalTerminalPageState extends State<LocalTerminalPage> {
  late final Terminal _terminal;
  late final TerminalController _terminalController;
  StreamSubscription<String>? _outputSubscription;
  final BytesBuilder _pendingInput = BytesBuilder(copy: false);
  Future<void> _inputWriteQueue = Future<void>.value();
  Timer? _inputFlushTimer;

  int? _sessionId;
  int _columns = 100;
  int _rows = 30;
  bool _starting = true;
  String _status = '正在启动系统 shell';
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _terminalController = TerminalController();
    _terminal = Terminal(
      maxLines: 10000,
      onOutput: _queueInput,
      onResize: _handleResize,
    );

    WidgetsBinding.instance.endOfFrame.then((_) {
      if (mounted) _startShell();
    });
  }

  Future<void> _startShell() async {
    if (_starting && _sessionId != null) return;

    setState(() {
      _starting = true;
      _status = '正在启动系统 shell';
      _errorMessage = null;
    });

    try {
      final sessionId = await startLocalShell(cols: _columns, rows: _rows);
      if (!mounted) {
        unawaited(closeLocalShell(sessionId: sessionId));
        return;
      }

      _sessionId = sessionId;
      _outputSubscription = readLocalShellOutput(sessionId: sessionId)
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(
            _terminal.write,
            onError: (Object error, StackTrace stackTrace) {
              _handleShellError(sessionId, error);
            },
            onDone: () => _handleShellExit(sessionId),
          );

      setState(() {
        _starting = false;
        _status = '本地终端已连接';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _status = '系统 shell 启动失败';
        _errorMessage = error.toString();
      });
      _terminal.write('\r\n[启动失败] $error\r\n');
    }
  }

  Future<void> _restartShell() async {
    await _stopShell();
    _terminal.write('\r\n[正在重新启动本地 shell]\r\n');
    await _startShell();
  }

  Future<void> _stopShell() async {
    _inputFlushTimer?.cancel();
    _inputFlushTimer = null;
    _flushInput();
    await _inputWriteQueue;

    final sessionId = _sessionId;
    _sessionId = null;
    final outputSubscription = _outputSubscription;
    _outputSubscription = null;

    if (sessionId != null) {
      try {
        await closeLocalShell(sessionId: sessionId);
      } catch (_) {
        // The shell may already have exited.
      }
    }
    await outputSubscription?.cancel();
  }

  void _queueInput(String value) {
    if (_sessionId == null) return;
    _pendingInput.add(utf8.encode(value));
    _inputFlushTimer ??= Timer(const Duration(milliseconds: 12), _flushInput);
  }

  void _flushInput() {
    _inputFlushTimer?.cancel();
    _inputFlushTimer = null;

    final sessionId = _sessionId;
    if (sessionId == null || _pendingInput.isEmpty) return;

    final data = _pendingInput.takeBytes();
    _inputWriteQueue = _inputWriteQueue
        .then((_) => writeLocalShellInput(sessionId: sessionId, data: data))
        .catchError((Object error) {
          if (!mounted) return;
          setState(() {
            _errorMessage = error.toString();
            _status = '终端输入失败';
          });
        });
  }

  void _handleResize(int columns, int rows, int pixelWidth, int pixelHeight) {
    _columns = columns.clamp(1, 1000);
    _rows = rows.clamp(1, 500);
    final sessionId = _sessionId;
    if (sessionId == null) return;

    unawaited(
      resizeLocalShell(
        sessionId: sessionId,
        cols: _columns,
        rows: _rows,
      ).catchError((Object error) {
        if (!mounted) return;
        setState(() => _errorMessage = error.toString());
      }),
    );
  }

  void _handleShellError(int sessionId, Object error) {
    if (!mounted || _sessionId != sessionId) return;
    setState(() {
      _status = '终端输出错误';
      _errorMessage = error.toString();
    });
    _terminal.write('\r\n[终端输出错误] $error\r\n');
  }

  void _handleShellExit(int sessionId) {
    if (_sessionId == sessionId) {
      _sessionId = null;
      _outputSubscription = null;
      if (mounted) {
        setState(() {
          _starting = false;
          _status = '系统 shell 已退出';
        });
      }
    }
    unawaited(closeLocalShell(sessionId: sessionId));
  }

  Future<void> _handleSecondaryTap() async {
    final selection = _terminalController.selection;
    if (selection != null) {
      final text = _terminal.buffer.getText(selection);
      _terminalController.clearSelection();
      await Clipboard.setData(ClipboardData(text: text));
      return;
    }

    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null) _terminal.paste(text);
  }

  Color _statusColor(ColorScheme colors) {
    if (_errorMessage != null) return colors.error;
    if (_starting) return colors.tertiary;
    return _sessionId == null ? colors.onSurfaceVariant : colors.primary;
  }

  @override
  void dispose() {
    _inputFlushTimer?.cancel();
    final sessionId = _sessionId;
    final outputSubscription = _outputSubscription;
    _sessionId = null;
    _outputSubscription = null;
    unawaited(_disposeSession(sessionId, outputSubscription));
    _terminalController.dispose();
    super.dispose();
  }

  Future<void> _disposeSession(
    int? sessionId,
    StreamSubscription<String>? outputSubscription,
  ) async {
    if (sessionId != null) {
      try {
        await closeLocalShell(sessionId: sessionId);
      } catch (_) {
        // Ignore cleanup errors during widget disposal.
      }
    }
    await outputSubscription?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.terminal_rounded),
            SizedBox(width: 12),
            Text('Geekcore Term'),
          ],
        ),
        actions: [
          Icon(Icons.circle, size: 10, color: _statusColor(colors)),
          const SizedBox(width: 8),
          Text(_status),
          const SizedBox(width: 12),
          IconButton(
            tooltip: '重新启动 shell',
            onPressed: _starting ? null : _restartShell,
            icon: const Icon(Icons.restart_alt_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          if (_errorMessage != null)
            MaterialBanner(
              content: Text(_errorMessage!),
              leading: Icon(Icons.error_outline, color: colors.error),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _errorMessage = null),
                  child: const Text('关闭'),
                ),
              ],
            ),
          Expanded(
            child: ColoredBox(
              color: const Color(0xFF0B0E0C),
              child: TerminalView(
                _terminal,
                controller: _terminalController,
                autofocus: true,
                // Keep Flutter's text-input connection active for IBus/Fcitx
                // composition on Linux, including Wayland sessions.
                hardwareKeyboardOnly: false,
                keyboardType: TextInputType.multiline,
                onKeyEvent: _handleTerminalKeyEvent,
                autoResize: true,
                backgroundOpacity: 1,
                padding: const EdgeInsets.all(12),
                textStyle: const TerminalStyle(
                  fontSize: 14,
                  fontFamily: 'monospace',
                ),
                onSecondaryTapDown: (details, offset) {
                  unawaited(_handleSecondaryTap());
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  KeyEventResult _handleTerminalKeyEvent(FocusNode _, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;

    final controlPressed = HardwareKeyboard.instance.isControlPressed;
    final altPressed = HardwareKeyboard.instance.isAltPressed;
    final metaPressed = HardwareKeyboard.instance.isMetaPressed;
    // Linux may report AltGr as Ctrl+Alt; it produces text and must go through
    // TextInputClient just like other printable keys.
    final hasCommandModifier = metaPressed || controlPressed != altPressed;

    final label = event.logicalKey.keyLabel;
    final hasPrintableCharacter =
        _containsPrintableCharacter(event.character) ||
        _isSinglePrintableCharacter(label);

    // Printable input is delivered by Flutter's TextInputClient, which is
    // required for IME composition. Letting xterm also translate the same
    // hardware event sends committed text to the shell more than once.
    if (!hasCommandModifier && hasPrintableCharacter) {
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  bool _containsPrintableCharacter(String? value) {
    if (value == null) return false;
    return value.runes.any((rune) => rune >= 0x20 && rune != 0x7f);
  }

  bool _isSinglePrintableCharacter(String value) {
    final runes = value.runes;
    if (runes.length != 1) return false;
    final rune = runes.first;
    return rune >= 0x20 && rune != 0x7f;
  }
}
