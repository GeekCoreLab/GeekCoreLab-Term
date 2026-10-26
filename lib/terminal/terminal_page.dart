import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
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
  final List<_TerminalTab> _tabs = [];
  int _nextTabId = 1;
  int? _activeTabId;

  _TerminalTab? get _activeTab {
    for (final tab in _tabs) {
      if (tab.id == _activeTabId) return tab;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    final tab = _createTabState();
    _tabs.add(tab);
    _activeTabId = tab.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || tab.isClosed) return;
      tab.focusNode.requestFocus();
      unawaited(_startShell(tab));
    });
  }

  _TerminalTab _createTabState() {
    final id = _nextTabId++;
    final tab = _TerminalTab(id: id, title: '终端 $id');
    tab.terminal = Terminal(
      maxLines: 10000,
      onOutput: (value) => _queueInput(tab, value),
      onResize: (columns, rows, pixelWidth, pixelHeight) {
        _handleResize(tab, columns, rows);
      },
    );
    return tab;
  }

  void _addTab() {
    final tab = _createTabState();
    setState(() {
      _tabs.add(tab);
      _activeTabId = tab.id;
    });
    _focusTab(tab);
    unawaited(_startShell(tab));
  }

  void _focusTab(_TerminalTab tab) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !tab.isClosed) tab.focusNode.requestFocus();
    });
  }

  void _selectTab(_TerminalTab tab) {
    if (_activeTabId == tab.id) {
      tab.focusNode.requestFocus();
      return;
    }
    setState(() => _activeTabId = tab.id);
    _focusTab(tab);
  }

  void _selectAdjacentTab(int direction) {
    if (_tabs.length < 2) return;
    final currentIndex = _tabs.indexWhere((tab) => tab.id == _activeTabId);
    final start = currentIndex < 0 ? 0 : currentIndex;
    final nextIndex = (start + direction + _tabs.length) % _tabs.length;
    _selectTab(_tabs[nextIndex]);
  }

  void _closeTab(_TerminalTab tab) {
    final index = _tabs.indexOf(tab);
    if (index < 0) return;

    final wasActive = tab.id == _activeTabId;
    _TerminalTab? nextTab;
    if (wasActive && _tabs.length > 1) {
      nextTab = _tabs[index == _tabs.length - 1 ? index - 1 : index + 1];
    }

    tab.isClosed = true;
    tab.inputFlushTimer?.cancel();
    tab.inputFlushTimer = null;
    tab.pendingInput.takeBytes();
    tab.focusNode.unfocus();

    setState(() {
      _tabs.removeAt(index);
      if (wasActive) _activeTabId = nextTab?.id;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      tab.focusNode.dispose();
      tab.terminalController.dispose();
    });
    unawaited(_disposeTab(tab));
    if (nextTab != null) _focusTab(nextTab);
  }

  Future<void> _startShell(_TerminalTab tab) async {
    if (tab.isClosed || tab.starting) return;

    tab.starting = true;
    tab.status = '正在启动系统 shell';
    tab.errorMessage = null;
    _refresh(tab);

    try {
      final sessionId = await startLocalShell(
        cols: tab.columns,
        rows: tab.rows,
      );
      if (tab.isClosed) {
        unawaited(closeLocalShell(sessionId: sessionId));
        return;
      }

      tab.sessionId = sessionId;
      tab.outputSubscription = readLocalShellOutput(sessionId: sessionId)
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(
            tab.terminal.write,
            onError: (Object error, StackTrace stackTrace) {
              _handleShellError(tab, sessionId, error);
            },
            onDone: () => _handleShellExit(tab, sessionId),
          );

      tab.starting = false;
      tab.status = '本地终端已连接';
      _refresh(tab);
    } catch (error) {
      if (tab.isClosed) return;
      tab.starting = false;
      tab.status = '系统 shell 启动失败';
      tab.errorMessage = error.toString();
      tab.terminal.write('\r\n[启动失败] $error\r\n');
      _refresh(tab);
    }
  }

  Future<void> _restartShell(_TerminalTab tab) async {
    if (tab.isClosed || tab.starting || tab.restarting) return;
    tab.restarting = true;
    tab.starting = true;
    tab.status = '正在重新启动系统 shell';
    _refresh(tab);
    try {
      await _stopShell(tab);
      if (tab.isClosed) return;
      tab.terminal.write('\r\n[正在重新启动本地 shell]\r\n');
      tab.restarting = false;
      await _startShell(tab);
    } finally {
      tab.restarting = false;
    }
  }

  Future<void> _stopShell(_TerminalTab tab) async {
    tab.inputFlushTimer?.cancel();
    tab.inputFlushTimer = null;
    _flushInput(tab);
    await tab.inputWriteQueue;

    final sessionId = tab.sessionId;
    tab.sessionId = null;
    final outputSubscription = tab.outputSubscription;
    tab.outputSubscription = null;
    tab.starting = false;

    if (sessionId != null) {
      try {
        await closeLocalShell(sessionId: sessionId);
      } catch (_) {
        // The shell may already have exited.
      }
    }
    await outputSubscription?.cancel();
  }

  void _queueInput(_TerminalTab tab, String value) {
    if (tab.isClosed ||
        tab.starting ||
        tab.restarting ||
        tab.sessionId == null) {
      return;
    }
    tab.pendingInput.add(utf8.encode(value));
    tab.inputFlushTimer ??= Timer(
      const Duration(milliseconds: 12),
      () => _flushInput(tab),
    );
  }

  void _flushInput(_TerminalTab tab) {
    tab.inputFlushTimer?.cancel();
    tab.inputFlushTimer = null;

    final sessionId = tab.sessionId;
    if (sessionId == null || tab.pendingInput.isEmpty) return;

    final data = tab.pendingInput.takeBytes();
    tab.inputWriteQueue = tab.inputWriteQueue
        .then((_) => writeLocalShellInput(sessionId: sessionId, data: data))
        .catchError((Object error) {
          if (tab.isClosed) return;
          tab.errorMessage = error.toString();
          tab.status = '终端输入失败';
          _refresh(tab);
        });
  }

  void _handleResize(_TerminalTab tab, int columns, int rows) {
    tab.columns = columns.clamp(1, 1000);
    tab.rows = rows.clamp(1, 500);
    final sessionId = tab.sessionId;
    if (sessionId == null) return;

    unawaited(
      resizeLocalShell(
        sessionId: sessionId,
        cols: tab.columns,
        rows: tab.rows,
      ).catchError((Object error) {
        if (tab.isClosed) return;
        tab.errorMessage = error.toString();
        _refresh(tab);
      }),
    );
  }

  void _handleShellError(_TerminalTab tab, int sessionId, Object error) {
    if (tab.isClosed || tab.sessionId != sessionId) return;
    tab.status = '终端输出错误';
    tab.errorMessage = error.toString();
    tab.terminal.write('\r\n[终端输出错误] $error\r\n');
    _refresh(tab);
  }

  void _handleShellExit(_TerminalTab tab, int sessionId) {
    if (tab.sessionId == sessionId) {
      tab.sessionId = null;
      tab.outputSubscription = null;
      tab.starting = false;
      tab.status = '系统 shell 已退出';
      _refresh(tab);
    }
    unawaited(closeLocalShell(sessionId: sessionId));
  }

  Future<void> _handleSecondaryTap(_TerminalTab tab) async {
    final selection = tab.terminalController.selection;
    if (selection != null) {
      final text = tab.terminal.buffer.getText(selection);
      tab.terminalController.clearSelection();
      await Clipboard.setData(ClipboardData(text: text));
      return;
    }

    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && !tab.isClosed) tab.terminal.paste(text);
  }

  void _refresh(_TerminalTab tab) {
    if (mounted && !tab.isClosed && _tabs.contains(tab)) setState(() {});
  }

  Color _statusColor(_TerminalTab? tab, ColorScheme colors) {
    if (tab == null) return colors.onSurfaceVariant;
    if (tab.errorMessage != null) return colors.error;
    if (tab.starting || tab.restarting) return colors.tertiary;
    return tab.sessionId == null ? colors.onSurfaceVariant : colors.primary;
  }

  Future<void> _disposeTab(_TerminalTab tab) async {
    await tab.inputWriteQueue;
    final sessionId = tab.sessionId;
    tab.sessionId = null;
    if (sessionId != null) {
      try {
        await closeLocalShell(sessionId: sessionId);
      } catch (_) {
        // Ignore cleanup errors when a tab is closed.
      }
    }
    await tab.outputSubscription?.cancel();
    tab.outputSubscription = null;
  }

  @override
  void dispose() {
    for (final tab in _tabs) {
      tab.isClosed = true;
      tab.inputFlushTimer?.cancel();
      tab.focusNode.dispose();
      tab.terminalController.dispose();
      unawaited(_disposeTab(tab));
    }
    _tabs.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final activeTab = _activeTab;

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
          Icon(Icons.circle, size: 10, color: _statusColor(activeTab, colors)),
          const SizedBox(width: 8),
          Text(activeTab?.status ?? '没有打开的会话'),
          const SizedBox(width: 12),
          IconButton(
            tooltip: '重新启动当前 shell',
            onPressed:
                activeTab == null || activeTab.starting || activeTab.restarting
                ? null
                : () => _restartShell(activeTab),
            icon: const Icon(Icons.restart_alt_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          _buildTabBar(colors),
          Expanded(
            child: _tabs.isEmpty
                ? _buildEmptyState(colors)
                : IndexedStack(
                    index: _tabs.indexWhere((tab) => tab.id == _activeTabId),
                    children: [
                      for (final tab in _tabs) _buildTerminalPane(tab, colors),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar(ColorScheme colors) {
    return Material(
      color: const Color(0xFF151A17),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [for (final tab in _tabs) _buildTab(tab, colors)],
                ),
              ),
            ),
            IconButton(
              tooltip: '新建终端 (Ctrl+Shift+T)',
              onPressed: _addTab,
              icon: const Icon(Icons.add_rounded),
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Widget _buildTab(_TerminalTab tab, ColorScheme colors) {
    final selected = tab.id == _activeTabId;
    return Padding(
      padding: const EdgeInsets.only(left: 5, top: 5, bottom: 5),
      child: Material(
        color: selected ? colors.surfaceContainerHighest : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: () => _selectTab(tab),
          child: SizedBox(
            width: 158,
            child: Padding(
              padding: const EdgeInsets.only(left: 10, right: 4),
              child: Row(
                children: [
                  Icon(
                    Icons.terminal_rounded,
                    size: 16,
                    color: selected ? colors.primary : colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(tab.title, overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 6),
                  Icon(Icons.circle, size: 8, color: _statusColor(tab, colors)),
                  IconButton(
                    tooltip: '关闭 ${tab.title} (Ctrl+W)',
                    onPressed: () => _closeTab(tab),
                    icon: const Icon(Icons.close_rounded, size: 15),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 28,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTerminalPane(_TerminalTab tab, ColorScheme colors) {
    return SizedBox.expand(
      key: ValueKey(tab.id),
      child: Column(
        children: [
          if (tab.errorMessage != null)
            MaterialBanner(
              content: Text(tab.errorMessage!),
              leading: Icon(Icons.error_outline, color: colors.error),
              actions: [
                TextButton(
                  onPressed: () => setState(() => tab.errorMessage = null),
                  child: const Text('关闭'),
                ),
              ],
            ),
          Expanded(
            child: ColoredBox(
              color: const Color(0xFF0B0E0C),
              child: TerminalView(
                tab.terminal,
                key: ValueKey('terminal-${tab.id}'),
                controller: tab.terminalController,
                focusNode: tab.focusNode,
                autofocus: false,
                // Keep Flutter's text input connection active for IBus/Fcitx
                // composition on Linux, including Wayland sessions.
                hardwareKeyboardOnly: false,
                keyboardType: TextInputType.multiline,
                onKeyEvent: (focusNode, event) =>
                    _handleTerminalKeyEvent(tab, focusNode, event),
                autoResize: true,
                backgroundOpacity: 1,
                padding: const EdgeInsets.all(12),
                textStyle: const TerminalStyle(
                  fontSize: 14,
                  fontFamily: 'monospace',
                ),
                onSecondaryTapDown: (details, offset) {
                  unawaited(_handleSecondaryTap(tab));
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme colors) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.terminal_rounded, size: 42, color: colors.outline),
          const SizedBox(height: 12),
          const Text('没有打开的终端'),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _addTab,
            icon: const Icon(Icons.add_rounded),
            label: const Text('新建终端'),
          ),
        ],
      ),
    );
  }

  KeyEventResult _handleTerminalKeyEvent(
    _TerminalTab tab,
    FocusNode _,
    KeyEvent event,
  ) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;

    if (event is KeyDownEvent) {
      final commandPressed = defaultTargetPlatform == TargetPlatform.macOS
          ? HardwareKeyboard.instance.isMetaPressed
          : HardwareKeyboard.instance.isControlPressed;
      final shiftPressed = HardwareKeyboard.instance.isShiftPressed;
      if (commandPressed &&
          shiftPressed &&
          event.logicalKey == LogicalKeyboardKey.keyT) {
        _addTab();
        return KeyEventResult.handled;
      }
      if (commandPressed &&
          !shiftPressed &&
          event.logicalKey == LogicalKeyboardKey.keyW) {
        _closeTab(tab);
        return KeyEventResult.handled;
      }
      if (commandPressed && event.logicalKey == LogicalKeyboardKey.tab) {
        _selectAdjacentTab(shiftPressed ? -1 : 1);
        return KeyEventResult.handled;
      }
    }

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
    // required for IME composition. Avoid sending committed text twice.
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

class _TerminalTab {
  _TerminalTab({required this.id, required this.title})
    : terminalController = TerminalController(),
      focusNode = FocusNode();

  final int id;
  final String title;
  final TerminalController terminalController;
  final FocusNode focusNode;
  final BytesBuilder pendingInput = BytesBuilder(copy: false);
  late final Terminal terminal;

  Future<void> inputWriteQueue = Future<void>.value();
  StreamSubscription<String>? outputSubscription;
  Timer? inputFlushTimer;
  int? sessionId;
  int columns = 100;
  int rows = 30;
  bool starting = false;
  bool restarting = false;
  bool isClosed = false;
  String status = '正在启动系统 shell';
  String? errorMessage;
}
