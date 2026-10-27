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
import 'package:geekcore_term/terminal/ssh_identity_file.dart';
import 'package:geekcore_term/terminal/session_store.dart';
import 'package:geekcore_term/terminal/websocket_ssh_socket.dart';
import 'package:geekcore_term/settings/app_settings.dart';
import 'package:geekcore_term/settings/settings_page.dart';
import 'package:geekcore_term/settings/window_state.dart';
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
  String _sessionSearch = '';
  _SidebarSection _sidebarSection = _SidebarSection.sessions;
  bool _clearingAppData = false;
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

  Future<void> _openSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => AppSettingsPage(
          settings: widget.settings,
          onClearAppData: _clearAppData,
        ),
      ),
    );
  }

  Future<void> _clearAppData() async {
    if (_clearingAppData) return;
    _clearingAppData = true;
    try {
      await _recordsReady;
      final tabs = List<_TerminalTab>.of(_tabs);
      for (final tab in tabs) {
        tab.isClosed = true;
        tab.inputFlushTimer?.cancel();
        tab.inputFlushTimer = null;
        tab.pendingInput.takeBytes();
        tab.focusNode.unfocus();
      }

      if (mounted) {
        setState(() {
          _tabs.clear();
          _activeTabId = null;
        });
      }

      for (final tab in tabs) {
        tab.focusNode.dispose();
        tab.terminalController.dispose();
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
    };
    final tab = _TerminalTab(
      id: id,
      title: connection.sessionTitle ?? title,
      connection: connection,
    );
    tab.terminal = Terminal(
      maxLines: 10000,
      onOutput: (value) => _queueInput(tab, value),
      onResize: (columns, rows, pixelWidth, pixelHeight) {
        _handleResize(tab, columns, rows);
      },
    );
    return tab;
  }

  void _addLocalShellTab() {
    if (kIsWeb) {
      _showMessage('浏览器版本不支持启动本地 Shell');
      return;
    }
    _addConnectionTab(const _TerminalConnection.local());
  }

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
        SessionProtocol.ssh => _TerminalConnection.ssh(
          record.address,
          record.port,
          sessionTitle: record.name,
          username: record.username,
          identityFile: record.identityFile,
          sshConfigAlias: record.sshConfigAlias,
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
          return;
        }
        if (record.protocol == SessionProtocol.ssh) {
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
      if (kIsWeb && connection.kind != _ConnectionKind.ssh) {
        throw UnsupportedError('浏览器版本仅支持通过 WebSocket 网关连接 SSH');
      }
      if (connection.kind == _ConnectionKind.ssh) {
        await _openSshSession(tab, connection);
        if (tab.isClosed) return;
        if (tab.sshSession == null || tab.sshClient == null) {
          tab.starting = false;
          if (tab.id == _activeTabId) {
            _sidebarSection = _SidebarSection.sessions;
          }
          _refresh(tab);
          return;
        }
        if (tab.id == _activeTabId) {
          _sidebarSection = _SidebarSection.files;
        }
        tab.starting = false;
        tab.status = connection.connectedStatus;
        _refresh(tab);
        _notifySessionProgress(
          tab,
          'SSH 登录成功',
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
        _ConnectionKind.ssh => throw StateError('SSH 会话应使用 SSH 客户端启动'),
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
      if (tab.connection.kind == _ConnectionKind.ssh &&
          tab.id == _activeTabId) {
        _sidebarSection = _SidebarSection.sessions;
      }
      tab.starting = false;
      tab.status = '${tab.connection.displayName}连接失败';
      tab.errorMessage = error.toString();
      tab.terminal.write('\r\n[启动失败] $error\r\n');
      if (tab.connection.kind == _ConnectionKind.ssh) {
        _notifySessionProgress(
          tab,
          'SSH 登录失败：$error',
          isError: true,
          tabStatus: 'SSH 登录失败',
        );
      } else {
        _refresh(tab);
      }
    }
  }

  Future<void> _openSshSession(
    _TerminalTab tab,
    _TerminalConnection connection,
  ) async {
    await _runPortKnockSequence(tab, connection);
    if (tab.isClosed) return;

    final savedCredentials = await _sshCredentialStore.read(
      connection.credentialKey,
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
        ((password == null || password.isEmpty) && !hasPrivateKey) ||
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

    List<SSHKeyPair> identities = const [];
    final trimmedPrivateKey = privateKeyPem?.trim() ?? '';
    if (trimmedPrivateKey.isNotEmpty) {
      try {
        identities = SSHKeyPair.fromPem(
          trimmedPrivateKey,
          privateKeyPassphrase?.isEmpty ?? true ? null : privateKeyPassphrase,
        );
      } catch (error) {
        identities = const [];
        _notifySessionProgress(tab, '私钥无法读取：$error', isError: true);
        _notifySessionProgress(tab, '密钥登录失败，使用密码重试...');
      }
    }

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
      final method = orderedAttempts[index];
      final isKeyAttempt = method == _SshAuthMethod.key;
      _notifySessionProgress(tab, isKeyAttempt ? '正在尝试密钥登录...' : '正在尝试密码登录...');
      final socket = await _connectSshSocket(connection);
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
    _notifySessionProgress(tab, '认证成功，正在打开终端...');
    try {
      final remoteSession = await authenticatedClient.shell(
        pty: SSHPtyConfig(width: tab.columns, height: tab.rows),
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

      unawaited(_recordConnection(connection));
      tab.outputSubscription = _mergeSshOutput(remoteSession)
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(
            tab.terminal.write,
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

  Future<SSHSocket> _connectSshSocket(_TerminalConnection connection) => kIsWeb
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
    _TerminalConnection connection,
  ) async {
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
          _notifySessionProgress(tab, '$protocolName 敲门：$target');
          tab.terminal.write('\r\n[端口敲门] $protocolName $target\r\n');
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
        case PortKnockActionKind.delay:
          _notifySessionProgress(tab, '端口敲门延迟 ${action.delayMs} ms');
          tab.terminal.write('\r\n[端口敲门] 延迟 ${action.delayMs} ms\r\n');
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
    tab.terminal.write('\r\n[SSH 输出错误] $error\r\n');
    _refresh(tab);
  }

  void _handleSshSessionExit(_TerminalTab tab, SSHClient client) {
    if (!identical(tab.sshClient, client)) return;
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
    _refresh(tab);
    unawaited(client.close());
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
    final sshClient = tab.sshClient;
    tab.sshClient = null;
    tab.sshSession = null;
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

  void _flushInput(_TerminalTab tab) {
    tab.inputFlushTimer?.cancel();
    tab.inputFlushTimer = null;

    final sessionId = tab.sessionId;
    final sshSession = tab.sshSession;
    if ((sessionId == null && sshSession == null) || tab.pendingInput.isEmpty) {
      return;
    }

    final data = tab.pendingInput.takeBytes();
    tab.inputWriteQueue = tab.inputWriteQueue
        .then((_) async {
          if (sshSession != null) {
            await sshSession.stdin.addStream(
              Stream<Uint8List>.value(Uint8List.fromList(data)),
            );
            await sshSession.flush();
          } else if (sessionId != null) {
            await writeTerminalInput(sessionId: sessionId, data: data);
          }
        })
        .catchError((Object error) {
          if (tab.isClosed) return;
          tab.errorMessage = error.toString();
          tab.status = '终端输入失败';
          if (sshSession != null) {
            _showMessage('SSH 输入失败：$error', isError: true);
          }
          _refresh(tab);
        });
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
    tab.terminal.write('\r\n[${tab.connection.displayName}输出错误] $error\r\n');
    _refresh(tab);
  }

  void _handleSessionExit(_TerminalTab tab, PlatformInt64 sessionId) {
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
    return tab.isConnected ? colors.primary : colors.onSurfaceVariant;
  }

  Future<void> _disposeTab(_TerminalTab tab) async {
    await tab.inputWriteQueue;
    final sessionId = tab.sessionId;
    tab.sessionId = null;
    final sshClient = tab.sshClient;
    tab.sshClient = null;
    tab.sshSession = null;
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
          const SizedBox(width: 6),
          IconButton(
            tooltip: '设置',
            onPressed: () => unawaited(_openSettings()),
            icon: const Icon(Icons.settings_outlined),
          ),
          const SizedBox(width: 14),
        ],
      ),
      body: Row(
        children: [
          _buildSidebarRail(colors),
          VerticalDivider(width: 1, thickness: 1, color: colors.outlineVariant),
          if (_sidebarSection == _SidebarSection.sessions)
            _buildSessionSidebar(colors),
          if (_sidebarSection == _SidebarSection.files)
            _buildFileSidebar(activeTab, colors),
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

  Widget _buildSidebarRail(ColorScheme colors) {
    Widget destination(_SidebarSection section, IconData icon, String label) {
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
                child: Icon(
                  icon,
                  size: 20,
                  color: selected ? colors.primary : colors.onSurfaceVariant,
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
        color: const Color(0xFF101412),
        child: Column(
          children: [
            const SizedBox(height: 10),
            destination(_SidebarSection.sessions, Icons.dns_outlined, '会话'),
            destination(
              _SidebarSection.files,
              Icons.folder_copy_outlined,
              '文件',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileSidebar(_TerminalTab? tab, ColorScheme colors) {
    Widget placeholder({
      required String title,
      required String description,
    }) => SizedBox(
      width: 260,
      child: ColoredBox(
        color: const Color(0xFF131816),
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
                onPressed: () =>
                    unawaited(_handleNewSession(_NewSessionAction.ssh)),
                icon: const Icon(Icons.lock_open_rounded, size: 18),
                label: const Text('新建 SSH'),
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
    if (tab.connection.kind != _ConnectionKind.ssh) {
      return placeholder(
        title: '当前不是 SSH 会话',
        description: 'SFTP 和 SCP 使用 SSH 连接。切换到 SSH 标签后即可管理远端文件。',
      );
    }
    if (tab.sshSession == null || tab.sshClient == null) {
      return placeholder(
        title: 'SSH 尚未连接',
        description: tab.status.isEmpty ? '连接 SSH 后即可打开远端文件列表。' : tab.status,
      );
    }

    return RemoteFileBrowser(
      key: ValueKey('remote-files-${tab.id}'),
      client: tab.sshClient!,
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

  void _insertRemotePath(_TerminalTab tab, String path) {
    if (tab.id != _activeTabId || !tab.isConnected) return;
    tab.focusNode.requestFocus();
    tab.terminal.paste(path);
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
                  if (!kIsWeb)
                    PopupMenuButton<_SshConfigImportSource>(
                      tooltip: '导入 SSH 配置',
                      onSelected: (source) =>
                          unawaited(_importSshConfig(source)),
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: _SshConfigImportSource.defaultConfig,
                          child: Text('导入 ~/.ssh/config'),
                        ),
                        PopupMenuItem(
                          value: _SshConfigImportSource.chooseFile,
                          child: Text('选择配置文件…'),
                        ),
                      ],
                      icon: const Icon(Icons.file_open_outlined),
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
    final protocolIcon = switch (record.protocol) {
      SessionProtocol.serial => Icons.usb_rounded,
      SessionProtocol.telnet => Icons.lan_rounded,
      SessionProtocol.ssh => Icons.lock_open_rounded,
    };
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
            width: 204,
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
                    _insertRemotePath(tab, details.data),
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
                          theme: terminalTheme,
                          textStyle: const TerminalStyle(
                            fontSize: 14,
                            fontFamily: 'monospace',
                          ),
                          onSecondaryTapDown: (details, offset) {
                            unawaited(_handleSecondaryTap(tab));
                          },
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
                  '成功连接过的串口、Telnet 和 SSH 会显示在这里。',
                  style: TextStyle(color: colors.onSurfaceVariant),
                )
              else
                for (final record in recent)
                  Card(
                    margin: const EdgeInsets.only(bottom: 6),
                    color: const Color(0xFF151A17),
                    child: ListTile(
                      leading: Icon(switch (record.protocol) {
                        SessionProtocol.serial => Icons.usb_rounded,
                        SessionProtocol.telnet => Icons.lan_rounded,
                        SessionProtocol.ssh => Icons.lock_open_rounded,
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

enum _NewSessionAction { local, serial, telnet, ssh, quickConnect, addSession }

enum _SshConfigImportSource { defaultConfig, chooseFile }

enum _SidebarSection { sessions, files }

enum _RecordAction { save, rename, delete, removeRecent }

enum _ConnectionKind { local, serial, telnet, ssh }

enum _SshAuthMethod { key, password }

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
      sshConfigAlias = null;

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
       sshConfigAlias = null;

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
      sshConfigAlias = null;

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
  }) : kind = _ConnectionKind.ssh,
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

  String get displayName => switch (kind) {
    _ConnectionKind.local => '本地终端',
    _ConnectionKind.serial => '串口 $address',
    _ConnectionKind.telnet => 'Telnet $address:$port',
    _ConnectionKind.ssh => 'SSH $address:$port',
  };

  String get openingStatus => switch (kind) {
    _ConnectionKind.local => '正在启动本地 shell',
    _ConnectionKind.serial => '正在打开串口 $address',
    _ConnectionKind.telnet => '正在连接 Telnet $address:$port',
    _ConnectionKind.ssh => '正在连接 SSH $address:$port',
  };

  String get connectedStatus => switch (kind) {
    _ConnectionKind.local => '本地终端已连接',
    _ConnectionKind.serial => '串口已连接 · $address',
    _ConnectionKind.telnet => 'Telnet 已连接 · $address:$port',
    _ConnectionKind.ssh => 'SSH 已连接 · $address:$port',
  };

  SessionProtocol? get sessionProtocol => switch (kind) {
    _ConnectionKind.local => null,
    _ConnectionKind.serial => SessionProtocol.serial,
    _ConnectionKind.telnet => SessionProtocol.telnet,
    _ConnectionKind.ssh => SessionProtocol.ssh,
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
    _ConnectionKind.ssh =>
      '${kind.name}:${address.trim().toLowerCase()}:$port:$webSocketUrl:${sshConfigAlias?.toLowerCase() ?? ''}',
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
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _privateKeyController = TextEditingController();
  final _privateKeyPassphraseController = TextEditingController();
  final _webSocketUrlController = TextEditingController();
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

  @override
  void initState() {
    super.initState();
    _selectedProtocol = widget.initialProtocol;
    _portController.text = _selectedProtocol == _ConnectionKind.ssh
        ? '22'
        : '23';
    _portsFuture = kIsWeb
        ? Future.value(const <SerialPortEntry>[])
        : listSerialPorts();
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
    _deviceController.dispose();
    _baudController.dispose();
    _profileNameController.dispose();
    super.dispose();
  }

  void _connect() {
    if (!_formKey.currentState!.validate()) return;
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
      child: ListTile(
        selected: selected,
        selectedTileColor: colors.primaryContainer.withValues(alpha: 0.65),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        leading: Icon(icon, color: selected ? colors.primary : null),
        title: Text(title),
        subtitle: Text(subtitle),
        onTap: () {
          setState(() {
            if (protocol == _ConnectionKind.ssh &&
                _portController.text == '23') {
              _portController.text = '22';
            } else if (protocol == _ConnectionKind.telnet &&
                _portController.text == '22') {
              _portController.text = '23';
            }
            _selectedProtocol = protocol;
          });
        },
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
          autofocus: _selectedProtocol == _ConnectionKind.ssh,
          decoration: const InputDecoration(
            labelText: 'SSH 主机名或 IP 地址',
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
                decoration: const InputDecoration(
                  labelText: 'SSH 端口',
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
        DropdownButtonFormField<SshAuthenticationMode>(
          initialValue: _authenticationMode,
          decoration: const InputDecoration(
            labelText: '认证模式',
            prefixIcon: Icon(Icons.tune_rounded),
          ),
          items: [
            for (final mode in SshAuthenticationMode.values)
              DropdownMenuItem(
                value: mode,
                child: Text(_authenticationModeLabel(mode)),
              ),
          ],
          onChanged: (value) {
            if (value != null) setState(() => _authenticationMode = value);
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
                ? '浏览器连接需要配置 WebSocket SSH 网关'
                : null,
          ),
          const SizedBox(height: 8),
          Text(
            '网关须将二进制 WebSocket 数据帧双向转发到目标 SSH 主机。支持 {host}/{port} 占位符；否则应用会追加 host、port 查询参数。HTTPS 页面需要 wss://。URL 不要包含访问令牌或密码。',
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
                                _ConnectionKind.local => '本地终端',
                              }, style: Theme.of(context).textTheme.titleLarge),
                              const SizedBox(height: 20),
                              if (_selectedProtocol == _ConnectionKind.serial)
                                _buildSerialFields()
                              else if (_selectedProtocol ==
                                  _ConnectionKind.telnet)
                                _buildTelnetFields(),
                              if (_selectedProtocol == _ConnectionKind.ssh)
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
  final GlobalKey terminalViewKey = GlobalKey();
  final BytesBuilder pendingInput = BytesBuilder(copy: false);
  late final Terminal terminal;

  Future<void> inputWriteQueue = Future<void>.value();
  StreamSubscription<String>? outputSubscription;
  Timer? inputFlushTimer;
  PlatformInt64? sessionId;
  SSHClient? sshClient;
  SSHSession? sshSession;
  String? remoteDirectory;
  int remoteRefreshToken = 0;
  RemoteTransferProtocol fileTransferProtocol = RemoteTransferProtocol.sftp;
  int columns = 100;
  int rows = 30;
  bool starting = false;
  bool restarting = false;
  bool isClosed = false;
  bool localFileDragHover = false;
  String status = '正在连接';
  String? errorMessage;

  bool get isConnected => sessionId != null || sshSession != null;
}
