import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geekcore_term/src/rust/api/terminal.dart';
import 'package:geekcore_term/terminal/session_store.dart';
import 'package:xterm/xterm.dart';

class LocalTerminalPage extends StatefulWidget {
  const LocalTerminalPage({super.key});

  @override
  State<LocalTerminalPage> createState() => _LocalTerminalPageState();
}

class _LocalTerminalPageState extends State<LocalTerminalPage> {
  final List<_TerminalTab> _tabs = [];
  final SessionStore _sessionStore = SessionStore();
  final TextEditingController _sessionSearchController =
      TextEditingController();
  late final Future<void> _recordsReady;
  List<SessionRecord> _savedSessions = [];
  List<SessionRecord> _recentSessions = [];
  String _sessionSearch = '';
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
    _recordsReady = _loadSessionRecords();
  }

  Future<void> _loadSessionRecords() async {
    try {
      final saved = await _sessionStore.loadSaved();
      final recent = await _sessionStore.loadRecent();
      if (!mounted) return;
      setState(() {
        _savedSessions = saved;
        _recentSessions = recent;
      });
    } catch (error) {
      if (mounted) _showMessage('读取会话记录失败：$error', isError: true);
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
        ),
      );
  }

  _TerminalTab _createTabState(_TerminalConnection connection) {
    final id = _nextTabId++;
    final title = switch (connection.kind) {
      _ConnectionKind.local => '终端 $id',
      _ConnectionKind.serial => '串口 ${connection.address}',
      _ConnectionKind.telnet =>
        'Telnet ${connection.address}:${connection.port}',
    };
    final tab = _TerminalTab(id: id, title: title, connection: connection);
    tab.terminal = Terminal(
      maxLines: 10000,
      onOutput: (value) => _queueInput(tab, value),
      onResize: (columns, rows, pixelWidth, pixelHeight) {
        _handleResize(tab, columns, rows);
      },
    );
    return tab;
  }

  void _addLocalShellTab() =>
      _addConnectionTab(const _TerminalConnection.local());

  void _addConnectionTab(_TerminalConnection connection) {
    final tab = _createTabState(connection);
    setState(() {
      _tabs.add(tab);
      _activeTabId = tab.id;
    });
    _focusTab(tab);
    unawaited(_startSession(tab));
  }

  _TerminalConnection _connectionFromRecord(SessionRecord record) =>
      switch (record.protocol) {
        SessionProtocol.serial => _TerminalConnection.serial(
          record.address,
          record.port,
          dataBits: record.dataBits,
          parity: record.parity,
          stopBits: record.stopBits,
          flowControl: record.flowControl,
        ),
        SessionProtocol.telnet => _TerminalConnection.telnet(
          record.address,
          record.port,
        ),
      };

  Future<void> _recordConnection(_TerminalConnection connection) async {
    if (connection.kind == _ConnectionKind.local) return;
    await _recordsReady;
    final now = DateTime.now();
    var sessionName = connection.displayName;
    for (final record in _savedSessions) {
      if (record.endpointKey == connection.endpointKey) {
        sessionName = record.name;
        break;
      }
    }
    final recentRecord = SessionRecord(
      id: connection.endpointKey,
      name: sessionName,
      protocol: connection.kind == _ConnectionKind.serial
          ? SessionProtocol.serial
          : SessionProtocol.telnet,
      address: connection.address,
      port: connection.port,
      dataBits: connection.dataBits,
      parity: connection.parity,
      stopBits: connection.stopBits,
      flowControl: connection.flowControl,
      lastConnectedAt: now,
    );
    final updated = [
      recentRecord,
      ..._recentSessions.where(
        (record) => record.endpointKey != recentRecord.endpointKey,
      ),
    ].take(20).toList();
    if (mounted) setState(() => _recentSessions = updated);
    try {
      await _sessionStore.saveRecent(updated);
    } catch (error) {
      _showMessage('无法保存最近连接：$error', isError: true);
    }
  }

  Future<void> _saveConnectionRecord(
    _TerminalConnection connection, {
    String? suggestedName,
  }) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) =>
          _SessionNameDialog(initialName: suggestedName ?? connection.address),
    );
    if (!mounted || name == null) return;
    await _storeSavedConnection(connection, name);
  }

  Future<void> _storeSavedConnection(
    _TerminalConnection connection,
    String name,
  ) async {
    await _recordsReady;
    final existingIndex = _savedSessions.indexWhere(
      (record) => record.endpointKey == connection.endpointKey,
    );
    final existing = existingIndex < 0 ? null : _savedSessions[existingIndex];
    final savedRecord = SessionRecord(
      id: existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      protocol: connection.kind == _ConnectionKind.serial
          ? SessionProtocol.serial
          : SessionProtocol.telnet,
      address: connection.address,
      port: connection.port,
      dataBits: connection.dataBits,
      parity: connection.parity,
      stopBits: connection.stopBits,
      flowControl: connection.flowControl,
      lastConnectedAt: existing?.lastConnectedAt ?? DateTime.now(),
    );
    final updated = [..._savedSessions];
    if (existingIndex < 0) {
      updated.insert(0, savedRecord);
    } else {
      updated[existingIndex] = savedRecord;
    }
    try {
      await _sessionStore.saveSaved(updated);
      if (!mounted) return;
      setState(() => _savedSessions = updated);
      _showMessage('已保存会话“$name”');
    } catch (error) {
      _showMessage('保存会话失败：$error', isError: true);
    }
  }

  Future<void> _handleRecordAction(
    SessionRecord record,
    _RecordAction action,
    bool saved,
  ) async {
    switch (action) {
      case _RecordAction.save:
        await _saveConnectionRecord(
          _connectionFromRecord(record),
          suggestedName: record.name,
        );
        return;
      case _RecordAction.rename:
        final name = await showDialog<String>(
          context: context,
          builder: (_) => _SessionNameDialog(initialName: record.name),
        );
        if (!mounted || name == null) return;
        final updated = _savedSessions
            .map(
              (item) => item.id == record.id ? item.copyWith(name: name) : item,
            )
            .toList();
        try {
          await _sessionStore.saveSaved(updated);
          if (mounted) setState(() => _savedSessions = updated);
        } catch (error) {
          _showMessage('重命名会话失败：$error', isError: true);
        }
        return;
      case _RecordAction.delete:
        final updated = _savedSessions
            .where((item) => item.id != record.id)
            .toList();
        try {
          await _sessionStore.saveSaved(updated);
          if (mounted) setState(() => _savedSessions = updated);
        } catch (error) {
          _showMessage('删除会话失败：$error', isError: true);
        }
        return;
      case _RecordAction.removeRecent:
        final updated = _recentSessions
            .where((item) => item.endpointKey != record.endpointKey)
            .toList();
        try {
          await _sessionStore.saveRecent(updated);
          if (mounted) setState(() => _recentSessions = updated);
        } catch (error) {
          _showMessage('删除最近连接失败：$error', isError: true);
        }
        return;
    }
  }

  Future<void> _handleNewSession(_NewSessionAction action) async {
    switch (action) {
      case _NewSessionAction.local:
        _addLocalShellTab();
        return;
      case _NewSessionAction.serial:
        await _showConnectionDialog(
          initialProtocol: _ConnectionKind.serial,
          mode: _ConnectionDialogMode.addSession,
        );
        return;
      case _NewSessionAction.telnet:
        await _showConnectionDialog(
          initialProtocol: _ConnectionKind.telnet,
          mode: _ConnectionDialogMode.addSession,
        );
        return;
      case _NewSessionAction.quickConnect:
        await _showConnectionDialog(
          initialProtocol: _ConnectionKind.telnet,
          mode: _ConnectionDialogMode.quickConnect,
        );
        return;
      case _NewSessionAction.addSession:
        await _showConnectionDialog(
          initialProtocol: _ConnectionKind.telnet,
          mode: _ConnectionDialogMode.addSession,
        );
        return;
    }
  }

  Future<void> _showConnectionDialog({
    required _ConnectionKind initialProtocol,
    required _ConnectionDialogMode mode,
  }) async {
    final result = await showDialog<_ConnectionDialogResult>(
      context: context,
      builder: (_) =>
          _ConnectionDialog(initialProtocol: initialProtocol, mode: mode),
    );
    if (result == null || !mounted) return;
    final saveAsName = result.saveAsName;
    if (saveAsName != null) {
      await _storeSavedConnection(result.connection, saveAsName);
    }
    if (mounted) _addConnectionTab(result.connection);
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

  Future<void> _startSession(_TerminalTab tab) async {
    if (tab.isClosed || tab.starting) return;

    tab.starting = true;
    tab.status = tab.connection.openingStatus;
    tab.errorMessage = null;
    _refresh(tab);

    try {
      final connection = tab.connection;
      final sessionId = switch (connection.kind) {
        _ConnectionKind.local => await startLocalShell(
          cols: tab.columns,
          rows: tab.rows,
        ),
        _ConnectionKind.serial => await startSerialSession(
          portName: connection.address,
          baudRate: connection.port,
          dataBits: connection.dataBits,
          parity: connection.parity,
          stopBits: connection.stopBits,
          flowControl: connection.flowControl,
        ),
        _ConnectionKind.telnet => await startTelnetSession(
          host: connection.address,
          port: connection.port,
          cols: tab.columns,
          rows: tab.rows,
        ),
      };
      if (tab.isClosed) {
        unawaited(closeTerminalSession(sessionId: sessionId));
        return;
      }

      tab.sessionId = sessionId;
      unawaited(_recordConnection(connection));
      tab.outputSubscription = readTerminalOutput(sessionId: sessionId)
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(
            tab.terminal.write,
            onError: (Object error, StackTrace stackTrace) {
              _handleSessionError(tab, sessionId, error);
            },
            onDone: () => _handleSessionExit(tab, sessionId),
          );

      tab.starting = false;
      tab.status = tab.connection.connectedStatus;
      _refresh(tab);
    } catch (error) {
      if (tab.isClosed) return;
      tab.starting = false;
      tab.status = '${tab.connection.displayName}连接失败';
      tab.errorMessage = error.toString();
      tab.terminal.write('\r\n[启动失败] $error\r\n');
      _refresh(tab);
    }
  }

  Future<void> _restartSession(_TerminalTab tab) async {
    if (tab.isClosed || tab.starting || tab.restarting) return;
    tab.restarting = true;
    tab.starting = true;
    tab.status = '正在重新连接${tab.connection.displayName}';
    _refresh(tab);
    try {
      await _stopSession(tab);
      if (tab.isClosed) return;
      tab.terminal.write('\r\n[正在重新连接${tab.connection.displayName}]\r\n');
      tab.restarting = false;
      await _startSession(tab);
    } finally {
      tab.restarting = false;
    }
  }

  Future<void> _stopSession(_TerminalTab tab) async {
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
        await closeTerminalSession(sessionId: sessionId);
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
        .then((_) => writeTerminalInput(sessionId: sessionId, data: data))
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
      resizeTerminalSession(
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

  void _handleSessionError(_TerminalTab tab, int sessionId, Object error) {
    if (tab.isClosed || tab.sessionId != sessionId) return;
    tab.status = '${tab.connection.displayName}输出错误';
    tab.errorMessage = error.toString();
    tab.terminal.write('\r\n[${tab.connection.displayName}输出错误] $error\r\n');
    _refresh(tab);
  }

  void _handleSessionExit(_TerminalTab tab, int sessionId) {
    if (tab.sessionId == sessionId) {
      tab.sessionId = null;
      tab.outputSubscription = null;
      tab.starting = false;
      tab.status = '${tab.connection.displayName}已断开';
      _refresh(tab);
    }
    unawaited(closeTerminalSession(sessionId: sessionId));
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
        await closeTerminalSession(sessionId: sessionId);
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
    _sessionSearchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final activeTab = _activeTab;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 62,
        titleSpacing: 16,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.terminal_rounded),
            SizedBox(width: 9),
            Text('Geekcore Term', style: TextStyle(fontSize: 17)),
          ],
        ),
        actions: [
          _ToolbarAction(
            icon: Icons.terminal_rounded,
            label: '本地终端',
            onPressed: _addLocalShellTab,
          ),
          _ToolbarAction(
            icon: Icons.usb_rounded,
            label: '串口',
            onPressed: () =>
                unawaited(_handleNewSession(_NewSessionAction.serial)),
          ),
          _ToolbarAction(
            icon: Icons.lan_rounded,
            label: 'Telnet',
            onPressed: () =>
                unawaited(_handleNewSession(_NewSessionAction.telnet)),
          ),
          const SizedBox(width: 8),
          VerticalDivider(
            width: 1,
            indent: 14,
            endIndent: 14,
            color: colors.outlineVariant,
          ),
          const SizedBox(width: 12),
          Icon(Icons.circle, size: 10, color: _statusColor(activeTab, colors)),
          const SizedBox(width: 8),
          SizedBox(
            width: 150,
            child: Text(
              activeTab?.status ?? '准备就绪',
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          if (activeTab != null) ...[
            const SizedBox(width: 8),
            IconButton(
              tooltip: '重新连接当前会话',
              onPressed: activeTab.starting || activeTab.restarting
                  ? null
                  : () => _restartSession(activeTab),
              icon: const Icon(Icons.restart_alt_rounded),
            ),
          ],
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: () =>
                unawaited(_handleNewSession(_NewSessionAction.quickConnect)),
            icon: const Icon(Icons.bolt_rounded, size: 18),
            label: const Text('快速连接'),
          ),
          const SizedBox(width: 14),
        ],
      ),
      body: Row(
        children: [
          _buildSessionSidebar(colors),
          VerticalDivider(width: 1, thickness: 1, color: colors.outlineVariant),
          Expanded(
            child: Column(
              children: [
                _buildTabBar(colors),
                Expanded(
                  child: _tabs.isEmpty
                      ? _buildHomeWorkspace(colors)
                      : IndexedStack(
                          index: _tabs.indexWhere(
                            (tab) => tab.id == _activeTabId,
                          ),
                          children: [
                            for (final tab in _tabs)
                              _buildTerminalPane(tab, colors),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionSidebar(ColorScheme colors) {
    final query = _sessionSearch.trim().toLowerCase();
    bool matches(SessionRecord record) =>
        query.isEmpty ||
        record.name.toLowerCase().contains(query) ||
        record.address.toLowerCase().contains(query) ||
        record.endpointLabel.toLowerCase().contains(query);
    final saved = _savedSessions.where(matches).toList();
    final recent = _recentSessions.where(matches).toList();

    return SizedBox(
      width: 260,
      child: ColoredBox(
        color: const Color(0xFF131816),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '会话记录',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '新建会话',
                    onPressed: () => unawaited(
                      _handleNewSession(_NewSessionAction.addSession),
                    ),
                    icon: const Icon(Icons.add_rounded),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextField(
                controller: _sessionSearchController,
                onChanged: (value) => setState(() => _sessionSearch = value),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '搜索会话',
                  prefixIcon: const Icon(Icons.search_rounded, size: 19),
                  suffixIcon: _sessionSearch.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清除搜索',
                          onPressed: () {
                            _sessionSearchController.clear();
                            setState(() => _sessionSearch = '');
                          },
                          icon: const Icon(Icons.close_rounded, size: 17),
                        ),
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                children: [
                  _buildSessionSectionHeader('已保存', saved.length),
                  if (saved.isEmpty)
                    _buildSessionPlaceholder(
                      query.isEmpty ? '保存常用连接后会显示在这里' : '没有匹配的会话',
                      colors,
                    )
                  else
                    for (final record in saved)
                      _buildSessionRecordTile(
                        record,
                        saved: true,
                        colors: colors,
                      ),
                  const SizedBox(height: 10),
                  _buildRecentSectionHeader(recent.length, query.isEmpty),
                  if (recent.isEmpty)
                    _buildSessionPlaceholder(
                      query.isEmpty ? '连接过的设备会显示在这里' : '没有匹配的会话',
                      colors,
                    )
                  else
                    for (final record in recent)
                      _buildSessionRecordTile(
                        record,
                        saved: false,
                        colors: colors,
                      ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
              child: Text(
                '会话配置保存在本机，不包含登录密码',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionSectionHeader(String label, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          Text('$count', style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildRecentSectionHeader(int count, bool showClear) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 2, 4),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              '最近连接',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          Text('$count', style: const TextStyle(fontSize: 11)),
          if (showClear && count > 0)
            IconButton(
              tooltip: '清除最近连接',
              visualDensity: VisualDensity.compact,
              onPressed: _clearRecentSessions,
              icon: const Icon(Icons.delete_sweep_outlined, size: 17),
            ),
        ],
      ),
    );
  }

  Widget _buildSessionPlaceholder(String text, ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
      ),
    );
  }

  Widget _buildSessionRecordTile(
    SessionRecord record, {
    required bool saved,
    required ColorScheme colors,
  }) {
    final protocolIcon = record.protocol == SessionProtocol.serial
        ? Icons.usb_rounded
        : Icons.lan_rounded;
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(vertical: -1),
      contentPadding: const EdgeInsets.only(left: 10, right: 2),
      leading: Icon(protocolIcon, size: 19, color: colors.primary),
      title: Text(
        record.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        record.endpointLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
      ),
      onTap: () => _addConnectionTab(_connectionFromRecord(record)),
      trailing: PopupMenuButton<_RecordAction>(
        tooltip: '会话操作',
        onSelected: (action) =>
            unawaited(_handleRecordAction(record, action, saved)),
        itemBuilder: (context) => [
          if (!saved)
            const PopupMenuItem(
              value: _RecordAction.save,
              child: Text('保存到会话记录'),
            ),
          if (saved)
            const PopupMenuItem(
              value: _RecordAction.rename,
              child: Text('重命名'),
            ),
          if (saved)
            const PopupMenuItem(
              value: _RecordAction.delete,
              child: Text('删除会话'),
            ),
          if (!saved)
            const PopupMenuItem(
              value: _RecordAction.removeRecent,
              child: Text('从最近连接移除'),
            ),
        ],
        icon: const Icon(Icons.more_vert_rounded, size: 19),
      ),
    );
  }

  Future<void> _clearRecentSessions() async {
    try {
      await _sessionStore.saveRecent(const []);
      if (mounted) setState(() => _recentSessions = []);
    } catch (error) {
      _showMessage('清除最近连接失败：$error', isError: true);
    }
  }

  Widget _buildTabBar(ColorScheme colors) {
    return Material(
      color: const Color(0xFF151A17),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            Expanded(
              child: _tabs.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: Text(
                        '主页',
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    )
                  : SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final tab in _tabs) _buildTab(tab, colors),
                        ],
                      ),
                    ),
            ),
            const SizedBox(width: 12),
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

  Widget _buildHomeWorkspace(ColorScheme colors) {
    final recent = _recentSessions.take(6).toList();
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.terminal_rounded, size: 36, color: colors.primary),
                  const SizedBox(width: 14),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Geekcore Term',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '从顶部工具栏创建连接，或从会话记录中重新打开常用连接。',
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 36),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '最近连接',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (recent.isNotEmpty)
                    TextButton.icon(
                      onPressed: _clearRecentSessions,
                      icon: const Icon(Icons.delete_sweep_outlined, size: 17),
                      label: const Text('清除'),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              if (recent.isEmpty)
                Text(
                  '成功连接过的串口和 Telnet 会显示在这里。',
                  style: TextStyle(color: colors.onSurfaceVariant),
                )
              else
                for (final record in recent)
                  Card(
                    margin: const EdgeInsets.only(bottom: 6),
                    color: const Color(0xFF151A17),
                    child: ListTile(
                      leading: Icon(
                        record.protocol == SessionProtocol.serial
                            ? Icons.usb_rounded
                            : Icons.lan_rounded,
                        color: colors.primary,
                      ),
                      title: Text(record.name),
                      subtitle: Text(record.endpointLabel),
                      trailing: const Icon(Icons.arrow_forward_rounded),
                      onTap: () =>
                          _addConnectionTab(_connectionFromRecord(record)),
                    ),
                  ),
            ],
          ),
        ),
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
        _addLocalShellTab();
        return KeyEventResult.handled;
      }
      if (commandPressed &&
          shiftPressed &&
          event.logicalKey == LogicalKeyboardKey.keyQ) {
        unawaited(_handleNewSession(_NewSessionAction.quickConnect));
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

class _ToolbarAction extends StatelessWidget {
  const _ToolbarAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: onPressed,
    icon: Icon(icon, size: 18),
    label: Text(label),
    style: TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      minimumSize: const Size(0, 42),
    ),
  );
}

enum _NewSessionAction { local, serial, telnet, quickConnect, addSession }

enum _RecordAction { save, rename, delete, removeRecent }

enum _ConnectionKind { local, serial, telnet }

enum _ConnectionDialogMode { quickConnect, addSession }

class _TerminalConnection {
  const _TerminalConnection.local()
    : kind = _ConnectionKind.local,
      address = '',
      port = 0,
      dataBits = 8,
      parity = 'none',
      stopBits = 1,
      flowControl = 'none';

  const _TerminalConnection.serial(
    this.address,
    this.port, {
    this.dataBits = 8,
    this.parity = 'none',
    this.stopBits = 1,
    this.flowControl = 'none',
  }) : kind = _ConnectionKind.serial;

  const _TerminalConnection.telnet(this.address, this.port)
    : kind = _ConnectionKind.telnet,
      dataBits = 8,
      parity = 'none',
      stopBits = 1,
      flowControl = 'none';

  final _ConnectionKind kind;
  final String address;
  // Serial uses this for baud rate; Telnet uses the TCP port.
  final int port;
  final int dataBits;
  final String parity;
  final int stopBits;
  final String flowControl;

  String get displayName => switch (kind) {
    _ConnectionKind.local => '本地终端',
    _ConnectionKind.serial => '串口 $address',
    _ConnectionKind.telnet => 'Telnet $address:$port',
  };

  String get openingStatus => switch (kind) {
    _ConnectionKind.local => '正在启动本地 shell',
    _ConnectionKind.serial => '正在打开串口 $address',
    _ConnectionKind.telnet => '正在连接 Telnet $address:$port',
  };

  String get connectedStatus => switch (kind) {
    _ConnectionKind.local => '本地终端已连接',
    _ConnectionKind.serial => '串口已连接 · $address',
    _ConnectionKind.telnet => 'Telnet 已连接 · $address:$port',
  };

  String get endpointKey => switch (kind) {
    _ConnectionKind.serial =>
      '${kind.name}:${address.trim().toLowerCase()}:$port:$dataBits:$parity:$stopBits:$flowControl',
    _ConnectionKind.telnet =>
      '${kind.name}:${address.trim().toLowerCase()}:$port',
    _ConnectionKind.local => kind.name,
  };
}

class _ConnectionDialogResult {
  const _ConnectionDialogResult({required this.connection, this.saveAsName});

  final _TerminalConnection connection;
  final String? saveAsName;
}

class _ConnectionDialog extends StatefulWidget {
  const _ConnectionDialog({required this.initialProtocol, required this.mode});

  final _ConnectionKind initialProtocol;
  final _ConnectionDialogMode mode;

  @override
  State<_ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends State<_ConnectionDialog> {
  static const _baudRatePresets = [
    110,
    300,
    600,
    1200,
    2400,
    4800,
    9600,
    14400,
    19200,
    38400,
    57600,
    76800,
    115200,
    128000,
    230400,
    256000,
    460800,
    500000,
    921600,
    1000000,
    1500000,
    2000000,
    3000000,
    4000000,
  ];

  final _formKey = GlobalKey<FormState>();
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '23');
  final _deviceController = TextEditingController();
  final _baudController = TextEditingController(text: '115200');
  final _profileNameController = TextEditingController();
  late _ConnectionKind _selectedProtocol;
  late Future<List<SerialPortEntry>> _portsFuture;
  int? _selectedBaudPreset = 115200;
  int _dataBits = 8;
  String _parity = 'none';
  int _stopBits = 1;
  String _flowControl = 'none';

  @override
  void initState() {
    super.initState();
    _selectedProtocol = widget.initialProtocol;
    _portsFuture = listSerialPorts();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _deviceController.dispose();
    _baudController.dispose();
    _profileNameController.dispose();
    super.dispose();
  }

  void _connect() {
    if (!_formKey.currentState!.validate()) return;
    final connection = switch (_selectedProtocol) {
      _ConnectionKind.serial => _TerminalConnection.serial(
        _deviceController.text.trim(),
        int.parse(_baudController.text.trim()),
        dataBits: _dataBits,
        parity: _parity,
        stopBits: _stopBits,
        flowControl: _flowControl,
      ),
      _ConnectionKind.telnet => _TerminalConnection.telnet(
        _hostController.text.trim(),
        int.parse(_portController.text.trim()),
      ),
      _ConnectionKind.local => const _TerminalConnection.local(),
    };
    final enteredName = _profileNameController.text.trim();
    Navigator.of(context).pop(
      _ConnectionDialogResult(
        connection: connection,
        saveAsName: widget.mode == _ConnectionDialogMode.addSession
            ? (enteredName.isEmpty ? connection.address : enteredName)
            : null,
      ),
    );
  }

  Widget _buildProtocolItem({
    required _ConnectionKind protocol,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final selected = _selectedProtocol == protocol;
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: ListTile(
        selected: selected,
        selectedTileColor: colors.primaryContainer.withValues(alpha: 0.65),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        leading: Icon(icon, color: selected ? colors.primary : null),
        title: Text(title),
        subtitle: Text(subtitle),
        onTap: () => setState(() => _selectedProtocol = protocol),
      ),
    );
  }

  Widget _buildTelnetFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: _hostController,
          autofocus: _selectedProtocol == _ConnectionKind.telnet,
          decoration: const InputDecoration(
            labelText: '主机名或 IP 地址',
            hintText: '192.168.1.10',
            prefixIcon: Icon(Icons.dns_rounded),
          ),
          validator: (value) =>
              value == null || value.trim().isEmpty ? '请输入主机名或 IP 地址' : null,
          onFieldSubmitted: (_) => _connect(),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: 220,
          child: TextFormField(
            controller: _portController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'TCP 端口',
              hintText: '23',
              prefixIcon: Icon(Icons.numbers_rounded),
            ),
            validator: (value) {
              final port = int.tryParse(value?.trim() ?? '');
              return port == null || port < 1 || port > 65535
                  ? '端口范围为 1 到 65535'
                  : null;
            },
            onFieldSubmitted: (_) => _connect(),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '默认端口 23。连接后可在终端中完成远端登录交互。',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildSerialFields() {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: _deviceController,
          autofocus: _selectedProtocol == _ConnectionKind.serial,
          decoration: InputDecoration(
            labelText: '串口设备',
            hintText: '/dev/ttyUSB0 或 COM3',
            prefixIcon: const Icon(Icons.usb_rounded),
            suffixIcon: IconButton(
              tooltip: '刷新串口列表',
              onPressed: () => setState(() => _portsFuture = listSerialPorts()),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ),
          validator: (value) =>
              value == null || value.trim().isEmpty ? '请输入串口设备或选择检测到的端口' : null,
          onChanged: (_) => setState(() {}),
          onFieldSubmitted: (_) => _connect(),
        ),
        const SizedBox(height: 8),
        FutureBuilder<List<SerialPortEntry>>(
          future: _portsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const LinearProgressIndicator();
            }
            if (snapshot.hasError) {
              return Text(
                '枚举串口失败：${snapshot.error}',
                style: TextStyle(color: colors.error),
              );
            }
            final ports = snapshot.data ?? const <SerialPortEntry>[];
            if (ports.isEmpty) {
              return Text(
                '未发现串口。也可以手动输入设备路径。',
                style: TextStyle(color: colors.onSurfaceVariant),
              );
            }
            final currentPort =
                ports.any(
                  (port) => port.portName == _deviceController.text.trim(),
                )
                ? _deviceController.text.trim()
                : null;
            return InputDecorator(
              decoration: const InputDecoration(
                labelText: '检测到的串口',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 3,
                ),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: currentPort,
                  isExpanded: true,
                  hint: const Text('选择串口设备'),
                  items: [
                    for (final port in ports)
                      DropdownMenuItem(
                        value: port.portName,
                        child: Text(
                          '${port.portName} (${port.deviceName})',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (portName) {
                    if (portName == null) return;
                    setState(() => _deviceController.text = portName);
                  },
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextFormField(
                controller: _baudController,
                keyboardType: const TextInputType.numberWithOptions(),
                decoration: const InputDecoration(
                  labelText: '波特率',
                  hintText: '例如 115200 或自定义数值',
                ),
                validator: (value) {
                  final baudRate = int.tryParse(value?.trim() ?? '');
                  return baudRate == null ||
                          baudRate < 1 ||
                          baudRate > 4294967295
                      ? '请输入有效的正整数波特率'
                      : null;
                },
                onChanged: (value) {
                  final baudRate = int.tryParse(value.trim());
                  setState(() {
                    _selectedBaudPreset = _baudRatePresets.contains(baudRate)
                        ? baudRate
                        : null;
                  });
                },
                onFieldSubmitted: (_) => _connect(),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 170,
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: '常用预设',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 3,
                  ),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    value: _selectedBaudPreset,
                    isExpanded: true,
                    hint: const Text('选择波特率'),
                    items: [
                      for (final baudRate in _baudRatePresets)
                        DropdownMenuItem(
                          value: baudRate,
                          child: Text('$baudRate'),
                        ),
                    ],
                    onChanged: (baudRate) {
                      if (baudRate == null) return;
                      setState(() {
                        _selectedBaudPreset = baudRate;
                        _baudController.text = '$baudRate';
                      });
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Card(
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            leading: const Icon(Icons.tune_rounded),
            title: const Text('高级设置'),
            subtitle: Text(
              '$_dataBits 位 · ${_parityLabel(_parity)} · $_stopBits 个停止位',
            ),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  SizedBox(
                    width: 140,
                    child: DropdownButtonFormField<int>(
                      initialValue: _dataBits,
                      decoration: const InputDecoration(labelText: '数据位'),
                      items: [
                        for (final bits in [5, 6, 7, 8])
                          DropdownMenuItem(value: bits, child: Text('$bits 位')),
                      ],
                      onChanged: (value) {
                        if (value != null) setState(() => _dataBits = value);
                      },
                    ),
                  ),
                  SizedBox(
                    width: 140,
                    child: DropdownButtonFormField<String>(
                      initialValue: _parity,
                      decoration: const InputDecoration(labelText: '校验位'),
                      items: const [
                        DropdownMenuItem(value: 'none', child: Text('无校验')),
                        DropdownMenuItem(value: 'odd', child: Text('奇校验')),
                        DropdownMenuItem(value: 'even', child: Text('偶校验')),
                      ],
                      onChanged: (value) {
                        if (value != null) setState(() => _parity = value);
                      },
                    ),
                  ),
                  SizedBox(
                    width: 140,
                    child: DropdownButtonFormField<int>(
                      initialValue: _stopBits,
                      decoration: const InputDecoration(labelText: '停止位'),
                      items: const [
                        DropdownMenuItem(value: 1, child: Text('1 位')),
                        DropdownMenuItem(value: 2, child: Text('2 位')),
                      ],
                      onChanged: (value) {
                        if (value != null) setState(() => _stopBits = value);
                      },
                    ),
                  ),
                  SizedBox(
                    width: 160,
                    child: DropdownButtonFormField<String>(
                      initialValue: _flowControl,
                      decoration: const InputDecoration(labelText: '流控'),
                      items: const [
                        DropdownMenuItem(value: 'none', child: Text('无流控')),
                        DropdownMenuItem(
                          value: 'software',
                          child: Text('软件流控'),
                        ),
                        DropdownMenuItem(
                          value: 'hardware',
                          child: Text('硬件流控'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) setState(() => _flowControl = value);
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _parityLabel(String value) => switch (value) {
    'odd' => '奇校验',
    'even' => '偶校验',
    _ => '无校验',
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Dialog(
      child: SizedBox(
        width: 900,
        height: 590,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 14, 18),
              child: Row(
                children: [
                  Icon(
                    widget.mode == _ConnectionDialogMode.quickConnect
                        ? Icons.bolt_rounded
                        : Icons.add_link_rounded,
                    color: colors.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.mode == _ConnectionDialogMode.quickConnect
                          ? '快速连接'
                          : '新建会话',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.outlineVariant),
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: 220,
                    child: ColoredBox(
                      color: colors.surfaceContainerLow,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(18, 18, 12, 8),
                            child: Text(
                              '连接协议',
                              style: TextStyle(
                                color: colors.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          _buildProtocolItem(
                            protocol: _ConnectionKind.telnet,
                            icon: Icons.lan_rounded,
                            title: 'Telnet',
                            subtitle: '主机和 TCP 端口',
                          ),
                          _buildProtocolItem(
                            protocol: _ConnectionKind.serial,
                            icon: Icons.usb_rounded,
                            title: '串口',
                            subtitle: '设备和串口参数',
                          ),
                        ],
                      ),
                    ),
                  ),
                  VerticalDivider(width: 1, color: colors.outlineVariant),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(26, 22, 26, 12),
                      child: Form(
                        key: _formKey,
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                _selectedProtocol == _ConnectionKind.serial
                                    ? '串口连接'
                                    : 'Telnet 连接',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 20),
                              if (_selectedProtocol == _ConnectionKind.serial)
                                _buildSerialFields()
                              else
                                _buildTelnetFields(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.outlineVariant),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
              child: Row(
                children: [
                  if (widget.mode == _ConnectionDialogMode.addSession) ...[
                    const Text('备注名'),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 250,
                      child: TextField(
                        controller: _profileNameController,
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: '可选，留空时使用地址作为名称',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ] else
                    Expanded(
                      child: Text(
                        '快速连接不会加入已保存会话，可从最近连接中再次打开。',
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _connect,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('连接'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionNameDialog extends StatefulWidget {
  const _SessionNameDialog({required this.initialName});

  final String initialName;

  @override
  State<_SessionNameDialog> createState() => _SessionNameDialogState();
}

class _SessionNameDialogState extends State<_SessionNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('保存会话'),
      content: SizedBox(
        width: 380,
        child: TextField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '会话名称',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _save(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}

class _TerminalTab {
  _TerminalTab({
    required this.id,
    required this.title,
    required this.connection,
  }) : terminalController = TerminalController(),
       focusNode = FocusNode();

  final int id;
  final String title;
  final _TerminalConnection connection;
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
  String status = '正在连接';
  String? errorMessage;
}
