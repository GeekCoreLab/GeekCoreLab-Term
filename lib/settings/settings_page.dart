import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_settings.dart';
import '../terminal/terminal_shortcuts.dart';
import '../terminal/terminal_keyword_highlights.dart';
import 'window_state.dart';

class AppSettingsPage extends StatefulWidget {
  const AppSettingsPage({
    required this.settings,
    required this.onClearAppData,
    this.sessionGroups = const [],
    super.key,
  });

  final AppSettingsController settings;
  final Future<void> Function() onClearAppData;
  final List<String> sessionGroups;

  @override
  State<AppSettingsPage> createState() => _AppSettingsPageState();
}

class _AppSettingsPageState extends State<AppSettingsPage> {
  bool _clearing = false;
  double? _terminalFontSizeDraft;
  TerminalFontFamily? _terminalFontFamilyDraft;

  bool get _supportsWindowBounds =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS);

  Future<void> _manageMasterPassword() async {
    final update = await showDialog<_MasterPasswordUpdate>(
      context: context,
      builder: (_) => _MasterPasswordDialog(settings: widget.settings),
    );
    if (update == null || !mounted) return;

    try {
      final password = update.password;
      if (password == null) {
        await widget.settings.removeMasterPassword();
        _showMessage('已移除主密码');
      } else {
        await widget.settings.setMasterPassword(password);
        _showMessage('主密码已更新；下次启动时需要输入');
      }
    } catch (error) {
      _showMessage('更新主密码失败：$error', isError: true);
    }
  }

  Future<void> _setRememberWindowBounds(bool value) async {
    try {
      await widget.settings.setRememberWindowBounds(value);
      await WindowStateManager.instance.setRemembering(value);
    } catch (error) {
      _showMessage('保存窗口设置失败：$error', isError: true);
    }
  }

  Future<void> _saveTerminalFontSize(double value) async {
    try {
      await widget.settings.setTerminalFontSize(value);
      if (mounted) setState(() => _terminalFontSizeDraft = value);
    } catch (error) {
      if (mounted) {
        setState(
          () => _terminalFontSizeDraft = widget.settings.terminalFontSize,
        );
        _showMessage('保存终端字号失败：$error', isError: true);
      }
    }
  }

  Future<void> _saveTerminalFontFamily(TerminalFontFamily family) async {
    try {
      await widget.settings.setTerminalFontFamily(family);
      if (mounted) setState(() => _terminalFontFamilyDraft = family);
    } catch (error) {
      if (mounted) {
        setState(
          () => _terminalFontFamilyDraft = widget.settings.terminalFontFamily,
        );
        _showMessage('保存终端字体失败：$error', isError: true);
      }
    }
  }

  Future<void> _saveSshKeepAliveSeconds(int seconds) async {
    try {
      await widget.settings.setSshKeepAliveSeconds(seconds);
    } catch (error) {
      if (mounted) _showMessage('保存 SSH 保活设置失败：$error', isError: true);
    }
  }

  Future<void> _saveStartupSessionGroup(String? group) async {
    try {
      await widget.settings.setStartupSessionGroup(group);
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) _showMessage('保存启动会话分类失败：$error', isError: true);
    }
  }

  Future<void> _editTerminalShortcut(TerminalShortcutAction action) async {
    final current = widget.settings.terminalShortcuts[action]!;
    final binding = await showDialog<TerminalShortcutBinding>(
      context: context,
      builder: (_) => _TerminalShortcutDialog(action: action, current: current),
    );
    if (binding == null || !mounted) return;
    try {
      await widget.settings.setTerminalShortcut(action, binding);
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) _showMessage('保存快捷键失败：$error', isError: true);
    }
  }

  Future<void> _resetTerminalShortcuts() async {
    try {
      await widget.settings.resetTerminalShortcuts();
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) _showMessage('恢复默认快捷键失败：$error', isError: true);
    }
  }

  Future<void> _addTerminalKeywordRule() async {
    if (widget.settings.terminalKeywordRules.length >=
        maxTerminalKeywordRules) {
      _showMessage('关键字规则最多 $maxTerminalKeywordRules 条', isError: true);
      return;
    }
    final rule = await showDialog<TerminalKeywordRule>(
      context: context,
      builder: (_) => const _TerminalKeywordRuleDialog(),
    );
    if (rule == null || !mounted) return;
    if (widget.settings.terminalKeywordRules.any(
      (existing) =>
          existing.keyword.toLowerCase() == rule.keyword.toLowerCase(),
    )) {
      _showMessage('关键字“${rule.keyword}”已存在', isError: true);
      return;
    }
    try {
      await widget.settings.setTerminalKeywordRules([
        ...widget.settings.terminalKeywordRules,
        rule,
      ]);
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) _showMessage('保存关键字规则失败：$error', isError: true);
    }
  }

  Future<void> _removeTerminalKeywordRule(TerminalKeywordRule rule) async {
    try {
      await widget.settings.setTerminalKeywordRules(
        widget.settings.terminalKeywordRules
            .where((item) => item != rule)
            .toList(),
      );
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) _showMessage('删除关键字规则失败：$error', isError: true);
    }
  }

  Future<void> _confirmClearAppData() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.delete_forever_outlined),
        title: const Text('清除应用数据？'),
        content: const Text(
          '这会删除已保存和最近连接、SSH 登录凭据与主机信任、终端主题和关键字高亮、启动会话组、窗口设置、终端布局、主密码，并关闭当前打开的会话。此操作无法撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            icon: const Icon(Icons.delete_outline_rounded),
            label: const Text('清除数据'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;

    setState(() => _clearing = true);
    try {
      await widget.onClearAppData();
      if (mounted) _showMessage('应用数据已清除');
    } catch (error) {
      if (mounted) _showMessage('清除应用数据失败：$error', isError: true);
    } finally {
      if (mounted) setState(() => _clearing = false);
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

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final colors = Theme.of(context).colorScheme;
    final fontSize = _terminalFontSizeDraft ?? settings.terminalFontSize;
    final fontFamily = _terminalFontFamilyDraft ?? settings.terminalFontFamily;
    final sessionGroups = widget.sessionGroups
        .where((group) => group.trim().isNotEmpty)
        .toSet()
        .toList();
    final startupSessionGroup =
        sessionGroups.contains(settings.startupSessionGroup)
        ? settings.startupSessionGroup
        : null;
    final clearButton = OutlinedButton.icon(
      onPressed: _clearing ? null : _confirmClearAppData,
      style: OutlinedButton.styleFrom(
        foregroundColor: colors.error,
        side: BorderSide(color: colors.error.withValues(alpha: 0.65)),
      ),
      icon: _clearing
          ? const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.delete_outline_rounded),
      label: Text(_clearing ? '正在清除' : '清除应用数据'),
    );

    return PopScope(
      canPop: !_clearing,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('设置'),
          leading: IconButton(
            tooltip: '返回',
            onPressed: _clearing ? null : () => Navigator.maybePop(context),
            icon: const Icon(Icons.arrow_back_rounded),
          ),
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
              children: [
                _SettingsSection(
                  icon: Icons.palette_outlined,
                  title: '外观',
                  subtitle: '更改工作区和终端的配色；浅色方案参考 HexHub 工作台',
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final style in AppThemeStyle.values)
                        ChoiceChip(
                          selected: settings.themeStyle == style,
                          onSelected: _clearing
                              ? null
                              : (_) async {
                                  try {
                                    await settings.setThemeStyle(style);
                                  } catch (error) {
                                    if (mounted) {
                                      _showMessage(
                                        '保存主题失败：$error',
                                        isError: true,
                                      );
                                    }
                                  }
                                },
                          avatar: CircleAvatar(
                            radius: 8,
                            backgroundColor: style.seedColor,
                          ),
                          label: Text(style.label),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _SettingsSection(
                  icon: Icons.text_fields_rounded,
                  title: '终端字号',
                  subtitle: '调整所有终端标签的等宽字体大小',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Expanded(child: Text('字号')),
                          Text('${fontSize.round()} px'),
                        ],
                      ),
                      Slider(
                        value: fontSize,
                        min: 10,
                        max: 24,
                        divisions: 14,
                        label: '${fontSize.round()} px',
                        onChanged: _clearing
                            ? null
                            : (value) => setState(
                                () => _terminalFontSizeDraft = value,
                              ),
                        onChangeEnd: _clearing
                            ? null
                            : (value) =>
                                  unawaited(_saveTerminalFontSize(value)),
                      ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<TerminalFontFamily>(
                        key: ValueKey(fontFamily),
                        initialValue: fontFamily,
                        decoration: const InputDecoration(
                          labelText: '等宽字体',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          for (final family in TerminalFontFamily.values)
                            DropdownMenuItem(
                              value: family,
                              child: Text(family.label),
                            ),
                        ],
                        onChanged: _clearing
                            ? null
                            : (family) {
                                if (family != null) {
                                  unawaited(_saveTerminalFontFamily(family));
                                }
                              },
                      ),
                      const SizedBox(height: 8),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: settings.terminalTheme.background,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          'ssh admin@router.local  # 中文显示预览',
                          style: TextStyle(
                            color: settings.terminalTheme.foreground,
                            fontFamily: fontFamily.familyName,
                            fontSize: fontSize,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.fade,
                          softWrap: false,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _SettingsSection(
                  icon: Icons.highlight_alt_rounded,
                  title: '终端关键字高亮',
                  subtitle: '按字面匹配终端缓冲区文本，不修改远端 ANSI 输出',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (settings.terminalKeywordRules.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Text(
                            '尚未添加规则；新增后会应用到当前打开的终端和后续输出。',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      for (final rule in settings.terminalKeywordRules)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: CircleAvatar(
                            radius: 9,
                            backgroundColor: rule.color,
                          ),
                          title: Text(rule.keyword),
                          subtitle: Text(
                            rule.caseSensitive ? '区分大小写' : '不区分大小写',
                          ),
                          trailing: IconButton(
                            tooltip: '删除“${rule.keyword}”规则',
                            onPressed: _clearing
                                ? null
                                : () => unawaited(
                                    _removeTerminalKeywordRule(rule),
                                  ),
                            icon: const Icon(Icons.delete_outline_rounded),
                          ),
                        ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: _clearing
                              ? null
                              : () => unawaited(_addTerminalKeywordRule()),
                          icon: const Icon(Icons.add_rounded),
                          label: const Text('添加关键字'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _SettingsSection(
                  icon: Icons.timer_outlined,
                  title: 'SSH 连接保活',
                  subtitle: '定期发送 SSH 保活请求，帮助维持空闲连接',
                  child: DropdownButtonFormField<int>(
                    key: ValueKey(settings.sshKeepAliveSeconds),
                    initialValue: settings.sshKeepAliveSeconds,
                    decoration: const InputDecoration(
                      labelText: '保活间隔',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final seconds
                          in AppSettingsController.sshKeepAliveOptions)
                        DropdownMenuItem(
                          value: seconds,
                          child: Text(seconds == 0 ? '关闭' : '$seconds 秒'),
                        ),
                    ],
                    onChanged: _clearing
                        ? null
                        : (seconds) {
                            if (seconds != null) {
                              unawaited(_saveSshKeepAliveSeconds(seconds));
                            }
                          },
                  ),
                ),
                const SizedBox(height: 16),
                _SettingsSection(
                  icon: Icons.folder_special_outlined,
                  title: '启动会话组',
                  subtitle: '下次启动时自动打开已保存会话；默认关闭',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (sessionGroups.isEmpty) ...[
                        Text(
                          '先在侧栏创建会话分类并保存会话，再选择启动分类。',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 12),
                      ],
                      DropdownButtonFormField<String>(
                        key: ValueKey(startupSessionGroup ?? ''),
                        initialValue: startupSessionGroup ?? '',
                        decoration: const InputDecoration(
                          labelText: '启动时打开',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          const DropdownMenuItem(
                            value: '',
                            child: Text('关闭自动启动'),
                          ),
                          for (final group in sessionGroups)
                            DropdownMenuItem(value: group, child: Text(group)),
                        ],
                        onChanged: _clearing
                            ? null
                            : (group) => unawaited(
                                _saveStartupSessionGroup(
                                  group == null || group.isEmpty ? null : group,
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _SettingsSection(
                  icon: Icons.keyboard_command_key_rounded,
                  title: '终端快捷键',
                  subtitle: '按下新的 Ctrl/Command 组合；Alt 与 AltGr 保留给文字输入',
                  child: Column(
                    children: [
                      for (final action in TerminalShortcutAction.values)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(action.label),
                          trailing: OutlinedButton(
                            onPressed: _clearing
                                ? null
                                : () =>
                                      unawaited(_editTerminalShortcut(action)),
                            child: Text(
                              widget.settings.terminalShortcuts[action]!.label(
                                isMacOS:
                                    defaultTargetPlatform ==
                                    TargetPlatform.macOS,
                              ),
                            ),
                          ),
                          onTap: _clearing
                              ? null
                              : () => unawaited(_editTerminalShortcut(action)),
                        ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: _clearing
                              ? null
                              : () => unawaited(_resetTerminalShortcuts()),
                          icon: const Icon(Icons.restart_alt_rounded, size: 18),
                          label: const Text('恢复默认快捷键'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _SettingsSection(
                  icon: Icons.password_rounded,
                  title: '主密码',
                  subtitle: settings.hasMasterPassword
                      ? '已设置 · 应用启动时需要输入；SSH 凭据仍由系统凭据存储单独保护'
                      : '用于应用启动解锁；SSH 凭据仍由系统凭据存储单独保护',
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: _clearing ? null : _manageMasterPassword,
                        icon: Icon(
                          settings.hasMasterPassword
                              ? Icons.edit_rounded
                              : Icons.lock_outline_rounded,
                        ),
                        label: Text(
                          settings.hasMasterPassword ? '修改主密码' : '设置主密码',
                        ),
                      ),
                      if (settings.hasMasterPassword)
                        const Text(
                          '留空新密码并验证当前密码即可移除',
                          style: TextStyle(fontSize: 12),
                        ),
                    ],
                  ),
                ),
                if (_supportsWindowBounds) ...[
                  const SizedBox(height: 16),
                  _SettingsSection(
                    icon: Icons.open_in_full_rounded,
                    title: '窗口',
                    subtitle: '下次启动时恢复桌面窗口的大小和位置',
                    child: SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('记住窗口位置和大小'),
                      value: settings.rememberWindowBounds,
                      onChanged: _clearing ? null : _setRememberWindowBounds,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                _SettingsSection(
                  icon: Icons.storage_outlined,
                  title: '本地数据',
                  subtitle: '删除此设备上保存的连接和设置',
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: colors.errorContainer.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: colors.error.withValues(alpha: 0.28),
                      ),
                    ),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final description = Row(
                          children: [
                            Icon(
                              Icons.warning_amber_rounded,
                              color: colors.error,
                            ),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Text(
                                '会一并删除保存的 SSH 凭据与主密码。',
                                style: TextStyle(fontSize: 13),
                              ),
                            ),
                          ],
                        );
                        if (constraints.maxWidth < 560) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              description,
                              const SizedBox(height: 14),
                              Align(
                                alignment: Alignment.centerRight,
                                child: clearButton,
                              ),
                            ],
                          );
                        }
                        return Row(
                          children: [
                            Expanded(child: description),
                            const SizedBox(width: 16),
                            clearButton,
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: colors.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            child,
          ],
        ),
      ),
    );
  }
}

class _TerminalShortcutDialog extends StatefulWidget {
  const _TerminalShortcutDialog({required this.action, required this.current});

  final TerminalShortcutAction action;
  final TerminalShortcutBinding current;

  @override
  State<_TerminalShortcutDialog> createState() =>
      _TerminalShortcutDialogState();
}

class _TerminalShortcutDialogState extends State<_TerminalShortcutDialog> {
  String? _error;

  KeyEventResult _capture(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.pop(context);
      return KeyEventResult.handled;
    }
    if (isTerminalShortcutModifier(event.logicalKey)) {
      return KeyEventResult.handled;
    }

    final keyboard = HardwareKeyboard.instance;
    final isMacOS = defaultTargetPlatform == TargetPlatform.macOS;
    final primary = isMacOS
        ? keyboard.isMetaPressed
        : keyboard.isControlPressed;
    if (!primary) {
      setState(() => _error = '请同时按住 Ctrl 或 Command');
      return KeyEventResult.handled;
    }

    Navigator.pop(
      context,
      TerminalShortcutBinding(
        keyId: event.logicalKey.keyId,
        shift: keyboard.isShiftPressed,
      ),
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isMacOS = defaultTargetPlatform == TargetPlatform.macOS;
    return AlertDialog(
      icon: const Icon(Icons.keyboard_command_key_rounded),
      title: Text('设置“${widget.action.label}”'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('点击下方区域并按下新的组合键。Esc 取消。'),
            const SizedBox(height: 14),
            Focus(
              autofocus: true,
              onKeyEvent: _capture,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 20,
                ),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: colors.outlineVariant),
                ),
                child: Column(
                  children: [
                    Icon(Icons.keyboard_rounded, color: colors.primary),
                    const SizedBox(height: 8),
                    Text(
                      widget.current.label(isMacOS: isMacOS),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '等待按键…',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: colors.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

class _MasterPasswordUpdate {
  const _MasterPasswordUpdate(this.password);

  final String? password;
}

class _MasterPasswordDialog extends StatefulWidget {
  const _MasterPasswordDialog({required this.settings});

  final AppSettingsController settings;

  @override
  State<_MasterPasswordDialog> createState() => _MasterPasswordDialogState();
}

class _MasterPasswordDialogState extends State<_MasterPasswordDialog> {
  final _currentPassword = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirmPassword = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _currentPassword.dispose();
    _newPassword.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });

    final current = _currentPassword.text;
    final next = _newPassword.text;
    final confirmation = _confirmPassword.text;
    try {
      if (widget.settings.hasMasterPassword &&
          !await widget.settings.verifyMasterPassword(current)) {
        _finishWithError('当前主密码不正确');
        return;
      }
    } catch (error) {
      _finishWithError('主密码验证失败：$error');
      return;
    }

    if (next.isEmpty && confirmation.isEmpty) {
      if (!widget.settings.hasMasterPassword) {
        _finishWithError('请输入新主密码');
        return;
      }
      if (mounted) Navigator.pop(context, const _MasterPasswordUpdate(null));
      return;
    }
    if (next.length < 10) {
      _finishWithError('主密码至少需要 10 个字符');
      return;
    }
    if (next != confirmation) {
      _finishWithError('两次输入的新主密码不一致');
      return;
    }
    if (mounted) Navigator.pop(context, _MasterPasswordUpdate(next));
  }

  void _finishWithError(String error) {
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasPassword = widget.settings.hasMasterPassword;
    return AlertDialog(
      title: Text(hasPassword ? '修改主密码' : '设置主密码'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasPassword) ...[
              TextField(
                controller: _currentPassword,
                autofocus: true,
                obscureText: true,
                onSubmitted: (_) => _submit(),
                decoration: const InputDecoration(
                  labelText: '当前主密码',
                  prefixIcon: Icon(Icons.lock_outline_rounded),
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _newPassword,
              autofocus: !hasPassword,
              obscureText: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: hasPassword ? '新主密码' : '新主密码（至少 10 个字符）',
                prefixIcon: const Icon(Icons.password_rounded),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _confirmPassword,
              obscureText: true,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: '确认新主密码',
                prefixIcon: Icon(Icons.check_circle_outline_rounded),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              hasPassword && _newPassword.text.isEmpty
                  ? '两个新密码框留空可移除主密码。'
                  : '使用较长的口令更安全。主密码不会上传到网络。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: Text(
            _saving
                ? '处理中…'
                : hasPassword &&
                      _newPassword.text.isEmpty &&
                      _confirmPassword.text.isEmpty
                ? '移除主密码'
                : '保存',
          ),
        ),
      ],
    );
  }
}

class _TerminalKeywordRuleDialog extends StatefulWidget {
  const _TerminalKeywordRuleDialog();

  @override
  State<_TerminalKeywordRuleDialog> createState() =>
      _TerminalKeywordRuleDialogState();
}

class _TerminalKeywordRuleDialogState
    extends State<_TerminalKeywordRuleDialog> {
  static const _colors = <(int, String)>[
    (0x70EF4444, '红'),
    (0x70F97316, '橙'),
    (0x70EAB308, '黄'),
    (0x704ADE80, '绿'),
    (0x7060A5FA, '蓝'),
    (0x70C084FC, '紫'),
  ];

  final _keywordController = TextEditingController();
  int _colorValue = _colors.first.$1;
  bool _caseSensitive = false;

  @override
  void dispose() {
    _keywordController.dispose();
    super.dispose();
  }

  void _submit() {
    final keyword = _keywordController.text.trim();
    if (keyword.isEmpty) return;
    Navigator.pop(
      context,
      TerminalKeywordRule(
        keyword: keyword,
        colorValue: _colorValue,
        caseSensitive: _caseSensitive,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加终端关键字'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _keywordController,
              autofocus: true,
              maxLength: 128,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: '关键字或短语',
                hintText: '例如 ERROR、timeout、连接失败',
              ),
            ),
            const SizedBox(height: 8),
            Text('高亮颜色', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (value, label) in _colors)
                  ChoiceChip(
                    selected: _colorValue == value,
                    avatar: CircleAvatar(
                      radius: 8,
                      backgroundColor: Color(value),
                    ),
                    label: Text(label),
                    onSelected: (_) => setState(() => _colorValue = value),
                  ),
              ],
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('区分大小写'),
              value: _caseSensitive,
              onChanged: (value) => setState(() => _caseSensitive = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _keywordController.text.trim().isEmpty ? null : _submit,
          child: const Text('添加'),
        ),
      ],
    );
  }
}
