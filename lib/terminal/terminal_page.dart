import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64;
import 'package:geekcore_term/src/rust/api/terminal.dart';
import 'package:geekcore_term/terminal/port_knock_transport.dart';
import 'package:geekcore_term/terminal/remote_file_browser.dart';
import 'package:geekcore_term/terminal/remote_file_transfer.dart';
import 'package:geekcore_term/terminal/ssh_credential_store.dart';
import 'package:geekcore_term/terminal/ssh_config.dart';
import 'package:geekcore_term/terminal/ssh_config_file.dart';
import 'package:geekcore_term/terminal/ssh_config_import_dialog.dart';
import 'package:geekcore_term/terminal/ssh_agent.dart';
import 'package:geekcore_term/terminal/ssh_identity_file.dart';
import 'package:geekcore_term/terminal/ssh_proxy.dart';
import 'package:geekcore_term/terminal/ssh_tunnel.dart';
import 'package:geekcore_term/terminal/ssh_terminal_environment.dart';
import 'package:geekcore_term/terminal/ssh_jump_port_knock.dart';
import 'package:geekcore_term/terminal/ssh_remote_monitor_dialog.dart';
import 'package:geekcore_term/terminal/ssh_remote_monitor_bar.dart';
import 'package:geekcore_term/terminal/ssh_remote_monitor_cache.dart';
import 'package:geekcore_term/terminal/network_diagnostics_dialog.dart';
import 'package:geekcore_term/terminal/command_snippet_dialog.dart';
import 'package:geekcore_term/terminal/command_macro_dialog.dart';
import 'package:geekcore_term/terminal/session_store.dart';
import 'package:geekcore_term/terminal/terminal_search_dialog.dart';
import 'package:geekcore_term/terminal/terminal_transcript.dart';
import 'package:geekcore_term/terminal/terminal_assistant.dart';
import 'package:geekcore_term/terminal/terminal_assistant_panel.dart';
import 'package:geekcore_term/terminal/terminal_input_targets.dart';
import 'package:geekcore_term/terminal/terminal_keyword_highlights.dart';
import 'package:geekcore_term/terminal/terminal_shortcuts.dart';
import 'package:geekcore_term/terminal/terminal_tab_order.dart';
import 'package:geekcore_term/terminal/terminal_link.dart';
import 'package:geekcore_term/terminal/startup_session_group.dart';
import 'package:geekcore_term/terminal/terminal_macro.dart';
import 'package:geekcore_term/terminal/terminal_input_recording.dart';
import 'package:geekcore_term/terminal/terminal_recorded_macro_dialog.dart';
import 'package:geekcore_term/terminal/terminal_chart_coordinator.dart';
import 'package:geekcore_term/terminal/terminal_chart_overlay.dart';
import 'package:geekcore_term/terminal/websocket_ssh_socket.dart';
import 'package:geekcore_term/settings/app_settings.dart';
import 'package:geekcore_term/settings/settings_page.dart';
import 'package:geekcore_term/settings/window_state.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm/xterm.dart';

class LocalTerminalPage extends StatefulWidget {
  const LocalTerminalPage({required this.settings, super.key});

  final AppSettingsController settings;

  @override
  State<LocalTerminalPage> createState() => _LocalTerminalPageState();
}

class _LocalTerminalPageState extends State<LocalTerminalPage> {
  final List<_TerminalTab> _tabs = [];
  final SessionStore _sessionStore = SessionStore();
  final SshCredentialStore _sshCredentialStore = SshCredentialStore();
  final TextEditingController _sessionSearchController =
      TextEditingController();
  late final Future<void> _recordsReady;
  List<SessionRecord> _savedSessions = [];
  List<SessionRecord> _recentSessions = [];
  List<String> _sessionGroups = [];
  String _sessionSearch = '';
  String? _sessionGroupFilter;
  _SidebarSection _sidebarSection = _SidebarSection.sessions;
  bool _assistantPanelOpen = true;
  bool _clearingAppData = false;
  int _nextTabId = 1;
  int? _activeTabId;
  TerminalSplitMode _splitMode = TerminalSplitMode.none;
  bool _layoutInteractionStarted = false;
  bool _startupGroupLaunchStarted = false;
  bool _startupGroupLaunchInProgress = false;
  bool _startupGroupLaunchCancelled = false;
  final List<int> _splitTabIds = [];
  bool _broadcastSplitInput = false;
  final Set<int> _multiExecTabIds = {};

  bool get _hasInputBroadcast =>
      (_broadcastSplitInput && _splitMode != TerminalSplitMode.none) ||
      _multiExecTabIds.isNotEmpty;

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
      final groups = await _sessionStore.loadGroups();
      final splitMode = await _sessionStore.loadTerminalSplitMode();
      if (!mounted) return;
      setState(() {
        _savedSessions = saved;
        _recentSessions = recent;
        if (!_layoutInteractionStarted && _tabs.isEmpty) {
          _splitMode = splitMode;
        }
        _sessionGroups = {
          ...groups,
          ...saved
              .map((record) => record.group)
              .where((group) => group.isNotEmpty),
        }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      });
      final startupGroup = widget.settings.startupSessionGroup;
      if (startupGroup != null) {
        unawaited(_launchStartupSessionGroup(saved, startupGroup));
      }
    } catch (error) {
      if (mounted) _showMessage('读取会话记录失败：$error', isError: true);
    }
  }

  Future<void> _openSettings() async {
    await _recordsReady;
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => AppSettingsPage(
          settings: widget.settings,
          onClearAppData: _clearAppData,
          sessionGroups: _sessionGroups,
        ),
      ),
    );
    if (!mounted) return;
    final rules = widget.settings.terminalKeywordRules;
    for (final tab in _tabs) {
      if (!tab.isClosed) {
        tab.keywordHighlighter.refreshNow(tab.terminal, rules);
      }
    }
  }

  Future<void> _openSshTunnelManager(_TerminalTab tab) async {
    final client = tab.sshClient;
    if (kIsWeb) {
      _showMessage('浏览器版本不支持本机 SSH 隧道监听');
      return;
    }
    if (client == null) {
      _showMessage('先连接 SSH/SFTP 会话，再管理隧道');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => _SshTunnelManagerDialog(
        client: client,
        sessionTitle: tab.title,
        tunnels: tab.tunnels,
      ),
    );
    if (mounted) _refresh(tab);
  }

  Future<void> _openSshRemoteMonitor(_TerminalTab tab) async {
    final client = tab.sshClient;
    if (client == null || tab.isClosed) {
      _showMessage('先连接 SSH 会话，再打开远程监控');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => SshRemoteMonitorDialog(
        cache: tab.remoteMonitorCache,
        sessionTitle: tab.title,
      ),
    );
    if (mounted && !tab.isClosed) _refresh(tab);
  }

  Future<void> _openNetworkDiagnostics() async {
    await showDialog<void>(
      context: context,
      builder: (_) => const NetworkDiagnosticsDialog(),
    );
  }

  Future<void> _openTerminalSearch([_TerminalTab? requestedTab]) async {
    final tab = requestedTab ?? _activeTab;
    if (tab == null) {
      _showMessage('先打开一个终端标签，再搜索输出');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => TerminalSearchDialog(
        terminal: tab.terminal,
        terminalController: tab.terminalController,
        scrollController: tab.scrollController,
      ),
    );
  }

  Future<void> _openCommandSnippetManager() async {
    try {
      await _recordsReady;
      final snippets = await _sessionStore.loadCommandSnippets();
      if (!mounted) return;
      final tab = _activeTab;
      await showDialog<void>(
        context: context,
        builder: (_) => CommandSnippetManagerDialog(
          initialSnippets: snippets,
          sessionTitle: tab?.title,
          canInsert: tab?.isConnected == true,
          isBroadcasting: _hasInputBroadcast,
          onSave: _sessionStore.saveCommandSnippets,
          onInsert: (snippet) async {
            if (tab == null || tab.isClosed || !tab.isConnected) return false;
            if (_hasInputBroadcast) {
              final confirmed = await _confirmBroadcastPaste(
                '命令片段“${snippet.name}”会粘贴到输入广播目标；片段为单行，不会自动按 Enter 执行。',
                confirmLabel: '继续粘贴',
              );
              if (!mounted || tab.isClosed || confirmed != true) return false;
            }
            tab.focusNode.requestFocus();
            tab.terminal.paste(snippet.command);
            _showMessage('已将“${snippet.name}”粘贴到终端；未发送 Enter');
            return true;
          },
        ),
      );
    } catch (error) {
      _showMessage('读取命令片段失败：$error', isError: true);
    }
  }

  Future<void> _openTerminalMacroManager() async {
    try {
      await _recordsReady;
      final macros = await _sessionStore.loadTerminalMacros();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => TerminalMacroManagerDialog(
          initialMacros: macros,
          canRun: _activeTab?.isConnected == true,
          onSave: _sessionStore.saveTerminalMacros,
          onRun: _reviewAndRunTerminalMacro,
        ),
      );
    } catch (error) {
      _showMessage('读取命令宏失败：$error', isError: true);
    }
  }

  Future<void> _openTerminalRecordedMacroManager() async {
    try {
      await _recordsReady;
      final macros = await _sessionStore.loadRecordedMacros();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => TerminalRecordedMacroManagerDialog(
          initialMacros: macros,
          onSave: _sessionStore.saveRecordedMacros,
          onRun: _reviewAndRunTerminalRecordedMacro,
        ),
      );
    } catch (error) {
      _showMessage('读取录制宏失败：$error', isError: true);
    }
  }

  Future<void> _toggleTerminalInputRecording(_TerminalTab tab) async {
    final recorder = tab.inputRecorder;
    if (recorder.isRecording) {
      recorder.stop();
      _refresh(tab);
      if (!recorder.hasData) {
        recorder.clear();
        _showMessage('录制已停止，没有捕获到输入');
        return;
      }
      await _saveRecordedInputMacro(tab);
      return;
    }
    if (recorder.hasData) {
      await _saveRecordedInputMacro(tab);
      return;
    }
    if (tab.isClosed || !tab.isConnected) {
      _showMessage('请先连接终端会话，再开始录制', isError: true);
      return;
    }

    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('开始录制键盘输入？'),
        content: const Text(
          '录制会捕获键盘、中文输入和粘贴内容，包括可能输入的密码或令牌。保存的宏位于本机应用数据中且不会加密。请不要录入敏感信息。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('开始录制'),
          ),
        ],
      ),
    );
    if (!mounted || accepted != true) return;
    if (tab.isClosed || !tab.isConnected || recorder.hasData) {
      _showMessage('会话状态已变化，未开始录制', isError: true);
      return;
    }
    recorder.start();
    _refresh(tab);
    _showMessage('正在录制 ${tab.title} 的键盘输入；再次点击可停止并保存');
  }

  Future<bool> _saveRecordedInputMacro(_TerminalTab tab) async {
    final recorder = tab.inputRecorder;
    recorder.stop();
    if (!recorder.hasData) {
      recorder.clear();
      _refresh(tab);
      _showMessage('录制内容为空');
      return true;
    }

    final draft = recorder.snapshot(id: 'recording-preview', name: '预览');
    final name = await showDialog<String>(
      context: context,
      builder: (_) => TerminalRecordedMacroNameDialog(
        preview: draft.preview,
        eventCount: draft.events.length,
        totalBytes: draft.totalBytes,
      ),
    );
    if (!mounted || tab.isClosed) return false;
    if (name == null) {
      _refresh(tab);
      return false;
    }

    try {
      await _recordsReady;
      final macros = await _sessionStore.loadRecordedMacros();
      final normalizedName = name.trim().toLowerCase();
      if (macros.any((macro) => macro.name.toLowerCase() == normalizedName)) {
        _showMessage('已存在同名录制宏，请使用其他名称', isError: true);
        return false;
      }
      if (macros.length >= TerminalRecordedMacro.maxSavedMacros) {
        _showMessage(
          '最多保存 ${TerminalRecordedMacro.maxSavedMacros} 个录制宏；请先删除旧宏',
          isError: true,
        );
        return false;
      }
      final idBase =
          'recorded-${DateTime.now().microsecondsSinceEpoch}-tab-${tab.id}';
      var id = idBase;
      var suffix = 1;
      while (macros.any((macro) => macro.id == id)) {
        id = '$idBase-${suffix++}';
      }
      final macro = recorder.snapshot(id: id, name: name);
      await _sessionStore.saveRecordedMacros([...macros, macro]);
      recorder.clear();
      _refresh(tab);
      _showMessage('已保存录制宏“${macro.name}”');
      return true;
    } catch (error) {
      _showMessage('保存录制宏失败：$error；录制内容仍保留', isError: true);
      return false;
    }
  }

  Future<void> _reviewAndRunTerminalRecordedMacro(
    TerminalRecordedMacro macro,
    TerminalRecordedMacroRunControl runControl,
  ) async {
    final source = _activeTab;
    if (source == null || source.isClosed || !source.isConnected) {
      _showMessage('请先连接一个终端会话', isError: true);
      return;
    }
    final targetIds = terminalInputTargetIds(
      sourceTabId: source.id,
      connectedTabIds: _tabs
          .where((tab) => tab.isConnected && !tab.isClosed)
          .map((tab) => tab.id),
      splitTabIds: _splitTabIds,
      selectedTabIds: _multiExecTabIds,
      broadcastSplitInput:
          _broadcastSplitInput && _splitMode != TerminalSplitMode.none,
    );
    final targets = [
      for (final tab in _tabs)
        if (targetIds.contains(tab.id) && tab.isConnected && !tab.isClosed)
          _TerminalMacroTarget.capture(tab),
    ];
    if (targets.isEmpty) {
      _showMessage('没有可回放宏的已连接终端', isError: true);
      return;
    }

    // Preserve already typed bytes before adding the recorded playback to each
    // session's serialized input queue.
    _flushInput(source);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => TerminalRecordedMacroReviewDialog(
        macro: macro,
        targetNames: targets.map((target) => target.displayName).toList(),
      ),
    );
    if (!mounted || confirmed != true) return;
    if (targets.any((target) => !_isMacroTargetCurrent(target))) {
      _showMessage('目标会话已断开或重连；未回放录制宏', isError: true);
      return;
    }

    var abortRequested = false;
    _TerminalRecordedMacroRunFailure? abortFailure;
    final writes = <Future<void>>[];
    for (final target in targets) {
      final tab = target.tab;
      final operation = tab.inputWriteQueue.then((_) async {
        try {
          await executeTerminalRecordedMacro(
            macro: macro,
            canContinue: (completedEvents) {
              if (abortRequested) return false;
              if (runControl.isCancelled) {
                abortRequested = true;
                abortFailure = _TerminalRecordedMacroRunFailure(
                  target.displayName,
                  completedEvents,
                  '用户停止回放',
                );
                return false;
              }
              if (!_isMacroTargetCurrent(target)) {
                abortRequested = true;
                abortFailure = _TerminalRecordedMacroRunFailure(
                  target.displayName,
                  completedEvents,
                  '会话已断开或重连',
                );
                return false;
              }
              return true;
            },
            write: (input) => _writeMacroInput(target, input),
          );
        } catch (error) {
          if (!abortRequested) {
            abortRequested = true;
            final completedEvents = switch (error) {
              TerminalRecordingStoppedException(:final completedEvents) =>
                completedEvents,
              TerminalRecordingWriteException(:final completedEvents) =>
                completedEvents,
              _ => 0,
            };
            final cause = error is TerminalRecordingWriteException
                ? error.cause
                : error;
            abortFailure = _TerminalRecordedMacroRunFailure(
              target.displayName,
              completedEvents,
              cause.toString(),
            );
          }
        }
      });
      tab.inputWriteQueue = operation.catchError((Object _) {});
      writes.add(operation);
    }
    await Future.wait(writes);
    final failure = abortFailure;
    if (failure != null) {
      _showMessage('录制宏回放已中止：$failure', isError: true);
    } else {
      _showMessage(
        '已向 ${targets.length} 个终端回放“${macro.name}”的 ${macro.events.length} 个输入片段',
      );
    }
  }

  Future<void> _reviewAndRunTerminalMacro(TerminalMacro macro) async {
    final source = _activeTab;
    if (source == null || source.isClosed || !source.isConnected) {
      _showMessage('请先连接一个终端会话', isError: true);
      return;
    }
    final targetIds = terminalInputTargetIds(
      sourceTabId: source.id,
      connectedTabIds: _tabs
          .where((tab) => tab.isConnected && !tab.isClosed)
          .map((tab) => tab.id),
      splitTabIds: _splitTabIds,
      selectedTabIds: _multiExecTabIds,
      broadcastSplitInput:
          _broadcastSplitInput && _splitMode != TerminalSplitMode.none,
    );
    final targets = [
      for (final tab in _tabs)
        if (targetIds.contains(tab.id) && tab.isConnected && !tab.isClosed)
          _TerminalMacroTarget.capture(tab),
    ];
    if (targets.isEmpty) {
      _showMessage('没有可执行宏的已连接终端', isError: true);
      return;
    }

    final TerminalMacroPlan plan;
    if (macro.parameters.isEmpty) {
      plan = macro.prepare(const {});
    } else {
      final prepared = await showDialog<TerminalMacroPlan>(
        context: context,
        builder: (_) => TerminalMacroParametersDialog(macro: macro),
      );
      if (!mounted || prepared == null) return;
      plan = prepared;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => TerminalMacroExecutionReviewDialog(
        macro: macro,
        targetNames: targets.map((target) => target.displayName).toList(),
        plan: plan,
      ),
    );
    if (!mounted || confirmed != true) return;
    if (targets.any((target) => !_isMacroTargetCurrent(target))) {
      _showMessage('目标会话已断开或重连；未发送宏命令', isError: true);
      return;
    }

    var abortRequested = false;
    _TerminalMacroRunFailure? abortFailure;
    final writes = <Future<void>>[];
    for (final target in targets) {
      final tab = target.tab;
      final operation = tab.inputWriteQueue.then((_) async {
        try {
          await executeTerminalMacroCommands(
            macro: macro,
            commands: plan.commands,
            canContinue: (completedCommands) {
              if (abortRequested) return false;
              if (!_isMacroTargetCurrent(target)) {
                abortRequested = true;
                abortFailure = _TerminalMacroRunFailure(
                  target.displayName,
                  completedCommands,
                  '会话已断开或重连',
                );
                return false;
              }
              return true;
            },
            write: (input) => _writeMacroInput(target, input),
          );
        } catch (error) {
          if (!abortRequested) {
            abortRequested = true;
            final completedCommands = switch (error) {
              TerminalMacroStoppedException(:final completedCommands) =>
                completedCommands,
              TerminalMacroWriteException(:final completedCommands) =>
                completedCommands,
              _ => 0,
            };
            final cause = error is TerminalMacroWriteException
                ? error.cause
                : error;
            abortFailure = _TerminalMacroRunFailure(
              target.displayName,
              completedCommands,
              cause.toString(),
            );
          }
        }
      });
      tab.inputWriteQueue = operation.catchError((Object _) {});
      writes.add(operation);
    }
    await Future.wait(writes);
    final failure = abortFailure;
    if (failure != null) {
      _showMessage('宏已中止：$failure', isError: true);
    } else {
      _showMessage(
        '已向 ${targets.length} 个终端发送“${macro.name}”的 ${plan.commands.length} 条命令',
      );
    }
  }

  bool _isMacroTargetCurrent(_TerminalMacroTarget target) {
    final tab = target.tab;
    return _tabs.contains(tab) &&
        !tab.isClosed &&
        !tab.starting &&
        !tab.restarting &&
        tab.isConnected &&
        tab.sessionId == target.sessionId &&
        identical(tab.sshClient, target.sshClient) &&
        identical(tab.sshSession, target.sshSession);
  }

  Future<void> _writeMacroInput(
    _TerminalMacroTarget target,
    Uint8List input,
  ) async {
    if (!_isMacroTargetCurrent(target)) {
      throw StateError('会话已断开或重连');
    }
    final sshSession = target.sshSession;
    if (sshSession != null) {
      await sshSession.stdin.addStream(Stream<Uint8List>.value(input));
      await sshSession.flush();
      return;
    }
    final sessionId = target.sessionId;
    if (sessionId == null) throw StateError('终端会话已关闭');
    await writeTerminalInput(sessionId: sessionId, data: input);
  }

  Future<bool> _confirmBroadcastPaste(
    String description, {
    String confirmLabel = '广播粘贴',
  }) async {
    if (!_hasInputBroadcast) {
      return true;
    }
    final targetIds = <int>{..._multiExecTabIds};
    if (_broadcastSplitInput && _splitMode != TerminalSplitMode.none) {
      targetIds.addAll(_splitTabIds);
    }
    if (_activeTabId case final activeId?) targetIds.add(activeId);
    final targetNames = _tabs
        .where((tab) => targetIds.contains(tab.id))
        .map((tab) => tab.isConnected ? tab.title : '${tab.title}（未连接，会跳过）')
        .join('、');
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('向输入广播目标粘贴？'),
            content: Text('$description\n\n接收会话：$targetNames'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(confirmLabel),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _configureMultiExec() async {
    final selected = _multiExecTabIds.toSet();
    final result = await showDialog<Set<int>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('多会话输入广播'),
          content: SizedBox(
            width: 420,
            height: 320,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '从任一终端输入时，同步发送到选中的已连接会话。粘贴前会再次确认。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: _tabs.isEmpty
                      ? const Center(child: Text('没有打开的终端会话'))
                      : ListView(
                          children: [
                            for (final tab in _tabs)
                              CheckboxListTile(
                                dense: true,
                                value: selected.contains(tab.id),
                                title: Text(
                                  tab.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  tab.isConnected ? tab.status : '未连接',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onChanged: (checked) {
                                  if (checked == true && !tab.isConnected) {
                                    return;
                                  }
                                  setDialogState(() {
                                    if (checked == true) {
                                      selected.add(tab.id);
                                    } else {
                                      selected.remove(tab.id);
                                    }
                                  });
                                },
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                contentPadding: EdgeInsets.zero,
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, <int>{}),
              child: const Text('关闭广播'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, selected.toSet()),
              child: Text('应用 ${selected.length} 个目标'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    final liveIds = _tabs.map((tab) => tab.id).toSet();
    setState(() {
      _multiExecTabIds
        ..clear()
        ..addAll(result.where(liveIds.contains));
    });
  }

  Future<void> _toggleTranscriptLog(_TerminalTab tab) async {
    if (tab.transcript.hasData || tab.transcript.isRecording) {
      await _saveTranscriptLog(tab);
      return;
    }
    tab.transcript.start(
      'Geekcore Term output transcript\n'
      'Session: ${tab.title}\n'
      'Started: ${DateTime.now().toIso8601String()}\n\n',
    );
    _refresh(tab);
    _showMessage('开始记录 ${tab.title} 的终端显示输出');
  }

  Future<bool> _saveTranscriptLog(_TerminalTab tab) async {
    tab.transcript.stop();
    final bytes = tab.transcript.snapshot();
    if (bytes.isEmpty) {
      tab.transcript.clear();
      _refresh(tab);
      _showMessage('终端记录为空');
      return true;
    }
    final fileName =
        'geekcore-term-${DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-')}.log';
    try {
      final path = await FilePicker.saveFile(
        dialogTitle: '保存终端输出记录',
        fileName: fileName,
        bytes: bytes,
      );
      if (!mounted || path == null) return false;
      tab.transcript.clear();
      _refresh(tab);
      _showMessage('已保存终端输出记录');
      return true;
    } catch (error) {
      _showMessage('保存终端记录失败：$error', isError: true);
      return false;
    }
  }

  Future<bool> _confirmTranscriptClose(_TerminalTab tab) async {
    if (!tab.transcript.hasData && !tab.transcript.isRecording) return true;
    if (!tab.transcript.hasData) {
      tab.transcript.clear();
      return true;
    }
    final action = await showDialog<_TranscriptCloseAction>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('保存终端记录？'),
        content: const Text(
          '此标签有未保存的终端输出记录。记录仅捕获显示内容，可能包含 shell 回显的命令；请检查后再分享。',
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(context, _TranscriptCloseAction.cancel),
            child: const Text('取消关闭'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(context, _TranscriptCloseAction.discard),
            child: const Text('丢弃记录'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, _TranscriptCloseAction.save),
            child: const Text('保存并关闭'),
          ),
        ],
      ),
    );
    if (!mounted) return false;
    switch (action) {
      case _TranscriptCloseAction.save:
        return _saveTranscriptLog(tab);
      case _TranscriptCloseAction.discard:
        tab.transcript.clear();
        return true;
      case _TranscriptCloseAction.cancel:
      case null:
        return false;
    }
  }

  Future<bool> _confirmRecordedMacroClose(_TerminalTab tab) async {
    final recorder = tab.inputRecorder;
    if (recorder.isRecording) recorder.stop();
    if (!recorder.hasData) {
      recorder.clear();
      _refresh(tab);
      return true;
    }
    _refresh(tab);
    final action = await showDialog<_TranscriptCloseAction>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('保存录制宏？'),
        content: const Text('此标签有未保存的键盘输入录制。内容可能包含密码或令牌；保存到本机应用数据前请检查。'),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(context, _TranscriptCloseAction.cancel),
            child: const Text('取消关闭'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(context, _TranscriptCloseAction.discard),
            child: const Text('丢弃录制'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, _TranscriptCloseAction.save),
            child: const Text('保存并关闭'),
          ),
        ],
      ),
    );
    if (!mounted) return false;
    switch (action) {
      case _TranscriptCloseAction.save:
        return _saveRecordedInputMacro(tab);
      case _TranscriptCloseAction.discard:
        recorder.clear();
        return true;
      case _TranscriptCloseAction.cancel:
      case null:
        return false;
    }
  }

  void _writeTerminalOutput(_TerminalTab tab, String value) {
    tab.inlineHintTransformer.onFlush ??= (flushedText) {
      if (!tab.isClosed && mounted) {
        tab.terminal.write(flushedText);
      }
    };
    final terminalOutput = widget.settings.terminalAssistantInlineHints
        ? tab.inlineHintTransformer.transform(value)
        : value;
    if (terminalOutput.isNotEmpty) {
      tab.terminal.write(terminalOutput);
    }
    if (!tab.isClosed) {
      tab.keywordHighlighter.schedule(
        tab.terminal,
        widget.settings.terminalKeywordRules,
      );
    }
    if (!tab.isClosed) tab.assistant.observe(value);
    if (!tab.isClosed) tab.chartCoordinator.observeOutput(value);
    final result = tab.transcript.append(value);
    if (result == TranscriptAppendResult.limitReached && !tab.isClosed) {
      _showMessage('终端记录达到 10 MiB 上限，已停止记录', isError: true);
      _refresh(tab);
    }
  }

  Future<void> _clearAppData() async {
    if (_clearingAppData) return;
    _clearingAppData = true;
    try {
      await _recordsReady;
      final tabs = List<_TerminalTab>.of(_tabs);
      for (final tab in tabs) {
        tab.isClosed = true;
        tab.transcript.clear();
        tab.inputRecorder.clear();
        tab.inputFlushTimer?.cancel();
        tab.inputFlushTimer = null;
        tab.pendingInput.takeBytes();
        tab.focusNode.unfocus();
      }

      if (mounted) {
        setState(() {
          _tabs.clear();
          _activeTabId = null;
          _splitMode = TerminalSplitMode.none;
          _splitTabIds.clear();
          _broadcastSplitInput = false;
          _multiExecTabIds.clear();
          _layoutInteractionStarted = true;
        });
      }

      for (final tab in tabs) {
        tab.focusNode.dispose();
        tab.keywordHighlighter.dispose();
        tab.terminalController.dispose();
        tab.scrollController.dispose();
        tab.remoteMonitorCache.dispose();
        tab.assistant.dispose();
        tab.inlineHintTransformer.dispose();
        await _disposeTab(tab);
      }

      WindowStateManager.instance.resetAfterClear();
      await _sshCredentialStore.clearAll();
      await _sessionStore.clear();
      await widget.settings.clearAll();

      if (mounted) {
        setState(() {
          _savedSessions = [];
          _recentSessions = [];
          _sessionGroups = [];
          _sessionSearch = '';
          _sessionSearchController.clear();
        });
      }
    } finally {
      _clearingAppData = false;
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    _replaceNotification(
      message,
      isError: isError,
      duration: const Duration(seconds: 4),
    );
  }

  bool _prepareTerminalLinkOpen(_TerminalTab tab, CellOffset offset) {
    tab.pendingExternalLink = null;
    final keyboard = HardwareKeyboard.instance;
    final modifierPressed = terminalLinkModifierPressed(
      platform: defaultTargetPlatform,
      controlPressed: keyboard.isControlPressed,
      metaPressed: keyboard.isMetaPressed,
    );
    if (!modifierPressed) return false;

    final uri = terminalHttpLinkAtCell(tab.terminal, offset);
    if (uri == null) return false;
    tab.pendingExternalLink = uri;
    return true;
  }

  Future<void> _openTerminalLink(Uri uri) async {
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
        _showMessage('没有可用的浏览器打开链接', isError: true);
      }
    } catch (error) {
      if (mounted) _showMessage('打开链接失败：$error', isError: true);
    }
  }

  void _replaceNotification(
    String message, {
    bool isError = false,
    Duration duration = const Duration(seconds: 2),
  }) {
    if (!mounted) return;
    final colors = Theme.of(context).colorScheme;
    final foreground = isError
        ? colors.onErrorContainer
        : colors.onInverseSurface;
    final messenger = ScaffoldMessenger.of(context);
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              isError
                  ? Icons.error_outline_rounded
                  : Icons.info_outline_rounded,
              size: 19,
              color: foreground,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(message, style: TextStyle(color: foreground)),
            ),
          ],
        ),
        duration: duration,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor: isError
            ? colors.errorContainer
            : colors.inverseSurface,
      ),
    );
  }

  void _notifySessionProgress(
    _TerminalTab tab,
    String message, {
    bool isError = false,
    String? tabStatus,
  }) {
    if (!mounted || tab.isClosed) return;
    final toast = tab.id == _activeTabId ? message : '会话${tab.title}：$message';
    tab.status = tabStatus ?? message;
    _replaceNotification(toast, isError: isError);
    _refresh(tab);
  }

  _TerminalTab _createTabState(_TerminalConnection connection) {
    final id = _nextTabId++;
    final title = switch (connection.kind) {
      _ConnectionKind.local => '终端 $id',
      _ConnectionKind.serial => '串口 ${connection.address}',
      _ConnectionKind.telnet =>
        'Telnet ${connection.address}:${connection.port}',
      _ConnectionKind.ssh => 'SSH ${connection.address}:${connection.port}',
      _ConnectionKind.sftp => 'SFTP ${connection.address}:${connection.port}',
    };
    final tab = _TerminalTab(
      id: id,
      title: connection.sessionTitle ?? title,
      connection: connection,
    );
    tab.terminal = Terminal(
      maxLines: 10000,
      onOutput: (value) => _queueInput(tab, value),
      onUserInput: (value) => _recordTerminalInput(tab, value),
      onResize: (columns, rows, pixelWidth, pixelHeight) {
        _handleResize(tab, columns, rows);
      },
    );
    tab.focusNode.addListener(() => _handleTabFocusChange(tab));
    return tab;
  }

  void _addLocalShellTab() {
    if (kIsWeb) {
      _showMessage('浏览器版本不支持启动本地 Shell');
      return;
    }
    _addConnectionTab(const _TerminalConnection.local());
  }

  Future<void> _launchStartupSessionGroup(
    List<SessionRecord> savedSessions,
    String group,
  ) async {
    if (_startupGroupLaunchStarted) return;
    _startupGroupLaunchStarted = true;
    if (!mounted || _layoutInteractionStarted || _tabs.isNotEmpty) return;

    final sessions = sessionsForStartupGroup(savedSessions, group);
    if (sessions.isEmpty) {
      _showMessage('启动分类“$group”中没有已保存的会话');
      return;
    }
    _startupGroupLaunchInProgress = true;
    try {
      _showMessage('正在按保存顺序启动“$group”分类（${sessions.length} 个会话）');
      await startStartupSessionsInOrder(
        sessions,
        (record) async {
          final tab = _addConnectionTab(
            _connectionFromRecord(record),
            startImmediately: false,
            fromStartupGroup: true,
          );
          await _startSession(tab);
        },
        shouldContinue: () =>
            mounted && !_clearingAppData && !_startupGroupLaunchCancelled,
      );
    } finally {
      _startupGroupLaunchInProgress = false;
    }
  }

  _TerminalTab _addConnectionTab(
    _TerminalConnection connection, {
    bool startImmediately = true,
    bool fromStartupGroup = false,
  }) {
    if (_startupGroupLaunchInProgress && !fromStartupGroup) {
      _startupGroupLaunchCancelled = true;
    }
    final tab = _createTabState(connection);
    _layoutInteractionStarted = true;
    setState(() {
      final activeId = _activeTabId;
      _tabs.add(tab);
      if (_splitMode != TerminalSplitMode.none) {
        final emptySlot =
            List<int>.generate(
              _splitMode.capacity,
              (index) => index,
            ).firstWhere(
              (index) =>
                  index >= _splitTabIds.length ||
                  !_tabs.any(
                    (candidate) => candidate.id == _splitTabIds[index],
                  ),
              orElse: () => -1,
            );
        if (emptySlot >= 0 && emptySlot < _splitTabIds.length) {
          _splitTabIds[emptySlot] = tab.id;
        } else if (emptySlot >= 0) {
          _splitTabIds.add(tab.id);
        } else if (_splitTabIds.isNotEmpty) {
          final activeSlot = activeId == null
              ? -1
              : _splitTabIds.indexOf(activeId);
          _splitTabIds[activeSlot < 0 ? 0 : activeSlot] = tab.id;
        }
      }
      _activeTabId = tab.id;
    });
    _focusTab(tab);
    if (startImmediately) unawaited(_startSession(tab));
    return tab;
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
        SessionProtocol.ssh => _TerminalConnection.ssh(
          record.address,
          record.port,
          sessionTitle: record.name,
          username: record.username,
          identityFile: record.identityFile,
          sshConfigAlias: record.sshConfigAlias,
          jumpHost: record.jumpHost,
          sshProxy: record.sshProxy,
          webSocketUrl: record.webSocketUrl,
          portKnockActions: record.portKnockActions,
          authenticationMode: record.authenticationMode,
        ),
        SessionProtocol.sftp => _TerminalConnection.sftp(
          record.address,
          record.port,
          sessionTitle: record.name,
          username: record.username,
          identityFile: record.identityFile,
          sshConfigAlias: record.sshConfigAlias,
          jumpHost: record.jumpHost,
          sshProxy: record.sshProxy,
          webSocketUrl: record.webSocketUrl,
          portKnockActions: record.portKnockActions,
          authenticationMode: record.authenticationMode,
        ),
      };

  Future<void> _recordConnection(_TerminalConnection connection) async {
    if (connection.kind == _ConnectionKind.local) return;
    await _recordsReady;
    if (!mounted || _clearingAppData) return;
    final now = DateTime.now();
    var sessionName = connection.sessionTitle ?? connection.displayName;
    for (final record in _savedSessions) {
      if (record.endpointKey == connection.endpointKey) {
        sessionName = record.name;
        break;
      }
    }
    final recentRecord = SessionRecord(
      id: connection.endpointKey,
      name: sessionName,
      protocol: connection.sessionProtocol!,
      address: connection.address,
      port: connection.port,
      dataBits: connection.dataBits,
      parity: connection.parity,
      stopBits: connection.stopBits,
      flowControl: connection.flowControl,
      webSocketUrl: connection.webSocketUrl,
      portKnockActions: connection.portKnockActions,
      authenticationMode: connection.authenticationMode,
      username: connection.username,
      identityFile: connection.identityFile,
      sshConfigAlias: connection.sshConfigAlias,
      jumpHost: connection.jumpHost,
      sshProxy: connection.sshProxy,
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
      protocol: connection.sessionProtocol!,
      address: connection.address,
      port: connection.port,
      dataBits: connection.dataBits,
      parity: connection.parity,
      stopBits: connection.stopBits,
      flowControl: connection.flowControl,
      webSocketUrl: connection.webSocketUrl,
      portKnockActions: connection.portKnockActions,
      authenticationMode: connection.authenticationMode,
      username: connection.username,
      identityFile: connection.identityFile,
      sshConfigAlias: connection.sshConfigAlias,
      jumpHost: connection.jumpHost,
      sshProxy: connection.sshProxy,
      group: existing?.group ?? '',
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
      final groups = _sessionGroups.toSet();
      if (savedRecord.group.isNotEmpty) groups.add(savedRecord.group);
      await _sessionStore.saveGroups(groups.toList());
      if (!mounted) return;
      setState(() {
        _savedSessions = updated;
        _sessionGroups = groups.toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      });
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
          builder: (_) =>
              _SessionNameDialog(title: '重命名会话', initialName: record.name),
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
          return;
        }
        if ((record.protocol == SessionProtocol.ssh ||
                record.protocol == SessionProtocol.sftp) &&
            !updated.any(
              (item) => item.credentialKey == record.credentialKey,
            )) {
          try {
            await _sshCredentialStore.delete(record.credentialKey);
          } catch (error) {
            _showMessage('会话已删除，但凭据清理失败：$error', isError: true);
          }
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
      case _RecordAction.moveGroup:
        final groups =
            _savedSessions
                .map((item) => item.group)
                .where((group) => group.isNotEmpty)
                .toSet()
                .toList()
              ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        final group = await showDialog<String>(
          context: context,
          builder: (_) =>
              _SessionGroupDialog(groups: groups, initialGroup: record.group),
        );
        if (!mounted || group == null || group == record.group) return;
        final allGroups = {
          ..._sessionGroups,
          if (group.isNotEmpty) group,
        }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        final updated = _savedSessions
            .map(
              (item) =>
                  item.id == record.id ? item.copyWith(group: group) : item,
            )
            .toList();
        try {
          await _sessionStore.saveSaved(updated);
          await _sessionStore.saveGroups(allGroups);
          if (mounted) {
            setState(() {
              _savedSessions = updated;
              _sessionGroups = allGroups;
            });
          }
        } catch (error) {
          _showMessage('移动会话失败：$error', isError: true);
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
        if (kIsWeb) {
          _showMessage('浏览器版本不支持串口连接');
          return;
        }
        await _showConnectionDialog(
          initialProtocol: _ConnectionKind.serial,
          mode: _ConnectionDialogMode.addSession,
        );
        return;
      case _NewSessionAction.telnet:
        if (kIsWeb) {
          _showMessage('浏览器版本不支持 Telnet 直连');
          return;
        }
        await _showConnectionDialog(
          initialProtocol: _ConnectionKind.telnet,
          mode: _ConnectionDialogMode.addSession,
        );
        return;
      case _NewSessionAction.ssh:
        await _showConnectionDialog(
          initialProtocol: _ConnectionKind.ssh,
          mode: _ConnectionDialogMode.addSession,
        );
        return;
      case _NewSessionAction.sftp:
        await _showConnectionDialog(
          initialProtocol: _ConnectionKind.sftp,
          mode: _ConnectionDialogMode.addSession,
        );
        return;
      case _NewSessionAction.quickConnect:
        await _showConnectionDialog(
          initialProtocol: kIsWeb
              ? _ConnectionKind.ssh
              : _ConnectionKind.telnet,
          mode: _ConnectionDialogMode.quickConnect,
        );
        return;
      case _NewSessionAction.addSession:
        await _showConnectionDialog(
          initialProtocol: kIsWeb
              ? _ConnectionKind.ssh
              : _ConnectionKind.telnet,
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
      builder: (_) => _ConnectionDialog(
        initialProtocol: initialProtocol,
        mode: mode,
        savedSshSessions: [
          for (final record in _savedSessions)
            if ((record.protocol == SessionProtocol.ssh ||
                    record.protocol == SessionProtocol.sftp) &&
                record.jumpHost == null &&
                record.sshProxy == null)
              record,
        ],
      ),
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

  void _handleTabFocusChange(_TerminalTab tab) {
    if (!tab.focusNode.hasFocus || tab.isClosed || !mounted) return;
    _activateTab(tab);
  }

  void _activateTab(_TerminalTab tab) {
    if (tab.isClosed || !mounted) return;
    final isVisible =
        _splitMode == TerminalSplitMode.none || _splitTabIds.contains(tab.id);
    if (_activeTabId == tab.id && isVisible) return;

    setState(() {
      if (_splitMode != TerminalSplitMode.none &&
          !_splitTabIds.contains(tab.id)) {
        final slot = _activeTabId == null
            ? -1
            : _splitTabIds.indexOf(_activeTabId!);
        if (slot >= 0) {
          _splitTabIds[slot] = tab.id;
        } else if (_splitTabIds.length < _splitMode.capacity) {
          _splitTabIds.add(tab.id);
        } else if (_splitTabIds.isNotEmpty) {
          _splitTabIds[0] = tab.id;
        }
      }
      _activeTabId = tab.id;
    });
  }

  void _selectTab(_TerminalTab tab) {
    _activateTab(tab);
    _focusTab(tab);
  }

  void _reorderTabs(int oldIndex, int newIndex) {
    if (oldIndex == newIndex || _tabs.length < 2) return;
    final reordered = reorderListItem(
      _tabs,
      oldIndex: oldIndex,
      newIndex: newIndex,
    );
    setState(() {
      _tabs
        ..clear()
        ..addAll(reordered);
    });
  }

  void _selectAdjacentTab(int direction) {
    if (_tabs.length < 2) return;
    final currentIndex = _tabs.indexWhere((tab) => tab.id == _activeTabId);
    final start = currentIndex < 0 ? 0 : currentIndex;
    final nextIndex = (start + direction + _tabs.length) % _tabs.length;
    _selectTab(_tabs[nextIndex]);
  }

  Future<void> _setSplitMode(TerminalSplitMode mode) async {
    _layoutInteractionStarted = true;
    if (mode == TerminalSplitMode.none) {
      setState(() {
        _splitMode = mode;
        _splitTabIds.clear();
        _broadcastSplitInput = false;
      });
      unawaited(_saveTerminalSplitMode(mode));
      return;
    }

    final primaryId = _activeTabId;
    final newTabs = <_TerminalTab>[];
    while (!kIsWeb && _tabs.length + newTabs.length < mode.capacity) {
      newTabs.add(_createTabState(const _TerminalConnection.local()));
    }
    final candidates = <int>[
      ?primaryId,
      for (final tab in [..._tabs, ...newTabs])
        if (tab.id != primaryId) tab.id,
    ];
    final visibleIds = candidates.take(mode.capacity).toList();
    setState(() {
      _tabs.addAll(newTabs);
      _splitMode = mode;
      _splitTabIds
        ..clear()
        ..addAll(visibleIds);
      _activeTabId = primaryId ?? visibleIds.firstOrNull;
    });
    unawaited(_saveTerminalSplitMode(mode));
    for (final tab in newTabs) {
      unawaited(_startSession(tab));
    }
    final active = _activeTab;
    if (active != null) _focusTab(active);
  }

  Future<void> _closeTab(_TerminalTab tab) async {
    if (tab.closing) return;
    tab.closing = true;
    if (!await _confirmTranscriptClose(tab)) {
      tab.closing = false;
      return;
    }
    if (!await _confirmRecordedMacroClose(tab)) {
      tab.closing = false;
      return;
    }
    if (!mounted || tab.isClosed) return;
    final index = _tabs.indexOf(tab);
    if (index < 0) {
      tab.closing = false;
      return;
    }

    final wasActive = tab.id == _activeTabId;
    final splitModeBeforeClose = _splitMode;
    _TerminalTab? nextTab;
    if (wasActive && _tabs.length > 1) {
      nextTab = _tabs[index == _tabs.length - 1 ? index - 1 : index + 1];
    }

    tab.isClosed = true;
    tab.inputRecorder.clear();
    tab.inputFlushTimer?.cancel();
    tab.inputFlushTimer = null;
    tab.pendingInput.takeBytes();
    tab.focusNode.unfocus();

    setState(() {
      _tabs.removeAt(index);
      _multiExecTabIds.remove(tab.id);
      if (wasActive) _activeTabId = nextTab?.id;
      if (_splitMode != TerminalSplitMode.none) {
        final removedSlot = _splitTabIds.indexOf(tab.id);
        _splitTabIds.remove(tab.id);
        if (removedSlot >= 0 && _splitTabIds.length < _splitMode.capacity) {
          final replacement = _tabs.cast<_TerminalTab?>().firstWhere(
            (candidate) =>
                candidate != null && !_splitTabIds.contains(candidate.id),
            orElse: () => null,
          );
          if (replacement != null) {
            _splitTabIds.insert(
              removedSlot.clamp(0, _splitTabIds.length),
              replacement.id,
            );
          }
        }
        if (_splitTabIds.length < 2) {
          _splitMode = TerminalSplitMode.none;
          _splitTabIds.clear();
          _broadcastSplitInput = false;
        }
      }
    });
    if (_splitMode != splitModeBeforeClose) {
      unawaited(_saveTerminalSplitMode(_splitMode));
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      tab.focusNode.dispose();
      tab.keywordHighlighter.dispose();
      tab.terminalController.dispose();
      tab.scrollController.dispose();
      tab.remoteMonitorCache.dispose();
      tab.assistant.dispose();
      tab.inlineHintTransformer.dispose();
    });
    unawaited(_disposeTab(tab));
    if (nextTab != null) _focusTab(nextTab);
  }

  Future<void> _saveTerminalSplitMode(TerminalSplitMode mode) async {
    try {
      await _sessionStore.saveTerminalSplitMode(mode);
    } catch (error) {
      if (mounted) _showMessage('保存终端布局失败：$error', isError: true);
    }
  }

  Future<void> _startSession(_TerminalTab tab) async {
    if (tab.isClosed || tab.starting) return;

    tab.starting = true;
    tab.status = tab.connection.openingStatus;
    tab.errorMessage = null;
    _refresh(tab);

    try {
      final connection = tab.connection;
      if (kIsWeb && !connection.kind.usesSshTransport) {
        throw UnsupportedError('浏览器版本仅支持通过 WebSocket 网关连接 SSH');
      }
      if (connection.kind.usesSshTransport) {
        await _openSshSession(tab, connection);
        if (tab.isClosed) return;
        if (tab.sshClient == null ||
            tab.sshClient!.isClosed ||
            (connection.kind == _ConnectionKind.ssh &&
                tab.sshSession == null)) {
          tab.starting = false;
          if (tab.id == _activeTabId) {
            _sidebarSection = _SidebarSection.sessions;
          }
          _refresh(tab);
          return;
        }
        if (tab.id == _activeTabId && connection.kind == _ConnectionKind.ssh) {
          _sidebarSection = _SidebarSection.files;
        }
        tab.starting = false;
        tab.status = connection.connectedStatus;
        _refresh(tab);
        _notifySessionProgress(
          tab,
          connection.kind == _ConnectionKind.sftp ? 'SFTP 登录成功' : 'SSH 登录成功',
          tabStatus: connection.connectedStatus,
        );
        return;
      }

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
        _ConnectionKind.ssh ||
        _ConnectionKind.sftp => throw StateError('SSH/SFTP 会话应使用 SSH 客户端启动'),
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
            (value) => _writeTerminalOutput(tab, value),
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
      if (tab.connection.kind.usesSshTransport && tab.id == _activeTabId) {
        _sidebarSection = _SidebarSection.sessions;
      }
      tab.starting = false;
      tab.status = '${tab.connection.displayName}连接失败';
      tab.errorMessage = error.toString();
      _writeTerminalOutput(tab, '\r\n[启动失败] $error\r\n');
      if (tab.connection.kind.usesSshTransport) {
        await _closeSshJumpClient(tab);
        _notifySessionProgress(
          tab,
          '${tab.connection.kind == _ConnectionKind.sftp ? 'SFTP' : 'SSH'} 登录失败：$error',
          isError: true,
          tabStatus: 'SSH 登录失败',
        );
      } else {
        _refresh(tab);
      }
    }
  }

  Future<List<SSHIdentity>> _loadSshAgentIdentities(
    _TerminalTab tab, {
    required String connectionLabel,
  }) async {
    try {
      final identities = await loadSshAgentIdentities();
      if (identities.isNotEmpty && mounted && !tab.isClosed) {
        _notifySessionProgress(
          tab,
          '$connectionLabel SSH Agent 提供 ${identities.length} 个密钥身份',
        );
      }
      return identities;
    } catch (error) {
      if (mounted && !tab.isClosed) {
        _notifySessionProgress(
          tab,
          '$connectionLabel SSH Agent 不可用，继续尝试已配置的认证方式：$error',
          isError: true,
        );
      }
      return const [];
    }
  }

  Future<void> _openSshSession(
    _TerminalTab tab,
    _TerminalConnection connection,
  ) async {
    SSHClient? jumpClient;
    final jumpHost = connection.jumpHost;
    final proxy = connection.sshProxy;
    if (proxy != null && kIsWeb) {
      throw UnsupportedError('浏览器 SSH 代理由 WebSocket 网关配置');
    }
    if (proxy != null && jumpHost != null) {
      throw StateError('SSH 代理和跳板机不能同时使用');
    }
    if (proxy != null && connection.portKnockActions.isNotEmpty) {
      throw UnsupportedError('SSH 代理连接不能同时使用端口敲门');
    }
    if (proxy != null && connection.webSocketUrl.isNotEmpty) {
      throw StateError('SSH 代理和 WebSocket 网关不能同时使用');
    }
    String? proxyPassword = connection.proxyPassword;
    var rememberProxyCredentials = connection.rememberProxyCredentials;
    if (proxy != null) {
      final savedProxyCredentials = await _sshCredentialStore.read(
        proxy.credentialKey,
      );
      proxyPassword ??= savedProxyCredentials?.password;
      rememberProxyCredentials |= savedProxyCredentials != null;
      if (!mounted || tab.isClosed) return;
      if (proxy.username.isNotEmpty &&
          (proxyPassword == null || proxyPassword.isEmpty)) {
        final entered = await showDialog<_SshProxyPasswordResult>(
          context: context,
          barrierDismissible: false,
          builder: (_) =>
              _SshProxyPasswordDialog(proxy: proxy, sessionTitle: tab.title),
        );
        if (entered == null || tab.isClosed) {
          throw StateError('SSH 代理认证已取消');
        }
        proxyPassword = entered.password;
        rememberProxyCredentials = entered.rememberCredentials;
      }
    }
    if (jumpHost == null) {
      await _runPortKnockSequence(tab, connection);
    } else {
      if (jumpHost.address.trim().toLowerCase() ==
              connection.address.trim().toLowerCase() &&
          jumpHost.port == connection.port) {
        throw StateError('跳板机和目标主机不能相同');
      }
      if (!canRunPortKnockActionsViaSshJump(connection.portKnockActions)) {
        throw UnsupportedError('经 SSH 跳板只支持 TCP 端口敲门');
      }
      _notifySessionProgress(tab, '正在连接 SSH 跳板机“${jumpHost.name}”…');
      jumpClient = await _openSshJumpHost(tab, jumpHost);
      if (tab.isClosed) return;
      await _runPortKnockSequence(tab, connection, viaJumpClient: jumpClient);
    }
    if (tab.isClosed) return;

    final savedCredentials = await _sshCredentialStore.read(
      connection.credentialKey,
    );
    if (!mounted || tab.isClosed) return;
    final agentIdentities = await _loadSshAgentIdentities(
      tab,
      connectionLabel: 'SSH',
    );
    if (!mounted || tab.isClosed) return;
    var username = connection.username.trim();
    var password = connection.password;
    var privateKeyPem = connection.privateKeyPem;
    var privateKeyPassphrase = connection.privateKeyPassphrase;
    final authenticationMode = connection.authenticationMode;
    var rememberCredentials = connection.rememberCredentials;
    if (username.isEmpty && savedCredentials != null) {
      username = savedCredentials.username;
    }
    if ((password == null || password.isEmpty) && savedCredentials != null) {
      password = savedCredentials.password;
    }
    if ((privateKeyPem == null || privateKeyPem.trim().isEmpty) &&
        savedCredentials != null) {
      privateKeyPem = savedCredentials.privateKeyPem;
    }
    if ((privateKeyPem == null || privateKeyPem.trim().isEmpty) &&
        connection.identityFile != null) {
      try {
        privateKeyPem = await readSshIdentityFile(connection.identityFile!);
      } catch (error) {
        _notifySessionProgress(tab, '无法读取 SSH 配置中的私钥：$error', isError: true);
      }
    }
    if ((privateKeyPassphrase == null || privateKeyPassphrase.isEmpty) &&
        savedCredentials != null) {
      privateKeyPassphrase = savedCredentials.privateKeyPassphrase;
    }

    final hasPrivateKey =
        privateKeyPem != null && privateKeyPem.trim().isNotEmpty;
    var privateKeyPassphraseMissing = false;
    if (hasPrivateKey &&
        (privateKeyPassphrase == null || privateKeyPassphrase.isEmpty)) {
      try {
        privateKeyPassphraseMissing = SSHKeyPair.isEncryptedPem(privateKeyPem);
      } on Object {
        // Let the regular PEM parser report unsupported or malformed formats.
      }
    }
    if (username.isEmpty ||
        ((password == null || password.isEmpty) &&
            !hasPrivateKey &&
            agentIdentities.isEmpty) ||
        privateKeyPassphraseMissing) {
      if (!mounted || tab.isClosed) return;
      final credentials = await showDialog<_SshCredentialPromptResult>(
        context: context,
        builder: (_) => _SshCredentialPrompt(
          initialUsername: username,
          initialPassword: password ?? '',
          initialPrivateKeyPem: privateKeyPem ?? '',
          initialPrivateKeyPassphrase: privateKeyPassphrase ?? '',
          rememberByDefault: rememberCredentials || savedCredentials != null,
        ),
      );
      if (credentials == null || tab.isClosed) {
        throw StateError('SSH 登录已取消');
      }
      username = credentials.username;
      password = credentials.password;
      privateKeyPem = credentials.privateKeyPem;
      privateKeyPassphrase = credentials.privateKeyPassphrase;
      rememberCredentials = credentials.rememberCredentials;
    }
    if (tab.isClosed) return;

    final identities = <SSHIdentity>[];
    final trimmedPrivateKey = privateKeyPem?.trim() ?? '';
    if (trimmedPrivateKey.isNotEmpty) {
      try {
        identities.addAll(
          SSHKeyPair.fromPem(
            trimmedPrivateKey,
            privateKeyPassphrase?.isEmpty ?? true ? null : privateKeyPassphrase,
          ),
        );
      } catch (error) {
        _notifySessionProgress(tab, '私钥无法读取：$error', isError: true);
        _notifySessionProgress(tab, '密钥登录失败，使用密码重试...');
      }
    }
    identities.addAll(agentIdentities);

    final hasPassword = password != null && password.isNotEmpty;
    final orderedAttempts = switch (authenticationMode) {
      SshAuthenticationMode.passwordFirst => [
        if (hasPassword || identities.isEmpty) _SshAuthMethod.password,
        if (identities.isNotEmpty) _SshAuthMethod.key,
        if (!hasPassword && identities.isNotEmpty) _SshAuthMethod.password,
      ],
      SshAuthenticationMode.keyFirst => [
        if (identities.isNotEmpty) _SshAuthMethod.key,
        _SshAuthMethod.password,
      ],
      SshAuthenticationMode.automatic => [
        if (identities.isNotEmpty) _SshAuthMethod.key,
        _SshAuthMethod.password,
      ],
    };

    SSHClient? client;
    var authenticated = false;
    for (var index = 0; index < orderedAttempts.length; index++) {
      if (tab.isClosed) return;
      final method = orderedAttempts[index];
      final isKeyAttempt = method == _SshAuthMethod.key;
      _notifySessionProgress(tab, isKeyAttempt ? '正在尝试密钥登录...' : '正在尝试密码登录...');
      final socket = jumpClient == null
          ? await _connectSshSocket(connection, proxyPassword: proxyPassword)
          : await jumpClient
                .forwardLocal(connection.address, connection.port)
                .timeout(const Duration(seconds: 15));
      if (tab.isClosed) {
        socket.destroy();
        return;
      }
      client = SSHClient(
        socket,
        username: username,
        identities: isKeyAttempt ? identities : null,
        onPasswordRequest: isKeyAttempt
            ? null
            : () => hasPassword ? password : null,
        onUserInfoRequest: isKeyAttempt
            ? null
            : (request) => _requestSshUserInfo(tab, request),
        onVerifyHostKey: (type, fingerprint) =>
            _verifySshHostKey(tab, connection, type, fingerprint),
        keepAliveInterval: widget.settings.sshKeepAliveSeconds == 0
            ? null
            : Duration(seconds: widget.settings.sshKeepAliveSeconds),
        handshakeTimeout: const Duration(seconds: 15),
        authTimeout: const Duration(minutes: 5),
      );
      tab.sshClient = client;

      try {
        await client.authenticated;
        authenticated = true;
        if (tab.isClosed) {
          await client.close();
          return;
        }
        break;
      } catch (error, stackTrace) {
        if (identical(tab.sshClient, client)) tab.sshClient = null;
        try {
          await client.close();
        } catch (_) {
          // Preserve the authentication failure when closing a failed attempt.
        }
        if (tab.isClosed) return;
        final hasFallback = index + 1 < orderedAttempts.length;
        if (!hasFallback) Error.throwWithStackTrace(error, stackTrace);
        final nextIsKey = orderedAttempts[index + 1] == _SshAuthMethod.key;
        _notifySessionProgress(
          tab,
          isKeyAttempt ? '密钥登录失败，使用密码重试...' : '密码登录失败，使用密钥重试...',
        );
        if (!nextIsKey && privateKeyPem != null && identities.isEmpty) {
          _notifySessionProgress(tab, '正在使用密码或交互式质询登录...');
        }
      }
    }

    final authenticatedClient = client;
    if (authenticatedClient == null || !authenticated) {
      throw StateError('SSH 认证未完成');
    }
    tab.sshClient = authenticatedClient;
    try {
      if (connection.kind == _ConnectionKind.sftp) {
        _notifySessionProgress(tab, '认证成功，正在打开 SFTP 文件浏览...');
        final sftpClient = await authenticatedClient.sftp().timeout(
          const Duration(seconds: 15),
        );
        try {
          await sftpClient.stat('.').timeout(const Duration(seconds: 15));
        } finally {
          await sftpClient.close();
        }
        if (rememberCredentials) {
          try {
            await _sshCredentialStore.write(
              connection.credentialKey,
              SshCredentials(
                username: username,
                password: password,
                privateKeyPem: trimmedPrivateKey.isEmpty
                    ? null
                    : trimmedPrivateKey,
                privateKeyPassphrase: privateKeyPassphrase,
              ),
            );
          } catch (error) {
            _showMessage('SFTP 已连接，但凭据保存失败：$error', isError: true);
          }
        }
        await _storeSshProxyCredentials(
          connection,
          proxyPassword,
          rememberProxyCredentials,
        );
        unawaited(_recordConnection(connection));
        unawaited(
          authenticatedClient.done.then<void>((_) {
            if (!mounted ||
                tab.isClosed ||
                !identical(tab.sshClient, authenticatedClient)) {
              return;
            }
            tab.sshClient = null;
            tab.status = 'SFTP 连接已断开';
            tab.errorMessage = 'SSH 传输已关闭，请重新连接后继续浏览文件。';
            unawaited(_closeSshJumpClient(tab));
            unawaited(_closeTunnels(tab));
            if (tab.id == _activeTabId) {
              _sidebarSection = _SidebarSection.sessions;
            }
            _refresh(tab);
          }),
        );
        return;
      }

      _notifySessionProgress(tab, '认证成功，正在打开终端...');
      final remoteSession = await authenticatedClient.shell(
        pty: SSHPtyConfig(width: tab.columns, height: tab.rows),
        environment: sshTerminalEnvironment(),
      );
      if (tab.isClosed) {
        remoteSession.close();
        await authenticatedClient.close();
        return;
      }
      tab.sshSession = remoteSession;

      if (rememberCredentials) {
        try {
          await _sshCredentialStore.write(
            connection.credentialKey,
            SshCredentials(
              username: username,
              password: password,
              privateKeyPem: trimmedPrivateKey.isEmpty
                  ? null
                  : trimmedPrivateKey,
              privateKeyPassphrase: privateKeyPassphrase,
            ),
          );
        } catch (error) {
          _showMessage('SSH 已连接，但凭据保存失败：$error', isError: true);
        }
      }
      await _storeSshProxyCredentials(
        connection,
        proxyPassword,
        rememberProxyCredentials,
      );

      unawaited(_recordConnection(connection));
      tab.outputSubscription = _mergeSshOutput(remoteSession)
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(
            (value) => _writeTerminalOutput(tab, value),
            onError: (Object error, StackTrace stackTrace) {
              _handleSshSessionError(tab, authenticatedClient, error);
            },
            onDone: () {
              // SSH stdout/stderr can reach EOF before the channel finishes.
              // Keep the client alive until the SSH session itself is closed.
              unawaited(
                remoteSession.done
                    .then<void>((_) {
                      _handleSshSessionExit(tab, authenticatedClient);
                    })
                    .catchError((Object error, StackTrace stackTrace) {
                      _handleSshSessionError(tab, authenticatedClient, error);
                    }),
              );
            },
          );
    } catch (_) {
      if (identical(tab.sshClient, authenticatedClient)) {
        tab.sshClient = null;
        tab.sshSession = null;
      }
      await authenticatedClient.close();
      rethrow;
    }
  }

  Future<void> _storeSshProxyCredentials(
    _TerminalConnection connection,
    String? password,
    bool remember,
  ) async {
    final proxy = connection.sshProxy;
    if (proxy == null || !remember || password == null || password.isEmpty) {
      return;
    }
    try {
      await _sshCredentialStore.write(
        proxy.credentialKey,
        SshCredentials(username: proxy.username, password: password),
      );
    } catch (error) {
      _showMessage('SSH 已连接，但代理凭据保存失败：$error', isError: true);
    }
  }

  Future<SSHClient> _openSshJumpHost(
    _TerminalTab tab,
    SshJumpHost record,
  ) async {
    final connection = _TerminalConnection.ssh(
      record.address,
      record.port,
      username: record.username,
      webSocketUrl: record.webSocketUrl,
      portKnockActions: record.portKnockActions,
      authenticationMode: record.authenticationMode,
      identityFile: record.identityFile,
      sshConfigAlias: record.sshConfigAlias,
      sessionTitle: record.name,
    );
    await _runPortKnockSequence(tab, connection);
    if (tab.isClosed) throw StateError('SSH 跳板机连接已取消');

    final savedCredentials = await _sshCredentialStore.read(
      connection.credentialKey,
    );
    if (!mounted || tab.isClosed) {
      throw StateError('SSH 跳板机连接已取消');
    }
    final agentIdentities = await _loadSshAgentIdentities(
      tab,
      connectionLabel: '跳板机',
    );
    if (!mounted || tab.isClosed) {
      throw StateError('SSH 跳板机连接已取消');
    }
    var username = connection.username.trim();
    var password = savedCredentials?.password;
    var privateKeyPem = connection.privateKeyPem;
    var privateKeyPassphrase = savedCredentials?.privateKeyPassphrase;
    var rememberCredentials = savedCredentials != null;
    if (username.isEmpty && savedCredentials != null) {
      username = savedCredentials.username;
    }
    if ((privateKeyPem == null || privateKeyPem.trim().isEmpty) &&
        savedCredentials != null) {
      privateKeyPem = savedCredentials.privateKeyPem;
    }
    if ((privateKeyPem == null || privateKeyPem.trim().isEmpty) &&
        connection.identityFile != null) {
      try {
        privateKeyPem = await readSshIdentityFile(connection.identityFile!);
      } catch (error) {
        _notifySessionProgress(tab, '无法读取跳板机私钥：$error', isError: true);
      }
    }

    final hasPrivateKey =
        privateKeyPem != null && privateKeyPem.trim().isNotEmpty;
    var privateKeyPassphraseMissing = false;
    if (hasPrivateKey &&
        (privateKeyPassphrase == null || privateKeyPassphrase.isEmpty)) {
      try {
        privateKeyPassphraseMissing = SSHKeyPair.isEncryptedPem(privateKeyPem);
      } on Object {
        // Let the regular PEM parser report unsupported or malformed formats.
      }
    }
    if (username.isEmpty ||
        ((password == null || password.isEmpty) &&
            !hasPrivateKey &&
            agentIdentities.isEmpty) ||
        privateKeyPassphraseMissing) {
      if (!mounted || tab.isClosed) {
        throw StateError('SSH 跳板机登录已取消');
      }
      final credentials = await showDialog<_SshCredentialPromptResult>(
        context: context,
        builder: (_) => _SshCredentialPrompt(
          initialUsername: username,
          initialPassword: password ?? '',
          initialPrivateKeyPem: privateKeyPem ?? '',
          initialPrivateKeyPassphrase: privateKeyPassphrase ?? '',
          rememberByDefault: savedCredentials != null,
        ),
      );
      if (credentials == null || tab.isClosed) {
        throw StateError('SSH 跳板机登录已取消');
      }
      username = credentials.username;
      password = credentials.password;
      privateKeyPem = credentials.privateKeyPem;
      privateKeyPassphrase = credentials.privateKeyPassphrase;
      rememberCredentials = credentials.rememberCredentials;
    }

    final identities = <SSHIdentity>[];
    final trimmedPrivateKey = privateKeyPem?.trim() ?? '';
    if (trimmedPrivateKey.isNotEmpty) {
      try {
        identities.addAll(
          SSHKeyPair.fromPem(
            trimmedPrivateKey,
            privateKeyPassphrase?.isEmpty ?? true ? null : privateKeyPassphrase,
          ),
        );
      } catch (error) {
        _notifySessionProgress(tab, '跳板机私钥无法读取：$error', isError: true);
      }
    }
    identities.addAll(agentIdentities);
    final hasPassword = password != null && password.isNotEmpty;
    final orderedAttempts = switch (connection.authenticationMode) {
      SshAuthenticationMode.passwordFirst => [
        if (hasPassword || identities.isEmpty) _SshAuthMethod.password,
        if (identities.isNotEmpty) _SshAuthMethod.key,
        if (!hasPassword && identities.isNotEmpty) _SshAuthMethod.password,
      ],
      SshAuthenticationMode.keyFirst => [
        if (identities.isNotEmpty) _SshAuthMethod.key,
        _SshAuthMethod.password,
      ],
      SshAuthenticationMode.automatic => [
        if (identities.isNotEmpty) _SshAuthMethod.key,
        _SshAuthMethod.password,
      ],
    };

    for (var index = 0; index < orderedAttempts.length; index++) {
      if (!mounted || tab.isClosed) {
        throw StateError('SSH 跳板机连接已取消');
      }
      final method = orderedAttempts[index];
      final isKeyAttempt = method == _SshAuthMethod.key;
      _notifySessionProgress(
        tab,
        isKeyAttempt ? '正在尝试跳板机密钥登录…' : '正在尝试跳板机密码登录…',
      );
      final socket = await _connectSshSocket(connection);
      if (tab.isClosed) {
        socket.destroy();
        throw StateError('SSH 跳板机连接已取消');
      }
      final client = SSHClient(
        socket,
        username: username,
        identities: isKeyAttempt ? identities : null,
        onPasswordRequest: isKeyAttempt
            ? null
            : () => hasPassword ? password : null,
        onUserInfoRequest: isKeyAttempt
            ? null
            : (request) => _requestSshUserInfo(tab, request),
        onVerifyHostKey: (type, fingerprint) =>
            _verifySshHostKey(tab, connection, type, fingerprint),
        keepAliveInterval: widget.settings.sshKeepAliveSeconds == 0
            ? null
            : Duration(seconds: widget.settings.sshKeepAliveSeconds),
        handshakeTimeout: const Duration(seconds: 15),
        authTimeout: const Duration(minutes: 5),
      );
      tab.sshJumpClient = client;
      try {
        await client.authenticated;
        if (tab.isClosed) return client;
        if (rememberCredentials) {
          try {
            await _sshCredentialStore.write(
              connection.credentialKey,
              SshCredentials(
                username: username,
                password: password,
                privateKeyPem: trimmedPrivateKey.isEmpty
                    ? null
                    : trimmedPrivateKey,
                privateKeyPassphrase: privateKeyPassphrase,
              ),
            );
          } catch (error) {
            _showMessage('跳板机已连接，但凭据保存失败：$error', isError: true);
          }
        }
        return client;
      } catch (error, stackTrace) {
        if (identical(tab.sshJumpClient, client)) tab.sshJumpClient = null;
        try {
          await client.close();
        } catch (_) {
          // Preserve the authentication failure when closing a failed attempt.
        }
        if (!mounted || tab.isClosed) {
          throw StateError('SSH 跳板机连接已取消');
        }
        if (index + 1 == orderedAttempts.length) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        _notifySessionProgress(tab, '跳板机首选认证失败，正在尝试备用认证…');
      }
    }
    throw StateError('SSH 跳板机认证未完成');
  }

  Future<SSHSocket> _connectSshSocket(
    _TerminalConnection connection, {
    String? proxyPassword,
  }) {
    final proxy = connection.sshProxy;
    if (proxy != null) {
      if (kIsWeb) {
        return Future.error(UnsupportedError('浏览器 SSH 代理由 WebSocket 网关配置'));
      }
      return connectSshThroughProxy(
        proxy: proxy,
        targetHost: connection.address,
        targetPort: connection.port,
        password: proxyPassword,
        timeout: const Duration(seconds: 15),
      );
    }
    return kIsWeb
        ? WebSocketSshSocket.connect(
            _webSocketUri(
              connection.webSocketUrl,
              connection.address,
              connection.port,
            ),
          )
        : SSHSocket.connect(
            connection.address,
            connection.port,
            timeout: const Duration(seconds: 15),
          );
  }

  Future<List<String>?> _requestSshUserInfo(
    _TerminalTab tab,
    SSHUserInfoRequest request,
  ) {
    if (tab.isClosed) return Future.value(null);
    _notifySessionProgress(tab, '收到交互式质询，请完成后继续');
    return showDialog<List<String>>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _SshUserInfoDialog(request: request, sessionTitle: tab.title),
    );
  }

  Future<void> _runPortKnockSequence(
    _TerminalTab tab,
    _TerminalConnection connection, {
    SSHClient? viaJumpClient,
  }) async {
    if (connection.jumpHost != null && viaJumpClient == null) {
      throw StateError('目标主机敲门需要已连接的 SSH 跳板');
    }
    for (final action in connection.portKnockActions) {
      if (tab.isClosed) return;
      switch (action.kind) {
        case PortKnockActionKind.knock:
          final protocolName = switch (action.protocol) {
            PortKnockProtocol.tcp => 'TCP',
            PortKnockProtocol.udp => 'UDP',
            PortKnockProtocol.icmp => 'ICMP',
          };
          final target = action.protocol == PortKnockProtocol.icmp
              ? connection.address
              : '${connection.address}:${action.port}';
          final viaJump = viaJumpClient != null;
          _notifySessionProgress(
            tab,
            '$protocolName 敲门：$target${viaJump ? '（经 SSH 跳板）' : ''}',
          );
          _writeTerminalOutput(
            tab,
            '\r\n[端口敲门] $protocolName $target${viaJump ? '（经 SSH 跳板）' : ''}\r\n',
          );
          if (viaJump) {
            if (action.protocol != PortKnockProtocol.tcp) {
              throw UnsupportedError('经 SSH 跳板只支持 TCP 端口敲门');
            }
            final jumpClient = viaJumpClient;
            await knockTcpThroughSshJump(
              openChannel: () =>
                  jumpClient.forwardLocal(connection.address, action.port),
              closeChannel: (channel) => channel.close(),
            );
          } else {
            await knockOnce(
              connection.address,
              action.protocol,
              action.port,
              webSocketUri: kIsWeb
                  ? _webSocketUri(
                      connection.webSocketUrl,
                      connection.address,
                      action.protocol == PortKnockProtocol.icmp
                          ? null
                          : action.port,
                      transport: action.protocol == PortKnockProtocol.tcp
                          ? null
                          : action.protocol.name,
                    )
                  : null,
            );
          }
        case PortKnockActionKind.delay:
          _notifySessionProgress(tab, '端口敲门延迟 ${action.delayMs} ms');
          _writeTerminalOutput(tab, '\r\n[端口敲门] 延迟 ${action.delayMs} ms\r\n');
          await Future<void>.delayed(Duration(milliseconds: action.delayMs));
      }
    }
  }

  Uri _webSocketUri(
    String template,
    String host,
    int? port, {
    String? transport,
  }) {
    final encodedHost = Uri.encodeComponent(host);
    final hasHostPlaceholder = template.contains('{host}');
    final hasPortPlaceholder = template.contains('{port}');
    final expanded = template
        .replaceAll('{host}', encodedHost)
        .replaceAll('{port}', port?.toString() ?? '');
    var uri = Uri.parse(expanded);
    if (uri.scheme != 'ws' && uri.scheme != 'wss') {
      throw const FormatException('Web SSH 网关地址必须使用 ws:// 或 wss://');
    }
    if (uri.userInfo.isNotEmpty) {
      throw const FormatException('WebSocket 地址中不能包含用户名或密码');
    }
    if (Uri.base.scheme == 'https' && uri.scheme != 'wss') {
      throw const FormatException('HTTPS 页面必须通过 wss:// 连接 SSH 网关');
    }
    if (!hasHostPlaceholder ||
        (port != null && !hasPortPlaceholder) ||
        transport != null) {
      uri = uri.replace(
        queryParameters: {
          ...uri.queryParameters,
          if (!hasHostPlaceholder) 'host': host,
          if (port != null && !hasPortPlaceholder) 'port': '$port',
          ...?(transport == null ? null : {'transport': transport}),
        },
      );
    }
    return uri;
  }

  Future<bool> _verifySshHostKey(
    _TerminalTab tab,
    _TerminalConnection connection,
    String type,
    Uint8List fingerprintBytes,
  ) async {
    final fingerprint = utf8.decode(fingerprintBytes, allowMalformed: true);
    final endpointKey = connection.hostKeyEndpoint;
    final existingFingerprint = await _sessionStore.loadSshHostKey(endpointKey);
    if (existingFingerprint == fingerprint) return true;
    if (!mounted) return false;
    _notifySessionProgress(
      tab,
      existingFingerprint == null
          ? '请核对并确认 SSH 主机指纹...'
          : 'SSH 主机指纹变化，请核对后继续...',
      isError: existingFingerprint != null,
    );

    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(
          existingFingerprint == null
              ? Icons.verified_user_outlined
              : Icons.warning_amber_rounded,
        ),
        title: Text(
          existingFingerprint == null ? '确认 SSH 主机密钥' : 'SSH 主机密钥已变化',
        ),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${connection.address}:${connection.port} · $type'),
              const SizedBox(height: 12),
              if (existingFingerprint != null) ...[
                const Text('此主机之前保存的密钥与当前密钥不同。只有确认服务器已更换密钥时才接受。'),
                const SizedBox(height: 8),
                SelectableText('原指纹：$existingFingerprint'),
              ] else
                const Text('首次连接前请通过可信渠道核对服务器指纹。'),
              const SizedBox(height: 8),
              SelectableText('当前指纹：$fingerprint'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('拒绝连接'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(existingFingerprint == null ? '信任此主机' : '更新并信任'),
          ),
        ],
      ),
    );
    if (accepted != true) return false;
    await _sessionStore.saveSshHostKey(endpointKey, fingerprint);
    return true;
  }

  Stream<Uint8List> _mergeSshOutput(SSHSession session) {
    late StreamSubscription<Uint8List> stdoutSubscription;
    late StreamSubscription<Uint8List> stderrSubscription;
    var openStreams = 2;
    late final StreamController<Uint8List> output;
    output = StreamController<Uint8List>(
      onListen: () {
        void streamClosed() {
          openStreams -= 1;
          if (openStreams == 0) unawaited(output.close());
        }

        stdoutSubscription = session.stdout.listen(
          output.add,
          onError: (Object error, StackTrace stackTrace) =>
              output.addError(error, stackTrace),
          onDone: streamClosed,
        );
        stderrSubscription = session.stderr.listen(
          output.add,
          onError: (Object error, StackTrace stackTrace) =>
              output.addError(error, stackTrace),
          onDone: streamClosed,
        );
      },
      onCancel: () async {
        await stdoutSubscription.cancel();
        await stderrSubscription.cancel();
      },
    );
    return output.stream;
  }

  void _handleSshSessionError(
    _TerminalTab tab,
    SSHClient client,
    Object error,
  ) {
    if (tab.isClosed || !identical(tab.sshClient, client)) return;
    tab.status = 'SSH 输出错误';
    tab.errorMessage = error.toString();
    _writeTerminalOutput(tab, '\r\n[SSH 输出错误] $error\r\n');
    _refresh(tab);
  }

  void _handleSshSessionExit(_TerminalTab tab, SSHClient client) {
    if (!identical(tab.sshClient, client)) return;
    _stopInputRecordingOnDisconnect(tab);
    final session = tab.sshSession;
    final exitCode = session?.exitCode;
    final exitSignal = session?.exitSignal;
    final exitDetails = [
      if (exitCode != null) '退出码 $exitCode',
      if (exitSignal != null) '信号 SIG${exitSignal.signalName}',
    ].join(' · ');
    tab.sshSession = null;
    tab.sshClient = null;
    tab.outputSubscription = null;
    tab.starting = false;
    tab.status =
        '${tab.connection.displayName}已断开${exitDetails.isEmpty ? '' : ' · $exitDetails'}';
    if (tab.id == _activeTabId) {
      _sidebarSection = _SidebarSection.sessions;
      _showMessage(
        tab.status,
        isError: exitSignal != null || (exitCode != null && exitCode != 0),
      );
    }
    final jumpClient = tab.sshJumpClient;
    tab.sshJumpClient = null;
    _refresh(tab);
    unawaited(
      _closeTunnels(tab)
          .then((_) async {
            await client.close();
            if (jumpClient != null) {
              try {
                await jumpClient.close();
              } catch (_) {
                // The jump transport may already have closed.
              }
            }
          })
          .catchError((_) {}),
    );
  }

  Future<void> _closeSshJumpClient(_TerminalTab tab) async {
    final client = tab.sshJumpClient;
    tab.sshJumpClient = null;
    if (client == null) return;
    try {
      await client.close();
    } catch (_) {
      // The jump transport may already have closed.
    }
  }

  Future<void> _closeTunnels(_TerminalTab tab) async {
    final tunnels = List<SshTunnelHandle>.of(tab.tunnels);
    tab.tunnels.clear();
    for (final tunnel in tunnels) {
      try {
        await tunnel.close();
      } catch (_) {
        // The listener may already have stopped with its SSH transport.
      }
    }
  }

  Future<void> _restartSession(_TerminalTab tab) async {
    if (tab.isClosed || tab.starting || tab.restarting) return;
    _stopInputRecordingOnDisconnect(tab);
    tab.assistant.reset();
    tab.inlineHintTransformer.reset();
    tab.restarting = true;
    tab.starting = true;
    tab.status = '正在重新连接${tab.connection.displayName}';
    _refresh(tab);
    try {
      await _stopSession(tab);
      if (tab.isClosed) return;
      _writeTerminalOutput(
        tab,
        '\r\n[正在重新连接${tab.connection.displayName}]\r\n',
      );
      tab.restarting = false;
      await _startSession(tab);
    } finally {
      tab.restarting = false;
    }
  }

  Future<void> _stopSession(_TerminalTab tab) async {
    _stopInputRecordingOnDisconnect(tab);
    tab.inputFlushTimer?.cancel();
    tab.inputFlushTimer = null;
    _flushInput(tab);
    await tab.inputWriteQueue;

    final sessionId = tab.sessionId;
    tab.sessionId = null;
    final sshClient = tab.sshClient;
    tab.sshClient = null;
    tab.sshSession = null;
    final sshJumpClient = tab.sshJumpClient;
    tab.sshJumpClient = null;
    await _closeTunnels(tab);
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
    if (sshClient != null) {
      try {
        await sshClient.close();
      } catch (_) {
        // The SSH transport may already have closed.
      }
    }
    if (sshJumpClient != null) {
      try {
        await sshJumpClient.close();
      } catch (_) {
        // The jump transport may already have closed.
      }
    }
    await outputSubscription?.cancel();
  }

  void _queueInput(_TerminalTab tab, String value) {
    if (tab.isClosed || tab.starting || tab.restarting || !tab.isConnected) {
      return;
    }
    tab.pendingInput.add(utf8.encode(value));
    tab.inputFlushTimer ??= Timer(
      const Duration(milliseconds: 12),
      () => _flushInput(tab),
    );
  }

  void _recordTerminalInput(_TerminalTab tab, String value) {
    tab.inlineHintTransformer.notifyUserInput(value);
    tab.chartCoordinator.notifyUserInput(value);
    if (!tab.inputRecorder.isRecording) return;
    if (!tab.inputRecorder.record(value)) {
      final prefix = tab.id == _activeTabId ? '' : '会话${tab.title}：';
      _showMessage('$prefix录制达到输入上限，已自动停止；请保存或丢弃这段录制', isError: true);
      _refresh(tab);
    }
  }

  void _stopInputRecordingOnDisconnect(_TerminalTab tab) {
    if (!tab.inputRecorder.isRecording) return;
    tab.inputRecorder.stop();
    if (!tab.inputRecorder.hasData) {
      tab.inputRecorder.clear();
      _refresh(tab);
      return;
    }
    _refresh(tab);
    final prefix = tab.id == _activeTabId ? '' : '会话${tab.title}：';
    _showMessage('$prefix会话断开，键盘录制已停止；可保存或丢弃录制内容', isError: true);
  }

  void _flushInput(_TerminalTab tab) {
    tab.inputFlushTimer?.cancel();
    tab.inputFlushTimer = null;

    final sessionId = tab.sessionId;
    final sshSession = tab.sshSession;
    if ((sessionId == null && sshSession == null) || tab.pendingInput.isEmpty) {
      return;
    }

    final data = tab.pendingInput.takeBytes();
    final targetIds = terminalInputTargetIds(
      sourceTabId: tab.id,
      connectedTabIds: _tabs
          .where((candidate) => candidate.isConnected && !candidate.isClosed)
          .map((candidate) => candidate.id),
      splitTabIds: _splitTabIds,
      selectedTabIds: _multiExecTabIds,
      broadcastSplitInput:
          _broadcastSplitInput && _splitMode != TerminalSplitMode.none,
    );
    final targets = _tabs.where((target) => targetIds.contains(target.id));
    for (final target in targets) {
      final targetSessionId = target.sessionId;
      final targetSshSession = target.sshSession;
      if (targetSessionId == null && targetSshSession == null) continue;
      target.inputWriteQueue = target.inputWriteQueue
          .then((_) async {
            if (target.isClosed ||
                target.sessionId != targetSessionId ||
                !identical(target.sshSession, targetSshSession)) {
              return;
            }
            if (targetSshSession != null) {
              await targetSshSession.stdin.addStream(
                Stream<Uint8List>.value(Uint8List.fromList(data)),
              );
              await targetSshSession.flush();
            } else if (targetSessionId != null) {
              await writeTerminalInput(
                sessionId: targetSessionId,
                data: Uint8List.fromList(data),
              );
            }
          })
          .catchError((Object error) {
            if (target.isClosed) return;
            target.errorMessage = error.toString();
            target.status = '终端输入失败';
            if (targetSshSession != null) {
              _showMessage('SSH 输入失败：$error', isError: true);
            }
            _refresh(target);
          });
    }
  }

  void _handleResize(_TerminalTab tab, int columns, int rows) {
    final nextColumns = columns.clamp(1, 1000);
    final nextRows = rows.clamp(1, 500);
    if (tab.columns == nextColumns && tab.rows == nextRows) return;

    tab.columns = nextColumns;
    tab.rows = nextRows;
    final sshSession = tab.sshSession;
    if (sshSession != null) {
      sshSession.resizeTerminal(tab.columns, tab.rows);
      return;
    }
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

  void _handleSessionError(
    _TerminalTab tab,
    PlatformInt64 sessionId,
    Object error,
  ) {
    if (tab.isClosed || tab.sessionId != sessionId) return;
    tab.status = '${tab.connection.displayName}输出错误';
    tab.errorMessage = error.toString();
    _writeTerminalOutput(
      tab,
      '\r\n[${tab.connection.displayName}输出错误] $error\r\n',
    );
    _refresh(tab);
  }

  void _handleSessionExit(_TerminalTab tab, PlatformInt64 sessionId) {
    if (tab.sessionId == sessionId) {
      _stopInputRecordingOnDisconnect(tab);
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
      await _copyTerminalSelection(tab, clearSelection: true);
      return;
    }

    await _pasteClipboard(tab);
  }

  Future<void> _copyTerminalSelection(
    _TerminalTab tab, {
    bool clearSelection = false,
  }) async {
    final selection = tab.terminalController.selection;
    if (selection == null) return;
    final text = tab.terminal.buffer.getText(selection);
    if (clearSelection) tab.terminalController.clearSelection();
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<void> _pasteClipboard(_TerminalTab tab) async {
    if (tab.isClosed) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (!mounted || text == null || tab.isClosed) return;
    if (_hasInputBroadcast) {
      final confirmed = await _confirmBroadcastPaste(
        '剪贴板内容会粘贴到输入广播目标，请确认内容后继续。',
      );
      if (!mounted || tab.isClosed || confirmed != true) return;
    }
    tab.terminal.paste(text);
  }

  void _refresh(_TerminalTab tab) {
    if (mounted && !tab.isClosed && _tabs.contains(tab)) setState(() {});
  }

  Color _statusColor(_TerminalTab? tab, ColorScheme colors) {
    if (tab == null) return colors.onSurfaceVariant;
    if (tab.errorMessage != null) return colors.error;
    if (tab.starting || tab.restarting) return colors.tertiary;
    final transportConnected =
        tab.isConnected ||
        (tab.connection.kind == _ConnectionKind.sftp &&
            tab.sshClient?.isClosed == false);
    return transportConnected ? colors.primary : colors.onSurfaceVariant;
  }

  Future<void> _disposeTab(_TerminalTab tab) async {
    await tab.inputWriteQueue;
    final sessionId = tab.sessionId;
    tab.sessionId = null;
    final sshClient = tab.sshClient;
    tab.sshClient = null;
    tab.sshSession = null;
    final sshJumpClient = tab.sshJumpClient;
    tab.sshJumpClient = null;
    await _closeTunnels(tab);
    if (sessionId != null) {
      try {
        await closeTerminalSession(sessionId: sessionId);
      } catch (_) {
        // Ignore cleanup errors when a tab is closed.
      }
    }
    if (sshClient != null) {
      try {
        await sshClient.close();
      } catch (_) {
        // Ignore cleanup errors when a tab is closed.
      }
    }
    if (sshJumpClient != null) {
      try {
        await sshJumpClient.close();
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
      tab.inputRecorder.clear();
      tab.inputFlushTimer?.cancel();
      tab.focusNode.dispose();
      tab.keywordHighlighter.dispose();
      tab.terminalController.dispose();
      tab.scrollController.dispose();
      tab.remoteMonitorCache.dispose();
      tab.assistant.dispose();
      tab.inlineHintTransformer.dispose();
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
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final compactToolbar = viewportWidth < 1600;
    final narrowToolbar = viewportWidth < 600;
    final terminalArea = Column(
      children: [
        _buildTabBar(colors),
        if (_hasInputBroadcast) _buildInputBroadcastBanner(colors),
        Expanded(child: _buildTerminalWorkspace(colors)),
        if (activeTab != null &&
            activeTab.connection.kind == _ConnectionKind.ssh)
          SshRemoteMonitorBar(
            key: ValueKey('remote-monitor-${activeTab.id}'),
            client: activeTab.sshClient,
            cache: activeTab.remoteMonitorCache,
            sessionTitle: activeTab.title,
            onOpenDetails: () => unawaited(_openSshRemoteMonitor(activeTab)),
          ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 62,
        titleSpacing: 16,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.terminal_rounded),
            SizedBox(width: 9),
            Flexible(
              child: Text(
                'Geekcore Term',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 17),
              ),
            ),
          ],
        ),
        actions: compactToolbar
            ? [
                if (!kIsWeb && !narrowToolbar)
                  IconButton(
                    tooltip: '本地终端',
                    onPressed: _addLocalShellTab,
                    icon: const Icon(Icons.terminal_rounded),
                  ),
                if (!narrowToolbar)
                  IconButton(
                    tooltip: 'SSH',
                    onPressed: () =>
                        unawaited(_handleNewSession(_NewSessionAction.ssh)),
                    icon: const Icon(Icons.lock_open_rounded),
                  ),
                PopupMenuButton<_CompactToolbarAction>(
                  tooltip: '更多工具',
                  onSelected: (action) {
                    switch (action) {
                      case _CompactToolbarAction.localTerminal:
                        _addLocalShellTab();
                        break;
                      case _CompactToolbarAction.ssh:
                        unawaited(_handleNewSession(_NewSessionAction.ssh));
                        break;
                      case _CompactToolbarAction.sftp:
                        unawaited(_handleNewSession(_NewSessionAction.sftp));
                        break;
                      case _CompactToolbarAction.serial:
                        unawaited(_handleNewSession(_NewSessionAction.serial));
                        break;
                      case _CompactToolbarAction.telnet:
                        unawaited(_handleNewSession(_NewSessionAction.telnet));
                        break;
                      case _CompactToolbarAction.tunnels:
                        if (activeTab?.sshClient != null) {
                          unawaited(_openSshTunnelManager(activeTab!));
                        }
                        break;
                      case _CompactToolbarAction.monitor:
                        if (activeTab?.sshClient != null) {
                          unawaited(_openSshRemoteMonitor(activeTab!));
                        }
                        break;
                      case _CompactToolbarAction.networkDiagnostics:
                        unawaited(_openNetworkDiagnostics());
                        break;
                      case _CompactToolbarAction.snippets:
                        unawaited(_openCommandSnippetManager());
                        break;
                      case _CompactToolbarAction.macros:
                        unawaited(_openTerminalMacroManager());
                        break;
                      case _CompactToolbarAction.inputRecording:
                        if (activeTab != null) {
                          unawaited(_toggleTerminalInputRecording(activeTab));
                        }
                        break;
                      case _CompactToolbarAction.recordedMacros:
                        unawaited(_openTerminalRecordedMacroManager());
                        break;
                      case _CompactToolbarAction.sidebarSessions:
                        unawaited(_openMobileSidebar(_SidebarSection.sessions));
                        break;
                      case _CompactToolbarAction.sidebarFiles:
                        unawaited(_openMobileSidebar(_SidebarSection.files));
                        break;
                      case _CompactToolbarAction.sidebarAssistant:
                        unawaited(
                          _openMobileSidebar(_SidebarSection.assistant),
                        );
                        break;
                      case _CompactToolbarAction.search:
                        unawaited(_openTerminalSearch());
                        break;
                      case _CompactToolbarAction.transcript:
                        if (activeTab != null) {
                          unawaited(_toggleTranscriptLog(activeTab));
                        }
                        break;
                      case _CompactToolbarAction.reconnect:
                        if (activeTab != null &&
                            !activeTab.starting &&
                            !activeTab.restarting) {
                          unawaited(_restartSession(activeTab));
                        }
                        break;
                    }
                  },
                  itemBuilder: (context) => [
                    if (!kIsWeb) ...[
                      if (narrowToolbar)
                        const PopupMenuItem(
                          value: _CompactToolbarAction.localTerminal,
                          child: Text('本地终端'),
                        ),
                      if (narrowToolbar)
                        const PopupMenuItem(
                          value: _CompactToolbarAction.ssh,
                          child: Text('连接 SSH…'),
                        ),
                      const PopupMenuItem(
                        value: _CompactToolbarAction.sftp,
                        child: Text('连接 SFTP…'),
                      ),
                      const PopupMenuItem(
                        value: _CompactToolbarAction.serial,
                        child: Text('连接串口…'),
                      ),
                      const PopupMenuItem(
                        value: _CompactToolbarAction.telnet,
                        child: Text('连接 Telnet…'),
                      ),
                    ],
                    if (!kIsWeb && activeTab?.sshClient != null)
                      const PopupMenuItem(
                        value: _CompactToolbarAction.tunnels,
                        child: Text('SSH 隧道…'),
                      ),
                    if (activeTab?.connection.kind == _ConnectionKind.ssh &&
                        activeTab?.sshClient != null)
                      const PopupMenuItem(
                        value: _CompactToolbarAction.monitor,
                        child: Text('远程监控…'),
                      ),
                    if (!kIsWeb)
                      const PopupMenuItem(
                        value: _CompactToolbarAction.networkDiagnostics,
                        child: Text('网络诊断…'),
                      ),
                    const PopupMenuItem(
                      value: _CompactToolbarAction.snippets,
                      child: Text('命令片段…'),
                    ),
                    const PopupMenuItem(
                      value: _CompactToolbarAction.macros,
                      child: Text('命令宏…'),
                    ),
                    PopupMenuItem(
                      value: _CompactToolbarAction.inputRecording,
                      enabled:
                          activeTab != null &&
                          (activeTab.isConnected ||
                              activeTab.inputRecorder.isRecording ||
                              activeTab.inputRecorder.hasData),
                      child: Text(
                        activeTab?.inputRecorder.isRecording == true
                            ? '停止并保存键盘录制'
                            : activeTab?.inputRecorder.hasData == true
                            ? '保存键盘录制'
                            : '录制键盘输入…',
                      ),
                    ),
                    const PopupMenuItem(
                      value: _CompactToolbarAction.recordedMacros,
                      child: Text('录制宏管理…'),
                    ),
                    if (narrowToolbar) ...[
                      const PopupMenuDivider(),
                      const PopupMenuItem(
                        value: _CompactToolbarAction.sidebarSessions,
                        child: Text('会话面板'),
                      ),
                      const PopupMenuItem(
                        value: _CompactToolbarAction.sidebarFiles,
                        child: Text('文件面板'),
                      ),
                      const PopupMenuItem(
                        value: _CompactToolbarAction.sidebarAssistant,
                        child: Text('终端助手面板'),
                      ),
                    ],
                    PopupMenuItem(
                      value: _CompactToolbarAction.search,
                      enabled: _tabs.isNotEmpty,
                      child: const Text('搜索终端输出…'),
                    ),
                    if (activeTab != null) ...[
                      const PopupMenuItem(
                        value: _CompactToolbarAction.transcript,
                        child: Text('终端输出记录'),
                      ),
                      PopupMenuItem(
                        value: _CompactToolbarAction.reconnect,
                        enabled: !activeTab.starting && !activeTab.restarting,
                        child: const Text('重新连接当前会话'),
                      ),
                    ],
                  ],
                  icon: const Icon(Icons.more_horiz_rounded),
                ),
                IconButton(
                  tooltip: '快速连接',
                  onPressed: () => unawaited(
                    _handleNewSession(_NewSessionAction.quickConnect),
                  ),
                  icon: const Icon(Icons.bolt_rounded),
                ),
                if (!narrowToolbar)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Tooltip(
                      message: activeTab?.status ?? '准备就绪',
                      child: Icon(
                        Icons.circle,
                        size: 10,
                        color: _statusColor(activeTab, colors),
                      ),
                    ),
                  ),
                IconButton(
                  tooltip: '设置',
                  onPressed: () => unawaited(_openSettings()),
                  icon: const Icon(Icons.settings_outlined),
                ),
                const SizedBox(width: 8),
              ]
            : [
                if (!kIsWeb) ...[
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
                ],
                _ToolbarAction(
                  icon: Icons.lock_open_rounded,
                  label: 'SSH',
                  onPressed: () =>
                      unawaited(_handleNewSession(_NewSessionAction.ssh)),
                ),
                _ToolbarAction(
                  icon: Icons.folder_open_rounded,
                  label: 'SFTP',
                  onPressed: () =>
                      unawaited(_handleNewSession(_NewSessionAction.sftp)),
                ),
                if (!kIsWeb)
                  IconButton(
                    tooltip: activeTab?.tunnels.isNotEmpty == true
                        ? 'SSH 隧道 (${activeTab!.tunnels.length})'
                        : 'SSH 隧道',
                    onPressed: activeTab?.sshClient == null
                        ? null
                        : () => unawaited(_openSshTunnelManager(activeTab!)),
                    icon: Badge(
                      isLabelVisible: activeTab?.tunnels.isNotEmpty == true,
                      label: Text('${activeTab?.tunnels.length ?? 0}'),
                      child: const Icon(Icons.account_tree_outlined),
                    ),
                  ),
                if (activeTab?.connection.kind == _ConnectionKind.ssh &&
                    activeTab?.sshClient != null)
                  IconButton(
                    tooltip: '远程监控',
                    onPressed: () =>
                        unawaited(_openSshRemoteMonitor(activeTab!)),
                    icon: const Icon(Icons.monitor_heart_outlined),
                  ),
                if (!kIsWeb)
                  IconButton(
                    tooltip: '网络诊断',
                    onPressed: () => unawaited(_openNetworkDiagnostics()),
                    icon: const Icon(Icons.network_check_rounded),
                  ),
                IconButton(
                  tooltip: '命令片段',
                  onPressed: () => unawaited(_openCommandSnippetManager()),
                  icon: const Icon(Icons.terminal_outlined),
                ),
                IconButton(
                  tooltip: '命令宏',
                  onPressed: () => unawaited(_openTerminalMacroManager()),
                  icon: const Icon(Icons.playlist_play_rounded),
                ),
                IconButton(
                  tooltip: activeTab?.inputRecorder.isRecording == true
                      ? '停止并保存键盘录制'
                      : activeTab?.inputRecorder.hasData == true
                      ? '保存键盘录制'
                      : '录制键盘输入',
                  onPressed:
                      activeTab != null &&
                          (activeTab.isConnected ||
                              activeTab.inputRecorder.isRecording ||
                              activeTab.inputRecorder.hasData)
                      ? () =>
                            unawaited(_toggleTerminalInputRecording(activeTab))
                      : null,
                  color: activeTab?.inputRecorder.isRecording == true
                      ? colors.error
                      : activeTab?.inputRecorder.hasData == true
                      ? colors.primary
                      : null,
                  icon: Icon(
                    activeTab?.inputRecorder.isRecording == true
                        ? Icons.stop_circle_outlined
                        : activeTab?.inputRecorder.hasData == true
                        ? Icons.save_alt_rounded
                        : Icons.fiber_manual_record_rounded,
                  ),
                ),
                IconButton(
                  tooltip: '录制宏管理',
                  onPressed: () =>
                      unawaited(_openTerminalRecordedMacroManager()),
                  icon: const Icon(Icons.keyboard_alt_outlined),
                ),
                IconButton(
                  tooltip: '搜索终端输出 (Ctrl+F)',
                  onPressed: _tabs.isEmpty
                      ? null
                      : () => unawaited(_openTerminalSearch()),
                  icon: const Icon(Icons.manage_search_rounded),
                ),
                IconButton(
                  tooltip: activeTab == null
                      ? '终端输出记录'
                      : activeTab.transcript.isRecording
                      ? '停止并保存终端输出记录'
                      : activeTab.transcript.hasData
                      ? '保存终端输出记录'
                      : '开始记录终端输出',
                  onPressed: activeTab == null
                      ? null
                      : () => unawaited(_toggleTranscriptLog(activeTab)),
                  color: activeTab?.transcript.isRecording == true
                      ? colors.error
                      : activeTab?.transcript.hasData == true
                      ? colors.primary
                      : null,
                  icon: Icon(
                    activeTab?.transcript.isRecording == true
                        ? Icons.stop_circle_outlined
                        : activeTab?.transcript.hasData == true
                        ? Icons.save_alt_rounded
                        : Icons.radio_button_checked_rounded,
                  ),
                ),
                const SizedBox(width: 8),
                VerticalDivider(
                  width: 1,
                  indent: 14,
                  endIndent: 14,
                  color: colors.outlineVariant,
                ),
                const SizedBox(width: 12),
                Icon(
                  Icons.circle,
                  size: 10,
                  color: _statusColor(activeTab, colors),
                ),
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
                  onPressed: () => unawaited(
                    _handleNewSession(_NewSessionAction.quickConnect),
                  ),
                  icon: const Icon(Icons.bolt_rounded, size: 18),
                  label: const Text('快速连接'),
                ),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: '设置',
                  onPressed: () => unawaited(_openSettings()),
                  icon: const Icon(Icons.settings_outlined),
                ),
                const SizedBox(width: 14),
              ],
      ),
      body: narrowToolbar
          ? terminalArea
          : Row(
              children: [
                _buildSidebarRail(colors),
                VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: colors.outlineVariant,
                ),
                if (_sidebarSection == _SidebarSection.sessions)
                  _buildSessionSidebar(colors),
                if (_sidebarSection == _SidebarSection.files)
                  _buildFileSidebar(activeTab, colors),
                if (_sidebarSection == _SidebarSection.assistant)
                  TerminalAssistantPanel(
                    analyzer: activeTab?.assistant,
                    sessionTitle: activeTab?.title,
                    inlineHintsEnabled:
                        widget.settings.terminalAssistantInlineHints,
                    onToggleInlineHints: (value) => unawaited(
                      widget.settings.setTerminalAssistantInlineHints(value),
                    ),
                    onInsertCommand: (cmd) async {
                      if (activeTab != null && activeTab.isConnected) {
                        activeTab.focusNode.requestFocus();
                        activeTab.terminal.paste(cmd);
                        _showMessage('已将排错命令粘贴到终端；未自动发送 Enter');
                      }
                    },
                  ),
                Expanded(child: terminalArea),
                if (_assistantPanelOpen) ...[
                  VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: colors.outlineVariant,
                  ),
                  TerminalAssistantPanel(
                    analyzer: activeTab?.assistant,
                    sessionTitle: activeTab?.title,
                    inlineHintsEnabled:
                        widget.settings.terminalAssistantInlineHints,
                    onToggleInlineHints: (value) => unawaited(
                      widget.settings.setTerminalAssistantInlineHints(value),
                    ),
                    onInsertCommand: (cmd) async {
                      if (activeTab != null && activeTab.isConnected) {
                        activeTab.focusNode.requestFocus();
                        activeTab.terminal.paste(cmd);
                        _showMessage('已将排错命令粘贴到终端；未自动发送 Enter');
                      }
                    },
                  ),
                ],
              ],
            ),
    );
  }

  Widget _buildSidebarRail(ColorScheme colors) {
    final activeTab = _activeTab;
    Widget destination(
      _SidebarSection section,
      IconData icon,
      String label, {
      int badgeCount = 0,
    }) {
      final selected = _sidebarSection == section;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Tooltip(
          message: label,
          child: Material(
            color: selected
                ? colors.primary.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() => _sidebarSection = section),
              child: SizedBox(
                width: 38,
                height: 38,
                child: Badge(
                  isLabelVisible: badgeCount > 0,
                  label: Text(badgeCount > 9 ? '9+' : '$badgeCount'),
                  child: Icon(
                    icon,
                    size: 20,
                    color: selected ? colors.primary : colors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      width: 48,
      child: ColoredBox(
        color: colors.surfaceContainerLowest,
        child: Column(
          children: [
            const SizedBox(height: 10),
            destination(_SidebarSection.sessions, Icons.dns_outlined, '会话'),
            destination(
              _SidebarSection.files,
              Icons.folder_copy_outlined,
              '文件',
            ),
            if (activeTab == null)
              destination(
                _SidebarSection.assistant,
                Icons.tips_and_updates_outlined,
                '终端助手',
              )
            else
              ListenableBuilder(
                listenable: activeTab.assistant,
                builder: (context, _) => destination(
                  _SidebarSection.assistant,
                  Icons.tips_and_updates_outlined,
                  '终端助手',
                  badgeCount: activeTab.assistant.findings.length,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileSidebar(
    _TerminalTab? tab,
    ColorScheme colors, {
    double width = 260,
    bool standalone = false,
  }) {
    Widget placeholder({
      required String title,
      required String description,
    }) => SizedBox(
      width: width,
      child: ColoredBox(
        color: colors.surfaceContainerLow,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(
                description,
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => unawaited(
                  _handleNewSession(
                    tab?.connection.kind == _ConnectionKind.sftp
                        ? _NewSessionAction.sftp
                        : _NewSessionAction.ssh,
                  ),
                ),
                icon: Icon(
                  tab?.connection.kind == _ConnectionKind.sftp
                      ? Icons.folder_open_rounded
                      : Icons.lock_open_rounded,
                  size: 18,
                ),
                label: Text(
                  tab?.connection.kind == _ConnectionKind.sftp
                      ? '新建 SFTP'
                      : '新建 SSH',
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (tab == null) {
      return placeholder(
        title: 'SFTP / SCP 文件',
        description: '打开 SSH 会话后，可浏览、上传和下载远端文件。',
      );
    }
    if (!tab.connection.kind.usesSshTransport) {
      return placeholder(
        title: '当前不是 SSH 会话',
        description: 'SFTP 和 SCP 使用 SSH 连接。切换到 SSH 标签后即可管理远端文件。',
      );
    }
    if (tab.connection.kind == _ConnectionKind.sftp && !standalone) {
      return placeholder(title: '独立 SFTP 会话', description: '文件管理器已显示在当前工作区。');
    }
    if (tab.sshClient == null ||
        (tab.connection.kind == _ConnectionKind.ssh &&
            tab.sshSession == null)) {
      return placeholder(
        title: tab.connection.kind == _ConnectionKind.sftp
            ? 'SFTP 尚未连接'
            : 'SSH 尚未连接',
        description: tab.status.isEmpty ? '连接 SSH 后即可打开远端文件列表。' : tab.status,
      );
    }

    return SizedBox(
      width: width,
      child: RemoteFileBrowser(
        key: ValueKey('remote-files-${tab.id}'),
        client: tab.sshClient!,
        sessionIdentity:
            '${tab.connection.remoteFileEndpointKey}:${tab.sshClient!.username}',
        sessionTitle: tab.title,
        initialPath: tab.remoteDirectory,
        refreshToken: tab.remoteRefreshToken,
        protocol: tab.fileTransferProtocol,
        onDirectoryChanged: (path) => tab.remoteDirectory = path,
        onProtocolChanged: (protocol) => setState(() {
          tab.fileTransferProtocol = protocol;
        }),
        onMessage: (message, {isError}) =>
            _showMessage(message, isError: isError ?? false),
      ),
    );
  }

  Future<void> _uploadDroppedToTerminal(
    _TerminalTab tab,
    List<DropItem> dropped,
  ) async {
    final client = tab.sshClient;
    if (tab.id != _activeTabId || client == null || tab.sshSession == null) {
      return;
    }
    final files = dropped.whereType<DropItemFile>().toList();
    final directories = dropped.whereType<DropItemDirectory>().length;
    if (files.isEmpty) {
      if (directories > 0) _showMessage('拖拽目录上传暂未支持');
      return;
    }

    SftpClient? sftp;
    try {
      sftp = await client.sftp();
      final remoteDirectory = tab.remoteDirectory ?? await sftp.absolute('.');
      final existingNames = (await sftp.listdir(
        remoteDirectory,
      )).map((entry) => entry.filename).toSet();
      var completed = 0;
      for (final file in files) {
        if (existingNames.contains(file.name) &&
            !await _confirmRemoteOverwrite(file.name)) {
          continue;
        }
        await uploadRemoteFile(
          client: client,
          remoteDirectory: remoteDirectory,
          source: RemoteFileSource(
            name: file.name,
            length: file.length,
            openRead: file.openRead,
          ),
          protocol: tab.fileTransferProtocol,
          sftpClient: sftp,
        );
        completed++;
        existingNames.add(file.name);
      }
      tab.remoteDirectory = remoteDirectory;
      tab.remoteRefreshToken++;
      _showMessage(
        completed == 0 ? '没有上传文件' : '已上传 $completed 个文件到 $remoteDirectory',
      );
      _refresh(tab);
    } catch (error) {
      _showMessage('上传到远端失败：$error', isError: true);
    } finally {
      if (sftp != null) await sftp.close();
    }
  }

  Future<bool> _confirmRemoteOverwrite(String name) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('覆盖远端项目？'),
          content: Text('“$name”已存在。继续会替换现有内容。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('覆盖'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _insertRemotePath(_TerminalTab tab, String path) async {
    if (tab.id != _activeTabId || !tab.isConnected) return;
    if (_hasInputBroadcast) {
      final confirmed = await _confirmBroadcastPaste(
        '远端路径“$path”会粘贴到输入广播目标。',
        confirmLabel: '插入路径',
      );
      if (!mounted || tab.isClosed || confirmed != true) return;
    }
    tab.focusNode.requestFocus();
    tab.terminal.paste(path);
  }

  Widget _buildSessionSidebar(ColorScheme colors, {double width = 260}) {
    final query = _sessionSearch.trim().toLowerCase();
    bool matches(SessionRecord record) =>
        query.isEmpty ||
        record.name.toLowerCase().contains(query) ||
        record.address.toLowerCase().contains(query) ||
        record.endpointLabel.toLowerCase().contains(query) ||
        record.group.toLowerCase().contains(query);
    final saved = _savedSessions
        .where(matches)
        .where(
          (record) =>
              _sessionGroupFilter == null ||
              record.group == _sessionGroupFilter,
        )
        .toList();
    final recent = _recentSessions.where(matches).toList();

    return SizedBox(
      width: width,
      child: ColoredBox(
        color: colors.surfaceContainerLow,
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
                    tooltip: '会话分类',
                    onPressed: _createSessionGroup,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    visualDensity: VisualDensity.compact,
                  ),
                  PopupMenuButton<_SessionSidebarAction>(
                    tooltip: '导入或导出会话',
                    onSelected: (action) {
                      switch (action) {
                        case _SessionSidebarAction.importOpenSshDefault:
                          unawaited(
                            _importSshConfig(
                              _SshConfigImportSource.defaultConfig,
                            ),
                          );
                          break;
                        case _SessionSidebarAction.importOpenSshFile:
                          unawaited(
                            _importSshConfig(_SshConfigImportSource.chooseFile),
                          );
                          break;
                        case _SessionSidebarAction.importBackup:
                          unawaited(_importSessions());
                          break;
                        case _SessionSidebarAction.exportBackup:
                          unawaited(_exportSessions());
                          break;
                      }
                    },
                    itemBuilder: (context) => [
                      if (!kIsWeb) ...[
                        const PopupMenuItem(
                          value: _SessionSidebarAction.importOpenSshDefault,
                          child: Text('导入 ~/.ssh/config'),
                        ),
                        const PopupMenuItem(
                          value: _SessionSidebarAction.importOpenSshFile,
                          child: Text('选择 OpenSSH 配置…'),
                        ),
                        const PopupMenuDivider(),
                      ],
                      const PopupMenuItem(
                        value: _SessionSidebarAction.importBackup,
                        child: Text('导入会话备份…'),
                      ),
                      const PopupMenuItem(
                        value: _SessionSidebarAction.exportBackup,
                        child: Text('导出会话备份…'),
                      ),
                    ],
                    icon: const Icon(Icons.swap_vert_rounded),
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
            SizedBox(
              height: 38,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: const Text('全部'),
                      selected: _sessionGroupFilter == null,
                      onSelected: (_) =>
                          setState(() => _sessionGroupFilter = null),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: const Text('未分类'),
                      selected: _sessionGroupFilter == '',
                      onSelected: (_) =>
                          setState(() => _sessionGroupFilter = ''),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  for (final group in _sessionGroups)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(group),
                        selected: _sessionGroupFilter == group,
                        onSelected: (_) =>
                            setState(() => _sessionGroupFilter = group),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
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
    final protocolIcon = switch (record.protocol) {
      SessionProtocol.serial => Icons.usb_rounded,
      SessionProtocol.telnet => Icons.lan_rounded,
      SessionProtocol.ssh => Icons.lock_open_rounded,
      SessionProtocol.sftp => Icons.folder_open_rounded,
    };
    return Material(
      color: Colors.transparent,
      child: ListTile(
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
            if (saved)
              const PopupMenuItem(
                value: _RecordAction.moveGroup,
                child: Text('移动到分类…'),
              ),
            if (!saved)
              const PopupMenuItem(
                value: _RecordAction.removeRecent,
                child: Text('从最近连接移除'),
              ),
          ],
          icon: const Icon(Icons.more_vert_rounded, size: 19),
        ),
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

  Future<void> _createSessionGroup() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) =>
          const _SessionNameDialog(title: '新建会话分类', initialName: ''),
    );
    if (!mounted || name == null) return;
    final duplicate = _sessionGroups.any(
      (group) => group.toLowerCase() == name.toLowerCase(),
    );
    if (duplicate) {
      _showMessage('分类“$name”已存在');
      return;
    }
    final groups = [..._sessionGroups, name]
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    await _sessionStore.saveGroups(groups);
    if (!mounted) return;
    setState(() {
      _sessionGroups = groups;
      _sessionGroupFilter = name;
    });
  }

  Future<void> _exportSessions() async {
    try {
      await _recordsReady;
      final payload = <String, Object>{
        'format': 'geekcore-term-sessions',
        'version': 1,
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
        'groups': _sessionGroups,
        'sessions': _savedSessions.map((record) => record.toJson()).toList(),
      };
      final bytes = Uint8List.fromList(
        utf8.encode(const JsonEncoder.withIndent('  ').convert(payload)),
      );
      final path = await FilePicker.saveFile(
        dialogTitle: '导出已保存会话',
        fileName: 'geekcore-term-sessions.json',
        bytes: bytes,
      );
      if (mounted && path != null) {
        _showMessage('已导出 ${_savedSessions.length} 个会话');
      }
    } catch (error) {
      _showMessage('导出会话失败：$error', isError: true);
    }
  }

  Future<void> _importSessions() async {
    try {
      final file = await FilePicker.pickFile(
        dialogTitle: '选择 Geekcore Term 会话 JSON',
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (bytes.length > 2 * 1024 * 1024) {
        throw const FormatException('会话文件不能大于 2 MiB');
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic> ||
          decoded['format'] != 'geekcore-term-sessions' ||
          decoded['version'] != 1 ||
          decoded['sessions'] is! List) {
        throw const FormatException('文件不是受支持的 Geekcore Term 会话备份');
      }
      final encodedSessions = decoded['sessions'] as List<Object?>;
      if (encodedSessions.length > 5000) {
        throw const FormatException('单个备份最多导入 5000 个会话');
      }
      final parsed = <SessionRecord>[
        for (var index = 0; index < encodedSessions.length; index++)
          SessionRecord.fromJson(jsonEncode(encodedSessions[index])).copyWith(
            id: 'import-${DateTime.now().microsecondsSinceEpoch}-$index',
          ),
      ];
      if (parsed.isEmpty) {
        _showMessage('备份中没有会话');
        return;
      }
      if (!mounted) return;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('导入会话'),
          content: Text(
            '备份包含 ${parsed.length} 个会话。导入内容只包含连接配置，不包含密码、私钥正文或已保存凭据。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('导入'),
            ),
          ],
        ),
      );
      if (!mounted || accepted != true) return;
      await _recordsReady;
      final endpointKeys = _savedSessions
          .map((record) => record.endpointKey)
          .toSet();
      final additions = <SessionRecord>[];
      for (final record in parsed) {
        if (endpointKeys.add(record.endpointKey)) additions.add(record);
      }
      if (additions.isEmpty) {
        _showMessage('备份中的会话已全部存在');
        return;
      }
      final updated = [...additions.reversed, ..._savedSessions];
      final groups = {
        ..._sessionGroups,
        for (final record in additions)
          if (record.group.isNotEmpty) record.group,
        if (decoded['groups'] is List)
          ...(decoded['groups'] as List<Object?>).whereType<String>().where(
            (group) => group.trim().isNotEmpty,
          ),
      }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      await _sessionStore.saveSaved(updated);
      await _sessionStore.saveGroups(groups);
      if (!mounted) return;
      setState(() {
        _savedSessions = updated;
        _sessionGroups = groups;
      });
      _showMessage(
        '已导入 ${additions.length} 个会话${parsed.length == additions.length ? '' : '，跳过 ${parsed.length - additions.length} 个重复项'}',
      );
    } catch (error) {
      _showMessage('导入会话失败：$error', isError: true);
    }
  }

  Future<void> _importSshConfig(_SshConfigImportSource source) async {
    if (kIsWeb) {
      _showMessage('浏览器版本无法读取本机 .ssh 配置');
      return;
    }

    try {
      late final SshConfigFileData configFile;
      if (source == _SshConfigImportSource.defaultConfig) {
        final defaultConfig = await readDefaultSshConfig();
        if (defaultConfig == null) {
          _showMessage('未找到 ~/.ssh/config，请选择配置文件');
          return;
        }
        configFile = defaultConfig;
      } else {
        final pickedFile = await FilePicker.pickFile(
          dialogTitle: '选择 OpenSSH 配置文件（通常为 ~/.ssh/config）',
        );
        if (pickedFile == null) return;
        final bytes = await pickedFile.readAsBytes();
        if (bytes.length > 2 * 1024 * 1024) {
          throw const FormatException('SSH 配置文件不能大于 2 MiB');
        }
        configFile = SshConfigFileData(
          path: pickedFile.path ?? pickedFile.name,
          content: utf8.decode(bytes),
        );
      }

      final parsed = parseOpenSshConfig(configFile.content);
      if (!mounted) return;
      if (parsed.hosts.isEmpty) {
        final warning = parsed.warnings.isEmpty
            ? '文件中没有可导入的 Host 别名'
            : parsed.warnings.join('；');
        _showMessage('没有可导入的主机：$warning', isError: true);
        return;
      }

      final selectedHosts = await showDialog<List<SshConfigHost>>(
        context: context,
        builder: (_) => SshConfigImportDialog(
          hosts: parsed.hosts,
          warnings: parsed.warnings,
        ),
      );
      if (!mounted || selectedHosts == null || selectedHosts.isEmpty) return;

      await _recordsReady;
      final existingEndpoints = _savedSessions
          .map((record) => record.endpointKey)
          .toSet();
      final imported = <SessionRecord>[];
      var duplicateCount = 0;
      for (final host in selectedHosts) {
        final record = SessionRecord(
          id: 'ssh-config-${DateTime.now().microsecondsSinceEpoch}-${imported.length}',
          name: host.alias,
          protocol: SessionProtocol.ssh,
          address: host.hostName,
          port: host.port,
          username: host.username,
          identityFile: host.identityFile,
          sshConfigAlias: host.alias,
          jumpHost: host.proxyJump == null
              ? null
              : SshJumpHost(
                  name: host.proxyJump!.alias,
                  address: host.proxyJump!.hostName,
                  port: host.proxyJump!.port,
                  username: host.proxyJump!.username,
                  identityFile: host.proxyJump!.identityFile,
                  sshConfigAlias: host.proxyJump!.alias,
                ),
          lastConnectedAt: DateTime.now(),
        );
        if (!existingEndpoints.add(record.endpointKey)) {
          duplicateCount++;
          continue;
        }
        imported.add(record);
      }

      if (imported.isEmpty) {
        _showMessage('选中的 SSH 配置已存在于已保存会话中');
        return;
      }
      final updated = [...imported.reversed, ..._savedSessions];
      await _sessionStore.saveSaved(updated);
      if (!mounted) return;
      setState(() => _savedSessions = updated);
      _showMessage(
        '已导入 ${imported.length} 个 SSH 会话${duplicateCount == 0 ? '' : '，跳过 $duplicateCount 个重复项'}',
      );
    } catch (error) {
      _showMessage('导入 SSH 配置失败：$error', isError: true);
    }
  }

  Future<void> _openMobileSidebar(_SidebarSection initialSection) async {
    if (!mounted) return;
    setState(() => _sidebarSection = initialSection);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final size = MediaQuery.sizeOf(context);
          final colors = Theme.of(context).colorScheme;
          void select(_SidebarSection section) {
            setState(() => _sidebarSection = section);
            setSheetState(() {});
          }

          final width = size.width;
          final panel = switch (_sidebarSection) {
            _SidebarSection.sessions => _buildSessionSidebar(
              colors,
              width: width,
            ),
            _SidebarSection.files => _buildFileSidebar(
              _activeTab,
              colors,
              width: width,
            ),
            _SidebarSection.assistant => TerminalAssistantPanel(
              analyzer: _activeTab?.assistant,
              sessionTitle: _activeTab?.title,
              inlineHintsEnabled: widget.settings.terminalAssistantInlineHints,
              onToggleInlineHints: (value) => unawaited(
                widget.settings.setTerminalAssistantInlineHints(value),
              ),
              onInsertCommand: (cmd) async {
                final tab = _activeTab;
                if (tab != null && tab.isConnected) {
                  tab.focusNode.requestFocus();
                  tab.terminal.paste(cmd);
                  _showMessage('已将排错命令粘贴到终端；未自动发送 Enter');
                }
              },
              width: width,
            ),
          };

          return SafeArea(
            top: false,
            child: SizedBox(
              width: width,
              height: size.height * 0.8,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
                    child: Row(
                      children: [
                        Container(
                          width: 34,
                          height: 4,
                          decoration: BoxDecoration(
                            color: colors.outlineVariant,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(width: 12),
                        ChoiceChip(
                          label: const Text('会话'),
                          selected: _sidebarSection == _SidebarSection.sessions,
                          onSelected: (_) => select(_SidebarSection.sessions),
                        ),
                        const SizedBox(width: 6),
                        ChoiceChip(
                          label: const Text('文件'),
                          selected: _sidebarSection == _SidebarSection.files,
                          onSelected: (_) => select(_SidebarSection.files),
                        ),
                        const SizedBox(width: 6),
                        ChoiceChip(
                          label: const Text('助手'),
                          selected:
                              _sidebarSection == _SidebarSection.assistant,
                          onSelected: (_) => select(_SidebarSection.assistant),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: '关闭侧栏',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(child: panel),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTabBar(ColorScheme colors) {
    return Material(
      color: colors.surfaceContainerLow,
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
                  : ReorderableListView.builder(
                      scrollDirection: Axis.horizontal,
                      buildDefaultDragHandles: false,
                      padding: EdgeInsets.zero,
                      itemCount: _tabs.length,
                      onReorderItem: _reorderTabs,
                      itemBuilder: (context, index) =>
                          _buildTab(_tabs[index], colors, index: index),
                    ),
            ),
            if (_tabs.length > 1)
              IconButton(
                tooltip: _multiExecTabIds.isEmpty
                    ? '多会话输入广播'
                    : '管理多会话输入广播（${_multiExecTabIds.length} 个目标）',
                onPressed: () => unawaited(_configureMultiExec()),
                color: _multiExecTabIds.isEmpty ? null : colors.error,
                icon: Badge(
                  isLabelVisible: _multiExecTabIds.isNotEmpty,
                  label: Text('${_multiExecTabIds.length}'),
                  child: const Icon(Icons.groups_outlined, size: 19),
                ),
              ),
            if (_splitMode != TerminalSplitMode.none)
              IconButton(
                tooltip: _broadcastSplitInput ? '关闭分屏输入广播' : '向所有分屏会话广播输入',
                onPressed: () => setState(
                  () => _broadcastSplitInput = !_broadcastSplitInput,
                ),
                color: _broadcastSplitInput ? colors.primary : null,
                icon: const Icon(Icons.campaign_outlined, size: 19),
              ),
            PopupMenuButton<TerminalSplitMode>(
              tooltip: '终端分屏',
              initialValue: _splitMode,
              onSelected: (mode) => unawaited(_setSplitMode(mode)),
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: TerminalSplitMode.none,
                  child: Text('单终端'),
                ),
                PopupMenuDivider(),
                PopupMenuItem(
                  value: TerminalSplitMode.vertical,
                  child: Text('左右两个终端'),
                ),
                PopupMenuItem(
                  value: TerminalSplitMode.horizontal,
                  child: Text('上下两个终端'),
                ),
                PopupMenuItem(
                  value: TerminalSplitMode.quad,
                  child: Text('四个终端'),
                ),
              ],
              icon: const Icon(Icons.view_quilt_outlined, size: 20),
            ),
            IconButton(
              tooltip: _assistantPanelOpen ? '隐藏终端助手' : '显示终端助手',
              onPressed: () => setState(
                () => _assistantPanelOpen = !_assistantPanelOpen,
              ),
              color: _assistantPanelOpen ? colors.primary : null,
              icon: _activeTab == null
                  ? const Icon(Icons.tips_and_updates_outlined, size: 20)
                  : ListenableBuilder(
                      listenable: _activeTab!.assistant,
                      builder: (context, _) {
                        final count = _activeTab!.assistant.findings.length;
                        return Badge(
                          isLabelVisible: count > 0,
                          label: Text(count > 9 ? '9+' : '$count'),
                          child: const Icon(
                            Icons.tips_and_updates_outlined,
                            size: 20,
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBroadcastBanner(ColorScheme colors) {
    final targetIds = <int>{..._multiExecTabIds};
    if (_broadcastSplitInput && _splitMode != TerminalSplitMode.none) {
      targetIds.addAll(_splitTabIds);
    }
    final names = _tabs
        .where((tab) => targetIds.contains(tab.id))
        .map((tab) => tab.isConnected ? tab.title : '${tab.title}（未连接）')
        .join('、');
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: colors.errorContainer.withValues(alpha: 0.72),
      child: Row(
        children: [
          Icon(Icons.campaign_rounded, size: 15, color: colors.error),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              '输入广播已开启 · 目标：$names',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.onErrorContainer,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (_multiExecTabIds.isNotEmpty)
            IconButton(
              tooltip: '关闭多会话输入广播',
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(_multiExecTabIds.clear),
              icon: const Icon(Icons.close_rounded, size: 16),
            ),
        ],
      ),
    );
  }

  Widget _buildTerminalWorkspace(ColorScheme colors) {
    if (_tabs.isEmpty && _splitMode == TerminalSplitMode.none) {
      return _buildHomeWorkspace(colors);
    }
    if (_splitMode == TerminalSplitMode.none) {
      final activeIndex = _tabs.indexWhere((tab) => tab.id == _activeTabId);
      return IndexedStack(
        index: activeIndex < 0 ? 0 : activeIndex,
        children: [for (final tab in _tabs) _buildTerminalPane(tab, colors)],
      );
    }

    final visibleTabs = [
      for (final id in _splitTabIds)
        for (final tab in _tabs)
          if (tab.id == id) tab,
    ];
    Widget paneAt(int index) {
      if (index >= visibleTabs.length) {
        return Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.terminal_rounded, size: 28, color: colors.outline),
                const SizedBox(height: 8),
                Text(
                  '此窗格尚未连接',
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
                const SizedBox(height: 6),
                FilledButton.tonalIcon(
                  onPressed: () => unawaited(
                    _handleNewSession(_NewSessionAction.quickConnect),
                  ),
                  icon: const Icon(Icons.add_rounded, size: 17),
                  label: const Text('连接会话'),
                ),
              ],
            ),
          ),
        );
      }
      final tab = visibleTabs[index];
      return Expanded(
        child: Container(
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            border: Border.all(
              color: tab.id == _activeTabId
                  ? colors.primary.withValues(alpha: 0.6)
                  : colors.outlineVariant,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Material(
                color: colors.surfaceContainerLow,
                child: InkWell(
                  onTap: () => _selectTab(tab),
                  child: SizedBox(
                    height: 26,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          Icon(
                            tab.connection.kind == _ConnectionKind.sftp
                                ? Icons.folder_open_rounded
                                : Icons.terminal_rounded,
                            size: 14,
                            color: tab.id == _activeTabId
                                ? colors.primary
                                : colors.onSurfaceVariant,
                          ),
                          if (tab.inputRecorder.isRecording) ...[
                            const SizedBox(width: 5),
                            Tooltip(
                              message: '正在录制键盘输入',
                              child: Icon(
                                Icons.fiber_manual_record_rounded,
                                size: 12,
                                color: colors.error,
                              ),
                            ),
                          ],
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '${tab.title} · ${tab.status}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 10),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(child: _buildTerminalPane(tab, colors)),
            ],
          ),
        ),
      );
    }

    return switch (_splitMode) {
      TerminalSplitMode.none => _buildTerminalPane(visibleTabs.first, colors),
      TerminalSplitMode.vertical => Row(children: [paneAt(0), paneAt(1)]),
      TerminalSplitMode.horizontal => Column(children: [paneAt(0), paneAt(1)]),
      TerminalSplitMode.quad => Column(
        children: [
          Expanded(child: Row(children: [paneAt(0), paneAt(1)])),
          Expanded(child: Row(children: [paneAt(2), paneAt(3)])),
        ],
      ),
    };
  }

  Widget _buildTab(_TerminalTab tab, ColorScheme colors, {required int index}) {
    final selected = tab.id == _activeTabId;
    final dragHandle = SizedBox(
      width: 19,
      height: 30,
      child: Center(
        child: Icon(
          Icons.drag_indicator_rounded,
          size: 16,
          color: selected ? colors.primary : colors.outline,
        ),
      ),
    );
    final dragListener = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.fuchsia =>
        ReorderableDelayedDragStartListener(index: index, child: dragHandle),
      _ => ReorderableDragStartListener(index: index, child: dragHandle),
    };
    return KeyedSubtree(
      key: ValueKey('terminal-tab-${tab.id}'),
      child: Padding(
        padding: const EdgeInsets.only(left: 5, top: 5, bottom: 5),
        child: Material(
          color: selected ? colors.surfaceContainerHighest : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          child: InkWell(
            borderRadius: BorderRadius.circular(7),
            onTap: () => _selectTab(tab),
            child: SizedBox(
              width: 224,
              child: Padding(
                padding: const EdgeInsets.only(left: 4, right: 4),
                child: Row(
                  children: [
                    Tooltip(message: '拖动以调整标签顺序', child: dragListener),
                    const SizedBox(width: 2),
                    Icon(
                      tab.connection.kind == _ConnectionKind.sftp
                          ? Icons.folder_open_rounded
                          : Icons.terminal_rounded,
                      size: 16,
                      color: selected
                          ? colors.primary
                          : colors.onSurfaceVariant,
                    ),
                    if (tab.inputRecorder.isRecording) ...[
                      const SizedBox(width: 5),
                      Tooltip(
                        message: '正在录制键盘输入',
                        child: Icon(
                          Icons.fiber_manual_record_rounded,
                          size: 12,
                          color: colors.error,
                        ),
                      ),
                    ],
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tab.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            tab.status,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 9,
                              color: _statusColor(tab, colors),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: '关闭 ${tab.title} (Ctrl+W)',
                      onPressed: () => unawaited(_closeTab(tab)),
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
      ),
    );
  }

  Widget _buildTerminalPane(_TerminalTab tab, ColorScheme colors) {
    if (tab.connection.kind == _ConnectionKind.sftp) {
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
              child: LayoutBuilder(
                builder: (context, constraints) => _buildFileSidebar(
                  tab,
                  colors,
                  width: constraints.maxWidth,
                  standalone: true,
                ),
              ),
            ),
          ],
        ),
      );
    }
    final terminalTheme = widget.settings.terminalTheme;
    final isActiveSsh =
        tab.id == _activeTabId &&
        tab.connection.kind == _ConnectionKind.ssh &&
        tab.sshSession != null;
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
            child: DropTarget(
              enable: isActiveSsh,
              onDragEntered: (_) {
                if (tab.id == _activeTabId) {
                  setState(() => tab.localFileDragHover = true);
                }
              },
              onDragExited: (_) {
                if (tab.localFileDragHover && mounted) {
                  setState(() => tab.localFileDragHover = false);
                }
              },
              onDragDone: (details) {
                if (tab.localFileDragHover && mounted) {
                  setState(() => tab.localFileDragHover = false);
                }
                unawaited(_uploadDroppedToTerminal(tab, details.files));
              },
              child: DragTarget<String>(
                onWillAcceptWithDetails: (details) =>
                    tab.id == _activeTabId && tab.isConnected,
                onAcceptWithDetails: (details) =>
                    unawaited(_insertRemotePath(tab, details.data)),
                builder: (context, candidates, rejected) {
                  final draggingRemoteFile = candidates.isNotEmpty;
                  final draggingLocalFile = tab.localFileDragHover;
                  return ColoredBox(
                    color: terminalTheme.background,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        TerminalView(
                          tab.terminal,
                          key: tab.terminalViewKey,
                          controller: tab.terminalController,
                          scrollController: tab.scrollController,
                          focusNode: tab.focusNode,
                          autofocus: false,
                          // Keep Flutter's text input connection active for IBus/Fcitx
                          // composition on Linux, including Wayland sessions.
                          hardwareKeyboardOnly: false,
                          keyboardType: TextInputType.multiline,
                          onKeyEvent: (focusNode, event) =>
                              _handleTerminalKeyEvent(tab, focusNode, event),
                          onTapDownIntercept: (_, offset) =>
                              _prepareTerminalLinkOpen(tab, offset),
                          onTapUp: (_, _) {
                            final pendingLink = tab.pendingExternalLink;
                            tab.pendingExternalLink = null;
                            if (pendingLink != null) {
                              unawaited(_openTerminalLink(pendingLink));
                            }
                            if (_activeTabId != tab.id) _selectTab(tab);
                          },
                          autoResize: true,
                          backgroundOpacity: 1,
                          padding: const EdgeInsets.all(12),
                          theme: terminalTheme,
                          textStyle: TerminalStyle(
                            fontSize: widget.settings.terminalFontSize,
                            fontFamily:
                                widget.settings.terminalFontFamily.familyName,
                          ),
                          onSecondaryTapDown: (details, offset) {
                            unawaited(_handleSecondaryTap(tab));
                          },
                        ),
                        TerminalChartOverlay(
                          coordinator: tab.chartCoordinator,
                          terminal: tab.terminal,
                          scrollController: tab.scrollController,
                          textStyle: TerminalStyle(
                            fontSize: widget.settings.terminalFontSize,
                            fontFamily:
                                widget.settings.terminalFontFamily.familyName,
                          ),
                          padding: const EdgeInsets.all(12),
                        ),
                        if (draggingRemoteFile || draggingLocalFile)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: ColoredBox(
                                color: colors.primary.withValues(alpha: 0.08),
                                child: Center(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: colors.surfaceContainerHigh,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: colors.primary.withValues(
                                          alpha: 0.55,
                                        ),
                                      ),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 18,
                                        vertical: 12,
                                      ),
                                      child: Text(
                                        draggingRemoteFile
                                            ? '松开鼠标以插入远端绝对路径'
                                            : '松开鼠标以上传到 ${tab.remoteDirectory ?? '远端当前目录'}',
                                        style: TextStyle(
                                          color: colors.onSurface,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHomeWorkspace(ColorScheme colors) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    final recent = _recentSessions.take(6).toList();
    final quickActions =
        <({String title, String subtitle, IconData icon, VoidCallback onTap})>[
          (
            title: '本地终端',
            subtitle: '打开系统 Shell',
            icon: Icons.terminal_rounded,
            onTap: _addLocalShellTab,
          ),
          (
            title: 'SSH',
            subtitle: '连接远程主机',
            icon: Icons.lock_outline_rounded,
            onTap: () => unawaited(_handleNewSession(_NewSessionAction.ssh)),
          ),
          (
            title: 'SFTP',
            subtitle: '仅浏览和传输文件',
            icon: Icons.folder_open_rounded,
            onTap: () => unawaited(_handleNewSession(_NewSessionAction.sftp)),
          ),
          (
            title: '串口',
            subtitle: '连接设备控制台',
            icon: Icons.usb_rounded,
            onTap: () => unawaited(_handleNewSession(_NewSessionAction.serial)),
          ),
          (
            title: 'Telnet',
            subtitle: '连接远端服务',
            icon: Icons.lan_rounded,
            onTap: () => unawaited(_handleNewSession(_NewSessionAction.telnet)),
          ),
        ];
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(compact ? 20 : 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.terminal_rounded, size: 36, color: colors.primary),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Geekcore Term',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '选择连接方式开始，或从会话记录中重新打开常用连接。',
                          maxLines: compact ? 2 : 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '快速开始',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '选择连接方式',
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth >= 700
                      ? 4
                      : constraints.maxWidth >= 460
                      ? 2
                      : 1;
                  final cardWidth =
                      (constraints.maxWidth - 12 * (columns - 1)) / columns;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final action in quickActions)
                        SizedBox(
                          width: cardWidth,
                          child: Card(
                            key: ValueKey('home-quick-${action.title}'),
                            margin: EdgeInsets.zero,
                            elevation: 0,
                            color: colors.surfaceContainerLow,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                              side: BorderSide(color: colors.outlineVariant),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: action.onTap,
                              child: SizedBox(
                                height: 88,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 38,
                                        height: 38,
                                        decoration: BoxDecoration(
                                          color: colors.primaryContainer,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Icon(
                                          action.icon,
                                          size: 20,
                                          color: colors.onPrimaryContainer,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              action.title,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(height: 3),
                                            Text(
                                              action.subtitle,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: colors.onSurfaceVariant,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Icon(
                                        Icons.arrow_forward_rounded,
                                        size: 16,
                                        color: colors.onSurfaceVariant,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
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
                  '成功连接过的串口、Telnet、SSH 和 SFTP 会显示在这里。',
                  style: TextStyle(color: colors.onSurfaceVariant),
                )
              else
                for (final record in recent)
                  Card(
                    margin: const EdgeInsets.only(bottom: 6),
                    color: colors.surfaceContainerLow,
                    child: ListTile(
                      leading: Icon(switch (record.protocol) {
                        SessionProtocol.serial => Icons.usb_rounded,
                        SessionProtocol.telnet => Icons.lan_rounded,
                        SessionProtocol.ssh => Icons.lock_open_rounded,
                        SessionProtocol.sftp => Icons.folder_open_rounded,
                      }, color: colors.primary),
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
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        if (tab.chartCoordinator.hasActiveRenderBlock) {
          tab.chartCoordinator.closeActiveCharts();
          return KeyEventResult.handled;
        }
      }

      final primaryPressed = defaultTargetPlatform == TargetPlatform.macOS
          ? HardwareKeyboard.instance.isMetaPressed
          : HardwareKeyboard.instance.isControlPressed;
      final shiftPressed = HardwareKeyboard.instance.isShiftPressed;
      final altPressed = HardwareKeyboard.instance.isAltPressed;
      final shortcuts = widget.settings.terminalShortcuts;
      bool matches(TerminalShortcutAction action) => shortcuts[action]!.matches(
        event,
        primaryPressed: primaryPressed,
        shiftPressed: shiftPressed,
        altPressed: altPressed,
      );

      if (matches(TerminalShortcutAction.newLocalTerminal)) {
        _addLocalShellTab();
        return KeyEventResult.handled;
      }
      if (matches(TerminalShortcutAction.quickConnect)) {
        unawaited(_handleNewSession(_NewSessionAction.quickConnect));
        return KeyEventResult.handled;
      }
      if (matches(TerminalShortcutAction.search)) {
        unawaited(_openTerminalSearch(tab));
        return KeyEventResult.handled;
      }
      if (matches(TerminalShortcutAction.copy)) {
        unawaited(_copyTerminalSelection(tab));
        return KeyEventResult.handled;
      }
      if (matches(TerminalShortcutAction.paste)) {
        unawaited(_pasteClipboard(tab));
        return KeyEventResult.handled;
      }
      if (matches(TerminalShortcutAction.closeTab)) {
        unawaited(_closeTab(tab));
        return KeyEventResult.handled;
      }
      if (matches(TerminalShortcutAction.nextTab)) {
        _selectAdjacentTab(1);
        return KeyEventResult.handled;
      }
      if (matches(TerminalShortcutAction.previousTab)) {
        _selectAdjacentTab(-1);
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

enum _NewSessionAction {
  local,
  serial,
  telnet,
  ssh,
  sftp,
  quickConnect,
  addSession,
}

enum _SshConfigImportSource { defaultConfig, chooseFile }

enum _SidebarSection { sessions, files, assistant }

enum _RecordAction { save, rename, delete, removeRecent, moveGroup }

enum _TranscriptCloseAction { save, discard, cancel }

enum _SessionSidebarAction {
  importOpenSshDefault,
  importOpenSshFile,
  importBackup,
  exportBackup,
}

enum _ConnectionKind {
  local,
  serial,
  telnet,
  ssh,
  sftp;

  bool get usesSshTransport => this == ssh || this == sftp;
}

enum _SshAuthMethod { key, password }

enum _CompactToolbarAction {
  localTerminal,
  ssh,
  sftp,
  sidebarSessions,
  sidebarFiles,
  sidebarAssistant,
  serial,
  telnet,
  tunnels,
  monitor,
  networkDiagnostics,
  snippets,
  macros,
  inputRecording,
  recordedMacros,
  search,
  transcript,
  reconnect,
}

enum _ConnectionDialogMode { quickConnect, addSession }

class _TerminalConnection {
  const _TerminalConnection.local()
    : kind = _ConnectionKind.local,
      address = '',
      port = 0,
      dataBits = 8,
      parity = 'none',
      stopBits = 1,
      flowControl = 'none',
      username = '',
      password = null,
      rememberCredentials = false,
      webSocketUrl = '',
      portKnockActions = const [],
      authenticationMode = SshAuthenticationMode.automatic,
      privateKeyPem = null,
      privateKeyPassphrase = null,
      sessionTitle = null,
      identityFile = null,
      sshConfigAlias = null,
      jumpHost = null,
      sshProxy = null,
      proxyPassword = null,
      rememberProxyCredentials = false;

  const _TerminalConnection.serial(
    this.address,
    this.port, {
    this.dataBits = 8,
    this.parity = 'none',
    this.stopBits = 1,
    this.flowControl = 'none',
  }) : kind = _ConnectionKind.serial,
       username = '',
       password = null,
       rememberCredentials = false,
       webSocketUrl = '',
       portKnockActions = const [],
       authenticationMode = SshAuthenticationMode.automatic,
       privateKeyPem = null,
       privateKeyPassphrase = null,
       sessionTitle = null,
       identityFile = null,
       sshConfigAlias = null,
       jumpHost = null,
       sshProxy = null,
       proxyPassword = null,
       rememberProxyCredentials = false;

  const _TerminalConnection.telnet(this.address, this.port)
    : kind = _ConnectionKind.telnet,
      dataBits = 8,
      parity = 'none',
      stopBits = 1,
      flowControl = 'none',
      username = '',
      password = null,
      rememberCredentials = false,
      webSocketUrl = '',
      portKnockActions = const [],
      authenticationMode = SshAuthenticationMode.automatic,
      privateKeyPem = null,
      privateKeyPassphrase = null,
      sessionTitle = null,
      identityFile = null,
      sshConfigAlias = null,
      jumpHost = null,
      sshProxy = null,
      proxyPassword = null,
      rememberProxyCredentials = false;

  const _TerminalConnection.ssh(
    this.address,
    this.port, {
    this.username = '',
    this.password,
    this.rememberCredentials = false,
    this.webSocketUrl = '',
    this.portKnockActions = const [],
    this.authenticationMode = SshAuthenticationMode.automatic,
    this.privateKeyPem,
    this.privateKeyPassphrase,
    this.sessionTitle,
    this.identityFile,
    this.sshConfigAlias,
    this.jumpHost,
    this.sshProxy,
    this.proxyPassword,
    this.rememberProxyCredentials = false,
  }) : kind = _ConnectionKind.ssh,
       dataBits = 8,
       parity = 'none',
       stopBits = 1,
       flowControl = 'none';

  const _TerminalConnection.sftp(
    this.address,
    this.port, {
    this.username = '',
    this.password,
    this.rememberCredentials = false,
    this.webSocketUrl = '',
    this.portKnockActions = const [],
    this.authenticationMode = SshAuthenticationMode.automatic,
    this.privateKeyPem,
    this.privateKeyPassphrase,
    this.sessionTitle,
    this.identityFile,
    this.sshConfigAlias,
    this.jumpHost,
    this.sshProxy,
    this.proxyPassword,
    this.rememberProxyCredentials = false,
  }) : kind = _ConnectionKind.sftp,
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
  final String username;
  final String? password;
  final bool rememberCredentials;
  final String webSocketUrl;
  final List<PortKnockAction> portKnockActions;
  final SshAuthenticationMode authenticationMode;
  final String? privateKeyPem;
  final String? privateKeyPassphrase;
  final String? sessionTitle;
  final String? identityFile;
  final String? sshConfigAlias;
  final SshJumpHost? jumpHost;
  final SshProxyConfig? sshProxy;
  final String? proxyPassword;
  final bool rememberProxyCredentials;

  String get routeLabel => jumpHost != null
      ? ' · 经 ${jumpHost!.name}'
      : sshProxy == null
      ? ''
      : ' · 经 ${sshProxy!.type == SshProxyType.socks5 ? 'SOCKS5' : 'HTTP'} 代理';

  String get displayName => switch (kind) {
    _ConnectionKind.local => '本地终端',
    _ConnectionKind.serial => '串口 $address',
    _ConnectionKind.telnet => 'Telnet $address:$port',
    _ConnectionKind.ssh => 'SSH $address:$port$routeLabel',
    _ConnectionKind.sftp => 'SFTP $address:$port$routeLabel',
  };

  String get openingStatus => switch (kind) {
    _ConnectionKind.local => '正在启动本地 shell',
    _ConnectionKind.serial => '正在打开串口 $address',
    _ConnectionKind.telnet => '正在连接 Telnet $address:$port',
    _ConnectionKind.ssh =>
      jumpHost == null
          ? '正在连接 SSH $address:$port$routeLabel'
          : '正在经 ${jumpHost!.name} 连接 SSH $address:$port',
    _ConnectionKind.sftp =>
      jumpHost == null
          ? '正在连接 SFTP $address:$port$routeLabel'
          : '正在经 ${jumpHost!.name} 连接 SFTP $address:$port',
  };

  String get connectedStatus => switch (kind) {
    _ConnectionKind.local => '本地终端已连接',
    _ConnectionKind.serial => '串口已连接 · $address',
    _ConnectionKind.telnet => 'Telnet 已连接 · $address:$port',
    _ConnectionKind.ssh => 'SSH 已连接 · $address:$port$routeLabel',
    _ConnectionKind.sftp => 'SFTP 已连接 · $address:$port$routeLabel',
  };

  SessionProtocol? get sessionProtocol => switch (kind) {
    _ConnectionKind.local => null,
    _ConnectionKind.serial => SessionProtocol.serial,
    _ConnectionKind.telnet => SessionProtocol.telnet,
    _ConnectionKind.ssh => SessionProtocol.ssh,
    _ConnectionKind.sftp => SessionProtocol.sftp,
  };

  String get credentialKey =>
      'ssh:${address.trim().toLowerCase()}:$port${sshConfigAlias == null ? '' : ':config:${sshConfigAlias!.toLowerCase()}'}';

  String get hostKeyEndpoint =>
      'ssh-host:${address.trim().toLowerCase()}:$port';

  String get endpointKey => switch (kind) {
    _ConnectionKind.serial =>
      '${kind.name}:${address.trim().toLowerCase()}:$port:$dataBits:$parity:$stopBits:$flowControl',
    _ConnectionKind.telnet =>
      '${kind.name}:${address.trim().toLowerCase()}:$port',
    _ConnectionKind.ssh || _ConnectionKind.sftp =>
      '${kind.name}:${address.trim().toLowerCase()}:$port:$webSocketUrl:${sshConfigAlias?.toLowerCase() ?? ''}:jump:${jumpHost?.endpointKey ?? ''}${sshProxy == null ? '' : ':proxy:${sshProxy!.credentialKey}'}',
    _ConnectionKind.local => kind.name,
  };

  String get remoteFileEndpointKey =>
      '${_ConnectionKind.ssh.name}:${address.trim().toLowerCase()}:$port:$webSocketUrl:${sshConfigAlias?.toLowerCase() ?? ''}:jump:${jumpHost?.endpointKey ?? ''}${sshProxy == null ? '' : ':proxy:${sshProxy!.credentialKey}'}';
}

class _ConnectionDialogResult {
  const _ConnectionDialogResult({required this.connection, this.saveAsName});

  final _TerminalConnection connection;
  final String? saveAsName;
}

class _ConnectionDialog extends StatefulWidget {
  const _ConnectionDialog({
    required this.initialProtocol,
    required this.mode,
    required this.savedSshSessions,
  });

  final _ConnectionKind initialProtocol;
  final _ConnectionDialogMode mode;
  final List<SessionRecord> savedSshSessions;

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
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _privateKeyController = TextEditingController();
  final _privateKeyPassphraseController = TextEditingController();
  final _webSocketUrlController = TextEditingController();
  final _proxyHostController = TextEditingController();
  final _proxyPortController = TextEditingController(text: '1080');
  final _proxyUsernameController = TextEditingController();
  final _proxyPasswordController = TextEditingController();
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
  bool _rememberCredentials = false;
  List<PortKnockAction> _portKnockActions = const [];
  SshAuthenticationMode _authenticationMode = SshAuthenticationMode.automatic;
  String? _jumpHostSessionId;
  SshProxyType _proxyType = SshProxyType.socks5;
  bool _useSshProxy = false;
  bool _rememberProxyCredentials = false;
  String? _proxyValidationError;

  @override
  void initState() {
    super.initState();
    _selectedProtocol = widget.initialProtocol;
    _portController.text = _selectedProtocol.usesSshTransport ? '22' : '23';
    _portsFuture = _selectedProtocol == _ConnectionKind.serial && !kIsWeb
        ? listSerialPorts()
        : Future.value(const <SerialPortEntry>[]);
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _privateKeyController.dispose();
    _privateKeyPassphraseController.dispose();
    _webSocketUrlController.dispose();
    _proxyHostController.dispose();
    _proxyPortController.dispose();
    _proxyUsernameController.dispose();
    _proxyPasswordController.dispose();
    _deviceController.dispose();
    _baudController.dispose();
    _profileNameController.dispose();
    super.dispose();
  }

  void _connect() {
    if (!_formKey.currentState!.validate()) return;
    SshProxyConfig? sshProxy;
    final proxyPassword = _proxyPasswordController.text;
    if (_useSshProxy) {
      final parsedProxyPort = int.tryParse(_proxyPortController.text.trim());
      final candidate = SshProxyConfig(
        type: _proxyType,
        address: _proxyHostController.text.trim(),
        port: parsedProxyPort ?? 0,
        username: _proxyUsernameController.text.trim(),
      );
      final validationError = candidate.validate();
      if (validationError != null) {
        setState(() => _proxyValidationError = validationError);
        return;
      }
      if (_jumpHostSessionId != null) {
        setState(() => _proxyValidationError = 'SSH 跳板机和代理不能同时配置');
        return;
      }
      if (_portKnockActions.isNotEmpty) {
        setState(() => _proxyValidationError = 'SSH 代理不能与端口敲门同时使用');
        return;
      }
      if (_webSocketUrlController.text.trim().isNotEmpty) {
        setState(() => _proxyValidationError = 'SSH 代理不能与 WebSocket 网关同时配置');
        return;
      }
      if (candidate.username.isEmpty != proxyPassword.isEmpty) {
        setState(() => _proxyValidationError = '代理用户名和密码需要同时填写');
        return;
      }
      _proxyValidationError = null;
      sshProxy = candidate;
    }
    SshJumpHost? jumpHost;
    if (_jumpHostSessionId != null) {
      for (final record in widget.savedSshSessions) {
        if (record.id == _jumpHostSessionId) {
          jumpHost = SshJumpHost.fromSession(record);
          break;
        }
      }
      if (jumpHost == null) return;
    }
    final enteredName = _profileNameController.text.trim();
    final sessionTitle = widget.mode == _ConnectionDialogMode.addSession
        ? (enteredName.isEmpty ? _hostController.text.trim() : enteredName)
        : null;
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
      _ConnectionKind.ssh => _TerminalConnection.ssh(
        _hostController.text.trim(),
        int.parse(_portController.text.trim()),
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        privateKeyPem: _privateKeyController.text.trim().isEmpty
            ? null
            : _privateKeyController.text,
        privateKeyPassphrase: _privateKeyPassphraseController.text,
        rememberCredentials: _rememberCredentials,
        webSocketUrl: _webSocketUrlController.text.trim(),
        portKnockActions: _portKnockActions,
        authenticationMode: _authenticationMode,
        sessionTitle: sessionTitle,
        jumpHost: jumpHost,
        sshProxy: sshProxy,
        proxyPassword: sshProxy == null || proxyPassword.isEmpty
            ? null
            : proxyPassword,
        rememberProxyCredentials: _rememberProxyCredentials,
      ),
      _ConnectionKind.sftp => _TerminalConnection.sftp(
        _hostController.text.trim(),
        int.parse(_portController.text.trim()),
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        privateKeyPem: _privateKeyController.text.trim().isEmpty
            ? null
            : _privateKeyController.text,
        privateKeyPassphrase: _privateKeyPassphraseController.text,
        rememberCredentials: _rememberCredentials,
        webSocketUrl: _webSocketUrlController.text.trim(),
        portKnockActions: _portKnockActions,
        authenticationMode: _authenticationMode,
        sessionTitle: sessionTitle,
        jumpHost: jumpHost,
        sshProxy: sshProxy,
        proxyPassword: sshProxy == null || proxyPassword.isEmpty
            ? null
            : proxyPassword,
        rememberProxyCredentials: _rememberProxyCredentials,
      ),
      _ConnectionKind.local => const _TerminalConnection.local(),
    };
    Navigator.of(context).pop(
      _ConnectionDialogResult(
        connection: connection,
        saveAsName: widget.mode == _ConnectionDialogMode.addSession
            ? (enteredName.isEmpty ? connection.address : enteredName)
            : null,
      ),
    );
  }

  Future<void> _configurePortKnock() async {
    final actions = await showDialog<List<PortKnockAction>>(
      context: context,
      builder: (_) => _PortKnockDialog(initialActions: _portKnockActions),
    );
    if (!mounted || actions == null) return;
    setState(() => _portKnockActions = actions);
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
      child: Material(
        color: Colors.transparent,
        child: ListTile(
          selected: selected,
          selectedTileColor: colors.primaryContainer.withValues(alpha: 0.65),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
          leading: Icon(icon, color: selected ? colors.primary : null),
          title: Text(title),
          subtitle: Text(subtitle),
          onTap: () {
            setState(() {
              if (protocol.usesSshTransport && _portController.text == '23') {
                _portController.text = '22';
              } else if (protocol == _ConnectionKind.telnet &&
                  _portController.text == '22') {
                _portController.text = '23';
              }
              _selectedProtocol = protocol;
              if (protocol == _ConnectionKind.serial) {
                _portsFuture = kIsWeb
                    ? Future.value(const <SerialPortEntry>[])
                    : listSerialPorts();
              }
            });
          },
        ),
      ),
    );
  }

  Widget _buildSshFields() {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: _hostController,
          autofocus: _selectedProtocol.usesSshTransport,
          decoration: InputDecoration(
            labelText: _selectedProtocol == _ConnectionKind.sftp
                ? 'SFTP 服务器（SSH 主机）'
                : 'SSH 主机名或 IP 地址',
            hintText: '192.168.1.10',
            prefixIcon: Icon(Icons.dns_rounded),
          ),
          validator: (value) => value == null || value.trim().isEmpty
              ? '请输入 SSH 主机名或 IP 地址'
              : null,
          onFieldSubmitted: (_) => _connect(),
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 220,
              child: TextFormField(
                controller: _portController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: _selectedProtocol == _ConnectionKind.sftp
                      ? 'SSH/SFTP 端口'
                      : 'SSH 端口',
                  hintText: '22',
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
            const SizedBox(width: 12),
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: TextButton.icon(
                onPressed: _configurePortKnock,
                icon: Icon(
                  _portKnockActions.isEmpty
                      ? Icons.playlist_add_rounded
                      : Icons.playlist_add_check_rounded,
                  size: 18,
                ),
                label: Text(_portKnockActions.isEmpty ? '配置端口敲门' : '已配置端口敲门'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String?>(
          initialValue: _jumpHostSessionId,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'SSH 跳板机',
            prefixIcon: Icon(Icons.route_outlined),
          ),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('直连目标主机')),
            for (final record in widget.savedSshSessions)
              DropdownMenuItem<String?>(
                value: record.id,
                child: Text(
                  '${record.name} · ${record.address}:${record.port}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          validator: (value) {
            if (value == null) return null;
            if (!canRunPortKnockActionsViaSshJump(_portKnockActions)) {
              return '经跳板仅支持 TCP 敲门和延迟，请移除 UDP/ICMP 操作';
            }
            for (final record in widget.savedSshSessions) {
              if (record.id != value) continue;
              if (record.address.trim().toLowerCase() ==
                      _hostController.text.trim().toLowerCase() &&
                  record.port ==
                      (int.tryParse(_portController.text.trim()) ?? -1)) {
                return '跳板机和目标主机不能相同';
              }
              return null;
            }
            return '所选跳板机会话已不存在';
          },
          onChanged: (value) => setState(() {
            _jumpHostSessionId = value;
            if (value != null) _useSshProxy = false;
            _proxyValidationError = null;
          }),
        ),
        const SizedBox(height: 6),
        Text(
          widget.savedSshSessions.isEmpty
              ? '先保存一个 SSH 会话，再将其选作跳板机。'
              : '仅支持一层跳转；跳板机凭据使用对应会话的安全凭据记录。',
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
        _buildSshProxyFields(colors),
        if (_jumpHostSessionId != null && _portKnockActions.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            canRunPortKnockActionsViaSshJump(_portKnockActions)
                ? 'TCP 敲门会通过 SSH 跳板发送，延迟操作仍按顺序执行。'
                : '经跳板仅支持 TCP 敲门和延迟；请移除 UDP/ICMP 操作。',
            style: TextStyle(
              color: canRunPortKnockActionsViaSshJump(_portKnockActions)
                  ? colors.onSurfaceVariant
                  : colors.error,
            ),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Icon(Icons.tune_rounded, size: 18, color: colors.onSurfaceVariant),
            const SizedBox(width: 8),
            Text('认证模式', style: Theme.of(context).textTheme.labelLarge),
          ],
        ),
        const SizedBox(height: 8),
        SegmentedButton<SshAuthenticationMode>(
          segments: [
            for (final mode in SshAuthenticationMode.values)
              ButtonSegment(
                value: mode,
                label: Text(_authenticationModeLabel(mode)),
              ),
          ],
          selected: {_authenticationMode},
          showSelectedIcon: false,
          onSelectionChanged: (selection) {
            if (selection.isNotEmpty) {
              setState(() => _authenticationMode = selection.first);
            }
          },
        ),
        const SizedBox(height: 6),
        Text(
          '自动模式会先试可用的私钥；优先模式失败后会回退到另一种可用认证。',
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _usernameController,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.username],
          decoration: const InputDecoration(
            labelText: '用户名',
            prefixIcon: Icon(Icons.person_outline_rounded),
          ),
          onFieldSubmitted: (_) => _connect(),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _passwordController,
          obscureText: true,
          autofillHints: const [AutofillHints.password],
          decoration: const InputDecoration(
            labelText: '密码',
            prefixIcon: Icon(Icons.password_rounded),
          ),
          onFieldSubmitted: (_) => _connect(),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _privateKeyController,
          minLines: 4,
          maxLines: 7,
          keyboardType: TextInputType.multiline,
          decoration: InputDecoration(
            labelText: 'SSH 私钥',
            hintText: '粘贴 OpenSSH 私钥内容，或选择私钥文件',
            alignLabelWithHint: true,
            prefixIcon: const Icon(Icons.key_rounded),
            suffixIcon: IconButton(
              tooltip: '选择私钥文件',
              onPressed: () async {
                final pem = await _pickSshPrivateKey(context);
                if (pem != null && mounted) {
                  setState(() => _privateKeyController.text = pem);
                }
              },
              icon: const Icon(Icons.folder_open_rounded),
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _privateKeyPassphraseController,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: '私钥口令（如有）',
            prefixIcon: Icon(Icons.password_rounded),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '仅支持 OpenSSH、PKCS#1 RSA 和 SEC1 EC 私钥格式。勾选保存登录凭据时，私钥和口令也会一起保存。',
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
        if (kIsWeb) ...[
          const SizedBox(height: 16),
          TextFormField(
            controller: _webSocketUrlController,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'WebSocket SSH 网关',
              hintText: 'wss://gateway.example/ssh?host={host}&port={port}',
              prefixIcon: Icon(Icons.swap_horiz_rounded),
            ),
            validator: (value) => value == null || value.trim().isEmpty
                ? (_jumpHostSessionId == null
                      ? '浏览器连接需要配置 WebSocket SSH 网关'
                      : null)
                : null,
          ),
          const SizedBox(height: 8),
          Text(
            _jumpHostSessionId == null
                ? '网关须将二进制 WebSocket 数据帧双向转发到目标 SSH 主机。支持 {host}/{port} 占位符；否则应用会追加 host、port 查询参数。HTTPS 页面需要 wss://。URL 不要包含访问令牌或密码。'
                : '目标连接会通过所选跳板机建立，目标网关可留空；跳板机配置的 WebSocket 网关将用于连接跳板机。',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
          if (_portKnockActions.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Web 端口敲门由网关代发：TCP 使用默认连接方式，UDP 需识别 transport=udp，ICMP 需识别 transport=icmp；host 和适用时的 port 参数用于指定目标。',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ],
        ],
        const SizedBox(height: 8),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _rememberCredentials,
          onChanged: (value) =>
              setState(() => _rememberCredentials = value ?? false),
          title: const Text('保存登录凭据'),
          subtitle: Text(
            kIsWeb
                ? '密码、私钥和口令使用浏览器加密存储'
                : defaultTargetPlatform == TargetPlatform.android
                ? '密码、私钥和口令使用 Android 系统密钥库加密存储'
                : '密码、私钥和口令保存到当前用户的凭据文件；勾选后才保存',
          ),
          controlAffinity: ListTileControlAffinity.leading,
        ),
        Text(
          '首次连接会显示服务器主机密钥指纹，核对后再信任。',
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _buildSshProxyFields(ColorScheme colors) {
    if (kIsWeb) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded, color: colors.primary, size: 19),
            const SizedBox(width: 9),
            const Expanded(child: Text('浏览器连接使用 WebSocket SSH 网关；代理路由在网关侧配置。')),
          ],
        ),
      );
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: const Icon(Icons.route_rounded),
        title: const Text('SSH 代理'),
        subtitle: Text(
          _useSshProxy
              ? '${_proxyType == SshProxyType.socks5 ? 'SOCKS5' : 'HTTP CONNECT'} · ${_proxyHostController.text.isEmpty ? '未配置主机' : _proxyHostController.text}'
              : '可选，直连默认关闭',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _useSshProxy,
            onChanged: _jumpHostSessionId == null
                ? (value) => setState(() {
                    _useSshProxy = value;
                    _proxyValidationError = null;
                  })
                : null,
            title: const Text('通过代理连接 SSH 主机'),
            subtitle: Text(
              _jumpHostSessionId == null
                  ? '支持 SOCKS5 和 HTTP CONNECT；代理密码不会写入会话备份。'
                  : '当前已选择 SSH 跳板机；代理与跳板机不能同时使用。',
            ),
          ),
          if (_useSshProxy) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<SshProxyType>(
                    initialValue: _proxyType,
                    decoration: const InputDecoration(labelText: '代理类型'),
                    items: const [
                      DropdownMenuItem(
                        value: SshProxyType.socks5,
                        child: Text('SOCKS5'),
                      ),
                      DropdownMenuItem(
                        value: SshProxyType.httpConnect,
                        child: Text('HTTP CONNECT'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        _proxyType = value;
                        _proxyValidationError = null;
                      });
                    },
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 150,
                  child: TextField(
                    controller: _proxyPortController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '代理端口',
                      hintText: '1080',
                    ),
                    onChanged: (_) =>
                        setState(() => _proxyValidationError = null),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _proxyHostController,
              decoration: const InputDecoration(
                labelText: '代理主机',
                hintText: '127.0.0.1',
                prefixIcon: Icon(Icons.dns_rounded),
              ),
              onChanged: (_) => setState(() => _proxyValidationError = null),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _proxyUsernameController,
                    decoration: const InputDecoration(
                      labelText: '代理用户名（可选）',
                      prefixIcon: Icon(Icons.person_outline_rounded),
                    ),
                    onChanged: (_) =>
                        setState(() => _proxyValidationError = null),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _proxyPasswordController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '代理密码（可选）',
                      prefixIcon: Icon(Icons.password_rounded),
                    ),
                    onChanged: (_) =>
                        setState(() => _proxyValidationError = null),
                  ),
                ),
              ],
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _rememberProxyCredentials,
              onChanged: (value) =>
                  setState(() => _rememberProxyCredentials = value ?? false),
              title: const Text('保存代理凭据'),
              subtitle: Text(
                defaultTargetPlatform == TargetPlatform.android
                    ? '代理密码使用 Android 系统密钥库'
                    : '代理密码保存在当前用户凭据存储中',
              ),
            ),
            if (_proxyType == SshProxyType.httpConnect &&
                _proxyUsernameController.text.isNotEmpty)
              Text(
                'HTTP CONNECT 使用 Basic 认证；代理凭据会通过明文代理连接发送，请只连接可信代理。',
                style: TextStyle(color: colors.error, fontSize: 12),
              ),
            if (_proxyValidationError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _proxyValidationError!,
                    style: TextStyle(color: colors.error),
                  ),
                ),
              ),
          ],
        ],
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
                          if (!kIsWeb)
                            _buildProtocolItem(
                              protocol: _ConnectionKind.telnet,
                              icon: Icons.lan_rounded,
                              title: 'Telnet',
                              subtitle: '主机和 TCP 端口',
                            ),
                          _buildProtocolItem(
                            protocol: _ConnectionKind.ssh,
                            icon: Icons.lock_open_rounded,
                            title: 'SSH',
                            subtitle: '加密远程终端',
                          ),
                          _buildProtocolItem(
                            protocol: _ConnectionKind.sftp,
                            icon: Icons.folder_open_rounded,
                            title: 'SFTP',
                            subtitle: '仅文件浏览和传输，不启动 Shell',
                          ),
                          if (!kIsWeb)
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
                              Text(switch (_selectedProtocol) {
                                _ConnectionKind.serial => '串口连接',
                                _ConnectionKind.telnet => 'Telnet 连接',
                                _ConnectionKind.ssh => 'SSH 连接',
                                _ConnectionKind.sftp => 'SFTP 文件会话',
                                _ConnectionKind.local => '本地终端',
                              }, style: Theme.of(context).textTheme.titleLarge),
                              const SizedBox(height: 20),
                              if (_selectedProtocol == _ConnectionKind.serial)
                                _buildSerialFields()
                              else if (_selectedProtocol ==
                                  _ConnectionKind.telnet)
                                _buildTelnetFields(),
                              if (_selectedProtocol.usesSshTransport)
                                _buildSshFields(),
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

class _PortKnockDialog extends StatefulWidget {
  const _PortKnockDialog({required this.initialActions});

  final List<PortKnockAction> initialActions;

  @override
  State<_PortKnockDialog> createState() => _PortKnockDialogState();
}

class _PortKnockDialogState extends State<_PortKnockDialog> {
  final _formKey = GlobalKey<FormState>();
  late final List<_PortKnockDraft> _actions;

  @override
  void initState() {
    super.initState();
    _actions = widget.initialActions.map(_PortKnockDraft.fromAction).toList();
  }

  void _addKnock() {
    setState(() => _actions.add(_PortKnockDraft.knock()));
  }

  void _addDelay() {
    setState(() => _actions.add(_PortKnockDraft.delay()));
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      final action = _actions.removeAt(oldIndex);
      _actions.insert(newIndex, action);
    });
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final actions = _actions.map((draft) => draft.toAction()).toList();
    Navigator.of(context).pop(actions);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 580,
          maxHeight: MediaQuery.sizeOf(context).height * 0.86,
        ),
        child: SizedBox(
          width: 580,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
                child: Row(
                  children: [
                    Icon(
                      Icons.playlist_add_check_rounded,
                      color: colors.primary,
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        '配置端口敲门',
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
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '操作按列表顺序执行。TCP 会连接一次后关闭，UDP 会发送一个空数据报，ICMP 会发送一次 Echo Request。',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Form(
                  key: _formKey,
                  child: _actions.isEmpty
                      ? Center(
                          child: Text(
                            '还没有操作，请添加敲门或延迟。',
                            style: TextStyle(color: colors.onSurfaceVariant),
                          ),
                        )
                      : ReorderableListView.builder(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          buildDefaultDragHandles: false,
                          itemCount: _actions.length,
                          onReorderItem: _reorder,
                          itemBuilder: (context, index) {
                            final action = _actions[index];
                            final isKnock =
                                action.kind == PortKnockActionKind.knock;
                            return Card(
                              key: ValueKey(action.key),
                              margin: const EdgeInsets.symmetric(vertical: 5),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Row(
                                      children: [
                                        ReorderableDragStartListener(
                                          index: index,
                                          child: const Padding(
                                            padding: EdgeInsets.all(8),
                                            child: Icon(
                                              Icons.drag_indicator_rounded,
                                            ),
                                          ),
                                        ),
                                        Icon(
                                          isKnock
                                              ? Icons.lan_rounded
                                              : Icons.timer_outlined,
                                          size: 19,
                                          color: colors.primary,
                                        ),
                                        const SizedBox(width: 9),
                                        Expanded(
                                          child: Text(
                                            '${index + 1}. ${isKnock ? '敲门' : '延迟'}',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: '删除操作',
                                          onPressed: () => setState(
                                            () => _actions.removeAt(index),
                                          ),
                                          icon: const Icon(
                                            Icons.delete_outline_rounded,
                                          ),
                                        ),
                                      ],
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        left: 48,
                                        right: 8,
                                      ),
                                      child: isKnock
                                          ? Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Expanded(
                                                  flex: 2,
                                                  child:
                                                      DropdownButtonFormField<
                                                        PortKnockProtocol
                                                      >(
                                                        initialValue:
                                                            action.protocol,
                                                        decoration:
                                                            const InputDecoration(
                                                              isDense: true,
                                                              labelText: '敲门协议',
                                                            ),
                                                        items: const [
                                                          DropdownMenuItem(
                                                            value:
                                                                PortKnockProtocol
                                                                    .tcp,
                                                            child: Text('TCP'),
                                                          ),
                                                          DropdownMenuItem(
                                                            value:
                                                                PortKnockProtocol
                                                                    .udp,
                                                            child: Text('UDP'),
                                                          ),
                                                          DropdownMenuItem(
                                                            value:
                                                                PortKnockProtocol
                                                                    .icmp,
                                                            child: Text('ICMP'),
                                                          ),
                                                        ],
                                                        onChanged: (value) {
                                                          if (value == null) {
                                                            return;
                                                          }
                                                          setState(() {
                                                            action.protocol =
                                                                value;
                                                          });
                                                        },
                                                      ),
                                                ),
                                                if (action.protocol !=
                                                    PortKnockProtocol.icmp) ...[
                                                  const SizedBox(width: 10),
                                                  Expanded(
                                                    flex: 3,
                                                    child: _portKnockValueField(
                                                      action,
                                                      isKnock: true,
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            )
                                          : _portKnockValueField(
                                              action,
                                              isKnock: false,
                                            ),
                                    ),
                                    if (isKnock &&
                                        action.protocol ==
                                            PortKnockProtocol.icmp)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          left: 48,
                                          right: 8,
                                          top: 4,
                                        ),
                                        child: Text(
                                          '向目标主机发送一次 ICMP Echo Request。',
                                          style: TextStyle(
                                            color: colors.onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _addKnock,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('添加敲门'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _addDelay,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('添加延迟'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                    FilledButton(onPressed: _save, child: const Text('完成')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _portKnockValueField(
    _PortKnockDraft action, {
    required bool isKnock,
  }) => TextFormField(
    key: ValueKey('${action.key}-field'),
    initialValue: action.value,
    keyboardType: TextInputType.number,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    decoration: InputDecoration(
      isDense: true,
      labelText: isKnock ? '敲门端口' : '延迟毫秒数',
      suffixText: isKnock ? null : 'ms',
    ),
    validator: (value) {
      final number = int.tryParse(value?.trim() ?? '');
      if (number == null) {
        return isKnock ? '请输入敲门端口' : '请输入延迟毫秒数';
      }
      if (isKnock && (number < 1 || number > 65535)) {
        return '端口范围为 1 到 65535';
      }
      if (!isKnock && number < 0) return '延迟不能小于 0';
      return null;
    },
    onChanged: (value) => action.value = value,
  );
}

class _PortKnockDraft {
  _PortKnockDraft.knock()
    : kind = PortKnockActionKind.knock,
      value = '',
      protocol = PortKnockProtocol.tcp;

  _PortKnockDraft.delay()
    : kind = PortKnockActionKind.delay,
      value = '1000',
      protocol = PortKnockProtocol.tcp;

  _PortKnockDraft.fromAction(PortKnockAction action)
    : kind = action.kind,
      protocol = action.protocol,
      value = switch (action.kind) {
        PortKnockActionKind.knock => '${action.port}',
        PortKnockActionKind.delay => '${action.delayMs}',
      };

  final Object key = Object();
  final PortKnockActionKind kind;
  PortKnockProtocol protocol;
  String value;

  PortKnockAction toAction() => switch (kind) {
    PortKnockActionKind.knock => PortKnockAction.knock(
      protocol == PortKnockProtocol.icmp ? 0 : int.parse(value),
      protocol: protocol,
    ),
    PortKnockActionKind.delay => PortKnockAction.delay(int.parse(value)),
  };
}

class _SshProxyPasswordResult {
  const _SshProxyPasswordResult({
    required this.password,
    required this.rememberCredentials,
  });

  final String password;
  final bool rememberCredentials;
}

class _SshProxyPasswordDialog extends StatefulWidget {
  const _SshProxyPasswordDialog({
    required this.proxy,
    required this.sessionTitle,
  });

  final SshProxyConfig proxy;
  final String sessionTitle;

  @override
  State<_SshProxyPasswordDialog> createState() =>
      _SshProxyPasswordDialogState();
}

class _SshProxyPasswordDialogState extends State<_SshProxyPasswordDialog> {
  final TextEditingController _passwordController = TextEditingController();
  bool _rememberCredentials = false;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_passwordController.text.isEmpty) {
      setState(() => _error = '请输入代理密码');
      return;
    }
    Navigator.pop(
      context,
      _SshProxyPasswordResult(
        password: _passwordController.text,
        rememberCredentials: _rememberCredentials,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('SSH 代理认证'),
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${widget.sessionTitle} · ${widget.proxy.address}:${widget.proxy.port}',
          ),
          if (widget.proxy.type == SshProxyType.httpConnect &&
              widget.proxy.username.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'HTTP CONNECT 使用 Basic 认证；代理密码会通过明文代理连接发送。',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _passwordController,
            autofocus: true,
            obscureText: true,
            decoration: InputDecoration(
              labelText: '代理密码',
              prefixIcon: const Icon(Icons.password_rounded),
              errorText: _error,
            ),
            onSubmitted: (_) => _submit(),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _rememberCredentials,
            onChanged: (value) =>
                setState(() => _rememberCredentials = value ?? false),
            title: const Text('保存代理密码'),
            subtitle: Text(
              defaultTargetPlatform == TargetPlatform.android
                  ? '保存到 Android 系统密钥库'
                  : '保存到当前用户凭据存储',
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('连接')),
    ],
  );
}

class _SshCredentialPromptResult {
  const _SshCredentialPromptResult({
    required this.username,
    required this.password,
    required this.privateKeyPem,
    required this.privateKeyPassphrase,
    required this.rememberCredentials,
  });

  final String username;
  final String password;
  final String privateKeyPem;
  final String privateKeyPassphrase;
  final bool rememberCredentials;
}

class _SshCredentialPrompt extends StatefulWidget {
  const _SshCredentialPrompt({
    required this.initialUsername,
    required this.initialPassword,
    required this.initialPrivateKeyPem,
    required this.initialPrivateKeyPassphrase,
    required this.rememberByDefault,
  });

  final String initialUsername;
  final String initialPassword;
  final String initialPrivateKeyPem;
  final String initialPrivateKeyPassphrase;
  final bool rememberByDefault;

  @override
  State<_SshCredentialPrompt> createState() => _SshCredentialPromptState();
}

class _SshCredentialPromptState extends State<_SshCredentialPrompt> {
  late final TextEditingController _usernameController;
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _privateKeyController = TextEditingController();
  final TextEditingController _privateKeyPassphraseController =
      TextEditingController();
  late bool _rememberCredentials;
  String? _error;

  @override
  void initState() {
    super.initState();
    _usernameController = TextEditingController(text: widget.initialUsername);
    _passwordController.text = widget.initialPassword;
    _privateKeyController.text = widget.initialPrivateKeyPem;
    _privateKeyPassphraseController.text = widget.initialPrivateKeyPassphrase;
    _rememberCredentials = widget.rememberByDefault;
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _privateKeyController.dispose();
    _privateKeyPassphraseController.dispose();
    super.dispose();
  }

  void _connect() {
    final username = _usernameController.text.trim();
    if (username.isEmpty) {
      setState(() => _error = '请输入用户名');
      return;
    }
    Navigator.of(context).pop(
      _SshCredentialPromptResult(
        username: username,
        password: _passwordController.text,
        privateKeyPem: _privateKeyController.text,
        privateKeyPassphrase: _privateKeyPassphraseController.text,
        rememberCredentials: _rememberCredentials,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('SSH 登录凭据'),
      content: SizedBox(
        width: 440,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.7,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _usernameController,
                  autofocus: true,
                  autofillHints: const [AutofillHints.username],
                  decoration: const InputDecoration(
                    labelText: '用户名',
                    prefixIcon: Icon(Icons.person_outline_rounded),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  decoration: const InputDecoration(
                    labelText: '密码（可选）',
                    prefixIcon: Icon(Icons.password_rounded),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _privateKeyController,
                  minLines: 4,
                  maxLines: 6,
                  decoration: InputDecoration(
                    labelText: 'SSH 私钥（可选）',
                    hintText: '粘贴 OpenSSH 私钥或选择文件',
                    alignLabelWithHint: true,
                    prefixIcon: const Icon(Icons.key_rounded),
                    suffixIcon: IconButton(
                      tooltip: '选择私钥文件',
                      onPressed: () async {
                        final pem = await _pickSshPrivateKey(context);
                        if (pem != null && mounted) {
                          setState(() => _privateKeyController.text = pem);
                        }
                      },
                      icon: const Icon(Icons.folder_open_rounded),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _privateKeyPassphraseController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '私钥口令（如有）',
                    prefixIcon: Icon(Icons.password_rounded),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: TextStyle(color: colors.error)),
                ],
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _rememberCredentials,
                  onChanged: (value) =>
                      setState(() => _rememberCredentials = value ?? false),
                  title: const Text('保存登录凭据'),
                  subtitle: const Text('包含密码、私钥和私钥口令'),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _connect,
          icon: const Icon(Icons.lock_open_rounded),
          label: const Text('登录'),
        ),
      ],
    );
  }
}

class _SshUserInfoDialog extends StatefulWidget {
  const _SshUserInfoDialog({required this.request, required this.sessionTitle});

  final SSHUserInfoRequest request;
  final String sessionTitle;

  @override
  State<_SshUserInfoDialog> createState() => _SshUserInfoDialogState();
}

class _SshUserInfoDialogState extends State<_SshUserInfoDialog> {
  late final List<TextEditingController> _controllers;

  @override
  void initState() {
    super.initState();
    _controllers = List.generate(
      widget.request.prompts.length,
      (_) => TextEditingController(),
    );
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  void _continue() => Navigator.of(
    context,
  ).pop(_controllers.map((controller) => controller.text).toList());

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.request.name.isEmpty ? 'SSH 交互式质询' : widget.request.name,
    ),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('会话：${widget.sessionTitle}'),
            const SizedBox(height: 10),
            if (widget.request.instruction.isNotEmpty) ...[
              Text(widget.request.instruction),
              const SizedBox(height: 12),
            ],
            for (
              var index = 0;
              index < widget.request.prompts.length;
              index++
            ) ...[
              if (index > 0) const SizedBox(height: 12),
              TextField(
                controller: _controllers[index],
                autofocus: index == 0,
                obscureText: !widget.request.prompts[index].echo,
                decoration: InputDecoration(
                  labelText: widget.request.prompts[index].promptText.trim(),
                ),
                onSubmitted: index == widget.request.prompts.length - 1
                    ? (_) => _continue()
                    : null,
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _continue, child: const Text('继续')),
    ],
  );
}

Future<String?> _pickSshPrivateKey(BuildContext context) async {
  try {
    final file = await FilePicker.pickFile(dialogTitle: '选择 SSH 私钥');
    if (file == null) return null;
    final length = await file.length();
    if (length != null && length > 1024 * 1024) {
      throw const FormatException('私钥文件不能大于 1 MiB');
    }
    final pem = utf8.decode(await file.readAsBytes());
    if (utf8.encode(pem).length > 1024 * 1024) {
      throw const FormatException('私钥文件不能大于 1 MiB');
    }
    if (!pem.contains('PRIVATE KEY')) {
      throw const FormatException('文件中未找到受支持的私钥内容');
    }
    return pem;
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('读取私钥失败：$error')));
    }
    return null;
  }
}

String _authenticationModeLabel(SshAuthenticationMode mode) => switch (mode) {
  SshAuthenticationMode.passwordFirst => '优先密码',
  SshAuthenticationMode.keyFirst => '优先密钥',
  SshAuthenticationMode.automatic => '自动',
};

class _SessionNameDialog extends StatefulWidget {
  const _SessionNameDialog({this.title = '保存会话', required this.initialName});

  final String title;
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
      title: Text(widget.title),
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

class _SessionGroupDialog extends StatefulWidget {
  const _SessionGroupDialog({required this.groups, required this.initialGroup});

  final List<String> groups;
  final String initialGroup;

  @override
  State<_SessionGroupDialog> createState() => _SessionGroupDialogState();
}

class _SessionGroupDialogState extends State<_SessionGroupDialog> {
  late String _selectedGroup = widget.initialGroup;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('移动会话到分类'),
    content: SizedBox(
      width: 360,
      child: RadioGroup<String>(
        groupValue: _selectedGroup,
        onChanged: (value) {
          if (value != null) setState(() => _selectedGroup = value);
        },
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final entry in [
              ('', '未分类'),
              ...widget.groups.map((group) => (group, group)),
            ])
              RadioListTile<String>(value: entry.$1, title: Text(entry.$2)),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _selectedGroup),
        child: const Text('移动'),
      ),
    ],
  );
}

class _SshTunnelManagerDialog extends StatefulWidget {
  const _SshTunnelManagerDialog({
    required this.client,
    required this.sessionTitle,
    required this.tunnels,
  });

  final SSHClient client;
  final String sessionTitle;
  final List<SshTunnelHandle> tunnels;

  @override
  State<_SshTunnelManagerDialog> createState() =>
      _SshTunnelManagerDialogState();
}

class _SshTunnelManagerDialogState extends State<_SshTunnelManagerDialog> {
  bool _working = false;

  Future<void> _addTunnel() async {
    final spec = await showDialog<SshTunnelSpec>(
      context: context,
      builder: (_) => const _SshTunnelCreateDialog(),
    );
    if (!mounted || spec == null) return;
    setState(() => _working = true);
    try {
      final tunnel = await startSshTunnel(widget.client, spec);
      if (!mounted) {
        await tunnel.close();
        return;
      }
      setState(() => widget.tunnels.add(tunnel));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已启动 ${_describeTunnel(tunnel)}')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('启动隧道失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _stopTunnel(SshTunnelHandle tunnel) async {
    try {
      await tunnel.close();
      if (mounted) {
        setState(() => widget.tunnels.remove(tunnel));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('关闭隧道失败：$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(22, 18, 16, 8),
      contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      title: Row(
        children: [
          const Icon(Icons.account_tree_outlined, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text('SSH 隧道 · ${widget.sessionTitle}')),
        ],
      ),
      content: SizedBox(
        width: 560,
        height: 390,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '支持本地转发、远程转发和 SOCKS5 动态转发。监听地址默认限制在 127.0.0.1。',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            if (_working) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: widget.tunnels.isEmpty
                  ? Center(
                      child: Text(
                        '当前 SSH 会话没有活动隧道',
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    )
                  : ListView.separated(
                      itemCount: widget.tunnels.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final tunnel = widget.tunnels[index];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            tunnel.spec.type == SshTunnelType.dynamic
                                ? Icons.public_rounded
                                : Icons.swap_horiz_rounded,
                            color: colors.primary,
                          ),
                          title: Text(_tunnelTypeLabel(tunnel.spec.type)),
                          subtitle: Text(
                            _describeTunnel(tunnel),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            tooltip: '停止隧道',
                            onPressed: _working
                                ? null
                                : () => unawaited(_stopTunnel(tunnel)),
                            icon: const Icon(Icons.stop_circle_outlined),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton.icon(
          onPressed: _working ? null : _addTunnel,
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('新建隧道'),
        ),
      ],
    );
  }
}

class _SshTunnelCreateDialog extends StatefulWidget {
  const _SshTunnelCreateDialog();

  @override
  State<_SshTunnelCreateDialog> createState() => _SshTunnelCreateDialogState();
}

class _SshTunnelCreateDialogState extends State<_SshTunnelCreateDialog> {
  final _formKey = GlobalKey<FormState>();
  final _bindHostController = TextEditingController(text: '127.0.0.1');
  final _bindPortController = TextEditingController(text: '8080');
  final _targetHostController = TextEditingController(text: '127.0.0.1');
  final _targetPortController = TextEditingController(text: '80');
  SshTunnelType _type = SshTunnelType.local;

  @override
  void dispose() {
    _bindHostController.dispose();
    _bindPortController.dispose();
    _targetHostController.dispose();
    _targetPortController.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      SshTunnelSpec(
        type: _type,
        bindHost: _bindHostController.text.trim(),
        bindPort: int.parse(_bindPortController.text.trim()),
        targetHost: _targetHostController.text.trim(),
        targetPort: _type == SshTunnelType.dynamic
            ? 0
            : int.parse(_targetPortController.text.trim()),
      ),
    );
  }

  String? _validatePort(String? value, {required bool allowZero}) {
    final port = int.tryParse(value?.trim() ?? '');
    if (port == null) return '请输入端口';
    if (port < (allowZero ? 0 : 1) || port > 65535) {
      return allowZero ? '范围为 0 到 65535' : '范围为 1 到 65535';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isRemote = _type == SshTunnelType.remote;
    final isDynamic = _type == SshTunnelType.dynamic;
    return AlertDialog(
      title: const Text('新建 SSH 隧道'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<SshTunnelType>(
                  initialValue: _type,
                  decoration: const InputDecoration(labelText: '转发类型'),
                  items: [
                    for (final type in SshTunnelType.values)
                      DropdownMenuItem(
                        value: type,
                        child: Text(_tunnelTypeLabel(type)),
                      ),
                  ],
                  onChanged: (type) {
                    if (type != null) setState(() => _type = type);
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _bindHostController,
                  decoration: InputDecoration(
                    labelText: isRemote ? 'SSH 服务器监听地址' : '本机监听地址',
                    helperText: '默认 127.0.0.1，只允许本机访问',
                  ),
                  validator: (value) =>
                      value == null || value.trim().isEmpty ? '请输入监听地址' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _bindPortController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: isRemote ? 'SSH 服务器监听端口' : '本机监听端口',
                    helperText: '输入 0 可由系统分配空闲端口',
                  ),
                  validator: (value) => _validatePort(value, allowZero: true),
                ),
                if (!isDynamic) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _targetHostController,
                    decoration: InputDecoration(
                      labelText: isRemote ? '本机可访问的目标地址' : 'SSH 服务器可访问的目标地址',
                    ),
                    validator: (value) => value == null || value.trim().isEmpty
                        ? '请输入目标地址'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _targetPortController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(labelText: '目标端口'),
                    validator: (value) =>
                        _validatePort(value, allowZero: false),
                  ),
                ],
                const SizedBox(height: 10),
                Text(
                  isDynamic
                      ? '建立本机 SOCKS5 代理；浏览器、SSH 客户端和其他应用可连接此端口。'
                      : isRemote
                      ? 'SSH 服务器上的连接会通过当前 SSH 会话转发到本机目标。'
                      : '本机监听端口会通过当前 SSH 会话连接远端目标。',
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _save,
          icon: const Icon(Icons.play_arrow_rounded, size: 18),
          label: const Text('启动隧道'),
        ),
      ],
    );
  }
}

String _tunnelTypeLabel(SshTunnelType type) => switch (type) {
  SshTunnelType.local => '本地转发（-L）',
  SshTunnelType.remote => '远程转发（-R）',
  SshTunnelType.dynamic => 'SOCKS5 动态转发（-D）',
};

String _describeTunnel(SshTunnelHandle tunnel) => switch (tunnel.spec.type) {
  SshTunnelType.local =>
    '${tunnel.boundHost}:${tunnel.boundPort} → ${tunnel.spec.targetHost}:${tunnel.spec.targetPort}',
  SshTunnelType.remote =>
    'SSH 服务器 ${tunnel.boundHost}:${tunnel.boundPort} → ${tunnel.spec.targetHost}:${tunnel.spec.targetPort}',
  SshTunnelType.dynamic => 'SOCKS5 ${tunnel.boundHost}:${tunnel.boundPort}',
};

class _TerminalMacroTarget {
  _TerminalMacroTarget.capture(this.tab)
    : displayName = '${tab.title} · 标签 ${tab.id}',
      sessionId = tab.sessionId,
      sshClient = tab.sshClient,
      sshSession = tab.sshSession;

  final _TerminalTab tab;
  final String displayName;
  final PlatformInt64? sessionId;
  final SSHClient? sshClient;
  final SSHSession? sshSession;
}

class _TerminalMacroRunFailure {
  const _TerminalMacroRunFailure(
    this.targetName,
    this.completedCommands,
    this.reason,
  );

  final String targetName;
  final int completedCommands;
  final String reason;

  @override
  String toString() =>
      '目标“$targetName”停止，已完成 $completedCommands 条命令：$reason。当前行可能已部分发送。';
}

class _TerminalRecordedMacroRunFailure {
  const _TerminalRecordedMacroRunFailure(
    this.targetName,
    this.completedEvents,
    this.reason,
  );

  final String targetName;
  final int completedEvents;
  final String reason;

  @override
  String toString() =>
      '目标“$targetName”停止，已发送 $completedEvents 个输入片段：$reason。最后一个输入片段可能已部分发送。';
}

class _TerminalTab {
  _TerminalTab({
    required this.id,
    required this.title,
    required this.connection,
  }) : terminalController = TerminalController(),
       focusNode = FocusNode(),
       scrollController = ScrollController();

  final int id;
  final String title;
  final _TerminalConnection connection;
  final TerminalController terminalController;
  final FocusNode focusNode;
  final GlobalKey terminalViewKey = GlobalKey();
  final ScrollController scrollController;
  final BytesBuilder pendingInput = BytesBuilder(copy: false);
  final TerminalTranscript transcript = TerminalTranscript();
  final TerminalAssistantAnalyzer assistant = TerminalAssistantAnalyzer();
  final TerminalInlineHintTransformer inlineHintTransformer =
      TerminalInlineHintTransformer();
  late final TerminalChartCoordinator chartCoordinator =
      TerminalChartCoordinator(
        terminal: terminal,
        scrollController: scrollController,
        terminalController: terminalController,
      );
  final TerminalInputRecorder inputRecorder = TerminalInputRecorder();
  late final TerminalKeywordHighlighter keywordHighlighter =
      TerminalKeywordHighlighter(terminalController);
  final SshRemoteMonitorCache remoteMonitorCache = SshRemoteMonitorCache();
  late final Terminal terminal;
  Uri? pendingExternalLink;

  Future<void> inputWriteQueue = Future<void>.value();
  StreamSubscription<String>? outputSubscription;
  Timer? inputFlushTimer;
  PlatformInt64? sessionId;
  SSHClient? sshClient;
  SSHClient? sshJumpClient;
  SSHSession? sshSession;
  String? remoteDirectory;
  int remoteRefreshToken = 0;
  RemoteTransferProtocol fileTransferProtocol = RemoteTransferProtocol.sftp;
  final List<SshTunnelHandle> tunnels = [];
  int columns = 100;
  int rows = 30;
  bool starting = false;
  bool restarting = false;
  bool isClosed = false;
  bool closing = false;
  bool localFileDragHover = false;
  String status = '正在连接';
  String? errorMessage;

  bool get isConnected => sessionId != null || sshSession != null;
}
