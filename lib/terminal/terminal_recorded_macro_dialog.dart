import 'package:flutter/material.dart';

import 'terminal_input_recording.dart';

class TerminalRecordedMacroManagerDialog extends StatefulWidget {
  const TerminalRecordedMacroManagerDialog({
    required this.initialMacros,
    required this.onSave,
    required this.onRun,
    super.key,
  });

  final List<TerminalRecordedMacro> initialMacros;
  final Future<void> Function(List<TerminalRecordedMacro> macros) onSave;
  final Future<void> Function(
    TerminalRecordedMacro macro,
    TerminalRecordedMacroRunControl control,
  )
  onRun;

  @override
  State<TerminalRecordedMacroManagerDialog> createState() =>
      _TerminalRecordedMacroManagerDialogState();
}

class _TerminalRecordedMacroManagerDialogState
    extends State<TerminalRecordedMacroManagerDialog> {
  late List<TerminalRecordedMacro> _macros = List.of(widget.initialMacros);
  bool _working = false;
  TerminalRecordedMacroRunControl? _runControl;

  Future<void> _delete(TerminalRecordedMacro macro) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除录制宏？'),
        content: Text('确定删除“${macro.name}”？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await _persist(_macros.where((item) => item.id != macro.id).toList());
  }

  Future<void> _persist(List<TerminalRecordedMacro> updated) async {
    setState(() => _working = true);
    try {
      await widget.onSave(updated);
      if (mounted) setState(() => _macros = updated);
    } catch (error) {
      if (mounted) _showMessage('保存录制宏失败：$error', isError: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _run(TerminalRecordedMacro macro) async {
    final control = TerminalRecordedMacroRunControl();
    setState(() {
      _working = true;
      _runControl = control;
    });
    try {
      await widget.onRun(macro, control);
    } catch (error) {
      if (mounted) _showMessage('回放录制宏失败：$error', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _working = false;
          _runControl = null;
        });
      }
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final viewport = MediaQuery.sizeOf(context);
    final width = (viewport.width - 100).clamp(220.0, 620.0).toDouble();
    final height = (viewport.height - 250).clamp(220.0, 500.0).toDouble();
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.keyboard_alt_outlined),
          const SizedBox(width: 9),
          const Expanded(child: Text('录制宏')),
          if (_working)
            const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
      content: SizedBox(
        width: width,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '录制按钮位于终端工具栏。宏保存于本机应用设置且未加密；回放会逐段重发原始输入。不要录入密码或令牌。',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _macros.isEmpty
                  ? Center(
                      child: Text(
                        '还没有录制宏',
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    )
                  : ListView.separated(
                      itemCount: _macros.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final macro = _macros[index];
                        return ListTile(
                          enabled: !_working,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.play_arrow_rounded),
                          title: Text(
                            macro.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${macro.events.length} 个输入片段 · ${macro.totalBytes} 字节',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: _working ? null : () => _run(macro),
                          trailing: IconButton(
                            tooltip: '删除录制宏',
                            onPressed: _working ? null : () => _delete(macro),
                            icon: const Icon(Icons.delete_outline_rounded),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        if (_runControl case final control?)
          TextButton.icon(
            onPressed: control.cancel,
            icon: const Icon(Icons.stop_rounded),
            label: const Text('停止回放'),
          ),
        TextButton(
          onPressed: _working ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class TerminalRecordedMacroNameDialog extends StatefulWidget {
  const TerminalRecordedMacroNameDialog({
    required this.preview,
    required this.eventCount,
    required this.totalBytes,
    super.key,
  });

  final String preview;
  final int eventCount;
  final int totalBytes;

  @override
  State<TerminalRecordedMacroNameDialog> createState() =>
      _TerminalRecordedMacroNameDialogState();
}

class _TerminalRecordedMacroNameDialogState
    extends State<TerminalRecordedMacroNameDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _reviewed = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final viewport = MediaQuery.sizeOf(context);
    final width = (viewport.width - 100).clamp(220.0, 620.0).toDouble();
    final height = (viewport.height - 360).clamp(220.0, 360.0).toDouble();
    return AlertDialog(
      title: const Text('检查并保存录制宏'),
      content: SizedBox(
        width: width,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              maxLength: TerminalRecordedMacro.maxNameLength,
              decoration: const InputDecoration(labelText: '宏名称'),
              onChanged: (_) => setState(() {}),
              onSubmitted: (value) {
                if (value.trim().isNotEmpty && _reviewed) {
                  Navigator.pop(context, value.trim());
                }
              },
            ),
            Text(
              '${widget.eventCount} 个输入片段 · ${widget.totalBytes} 字节',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Text(
              '宏保存在本机应用设置中且未加密。确认预览不含密码或令牌。',
              style: TextStyle(color: colors.error, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: colors.outlineVariant),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(8),
                  child: SelectableText(
                    widget.preview,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _reviewed,
              title: const Text('我已检查，内容不含秘密信息'),
              controlAffinity: ListTileControlAffinity.leading,
              onChanged: (value) => setState(() => _reviewed = value == true),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('稍后'),
        ),
        FilledButton(
          onPressed: _controller.text.trim().isEmpty || !_reviewed
              ? null
              : () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class TerminalRecordedMacroReviewDialog extends StatefulWidget {
  const TerminalRecordedMacroReviewDialog({
    required this.macro,
    required this.targetNames,
    super.key,
  });

  final TerminalRecordedMacro macro;
  final List<String> targetNames;

  @override
  State<TerminalRecordedMacroReviewDialog> createState() =>
      _TerminalRecordedMacroReviewDialogState();
}

class _TerminalRecordedMacroReviewDialogState
    extends State<TerminalRecordedMacroReviewDialog> {
  bool _reviewed = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final viewport = MediaQuery.sizeOf(context);
    final width = (viewport.width - 100).clamp(220.0, 620.0).toDouble();
    final height = (viewport.height - 240).clamp(280.0, 560.0).toDouble();
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: colors.tertiary),
          const SizedBox(width: 9),
          const Expanded(child: Text('确认回放录制宏')),
        ],
      ),
      content: SizedBox(
        width: width,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('宏：${widget.macro.name} · ${widget.macro.totalBytes} 字节'),
            const SizedBox(height: 6),
            Text(
              '接收会话：${widget.targetNames.join('、')}',
              style: TextStyle(color: colors.primary),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: colors.outlineVariant),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(10),
                  child: SelectableText(
                    widget.macro.preview,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '原始输入可能包含密码、令牌或控制序列。回放会重发预览中的内容。',
              style: TextStyle(color: colors.error, fontSize: 12),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _reviewed,
              title: const Text('我已检查输入内容和目标会话'),
              controlAffinity: ListTileControlAffinity.leading,
              onChanged: (value) => setState(() => _reviewed = value == true),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _reviewed ? () => Navigator.pop(context, true) : null,
          child: const Text('回放'),
        ),
      ],
    );
  }
}
