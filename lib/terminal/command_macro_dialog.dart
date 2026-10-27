import 'package:flutter/material.dart';

import 'terminal_macro.dart';

class TerminalMacroManagerDialog extends StatefulWidget {
  const TerminalMacroManagerDialog({
    required this.initialMacros,
    required this.canRun,
    required this.onSave,
    required this.onRun,
    super.key,
  });

  final List<TerminalMacro> initialMacros;
  final bool canRun;
  final Future<void> Function(List<TerminalMacro> macros) onSave;
  final Future<void> Function(TerminalMacro macro) onRun;

  @override
  State<TerminalMacroManagerDialog> createState() =>
      _TerminalMacroManagerDialogState();
}

class _TerminalMacroManagerDialogState
    extends State<TerminalMacroManagerDialog> {
  late List<TerminalMacro> _macros = List.of(widget.initialMacros);
  bool _working = false;

  Future<void> _edit([TerminalMacro? existing]) async {
    final macro = await showDialog<TerminalMacro>(
      context: context,
      builder: (_) => _TerminalMacroEditDialog(existing: existing),
    );
    if (!mounted || macro == null) return;
    if (_macros.any(
      (item) =>
          item.id != existing?.id &&
          item.name.toLowerCase() == macro.name.toLowerCase(),
    )) {
      _showMessage('已存在同名命令宏');
      return;
    }
    final updated = [
      for (final item in _macros)
        if (item.id == existing?.id) macro else item,
      if (existing == null) macro,
    ];
    await _persist(updated);
  }

  Future<void> _delete(TerminalMacro macro) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除命令宏？'),
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

  Future<void> _persist(List<TerminalMacro> updated) async {
    setState(() => _working = true);
    try {
      await widget.onSave(updated);
      if (mounted) setState(() => _macros = updated);
    } catch (error) {
      if (mounted) _showMessage('保存命令宏失败：$error', isError: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _run(TerminalMacro macro) async {
    if (!widget.canRun) {
      _showMessage('请先连接一个终端会话');
      return;
    }
    setState(() => _working = true);
    try {
      await widget.onRun(macro);
    } catch (error) {
      if (mounted) _showMessage('执行命令宏失败：$error', isError: true);
    } finally {
      if (mounted) setState(() => _working = false);
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
    final contentWidth = (viewport.width - 120).clamp(240.0, 660.0).toDouble();
    final contentHeight = (viewport.height - 200)
        .clamp(220.0, 440.0)
        .toDouble();
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(22, 18, 16, 8),
      contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      title: Row(
        children: [
          const Icon(Icons.playlist_play_rounded, size: 21),
          const SizedBox(width: 10),
          const Expanded(child: Text('命令宏')),
          if (_working)
            const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
      content: SizedBox(
        width: contentWidth,
        height: contentHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.canRun
                  ? '脚本会按顺序发送展开后的命令并自动按 Enter；分支和重复次数有上限。执行前会显示命令及目标会话供你确认。'
                  : '脚本保存在本机。连接终端后可执行；执行前会显示展开命令和目标会话供你确认。',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            Text(
              '宏内容保存在普通本地设置中，请勿写入密码、令牌或其他秘密。',
              style: TextStyle(fontSize: 11, color: colors.tertiary),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _macros.isEmpty
                  ? Center(
                      child: Text(
                        '还没有命令宏',
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
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                          ),
                          leading: Icon(
                            Icons.play_arrow_rounded,
                            color: widget.canRun
                                ? colors.primary
                                : colors.onSurfaceVariant,
                          ),
                          title: Text(
                            macro.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            macro.isStructured
                                ? '${macro.commands.length} 条命令模板 · ${macro.parameters.length} 个变量'
                                : '${macro.commands.length} 条命令 · ${macro.commands.first}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                            ),
                          ),
                          onTap: _working ? null : () => _run(macro),
                          trailing: PopupMenuButton<String>(
                            enabled: !_working,
                            tooltip: '宏操作',
                            onSelected: (action) {
                              if (action == 'edit') {
                                _edit(macro);
                              } else {
                                _delete(macro);
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'edit', child: Text('编辑')),
                              PopupMenuItem(value: 'delete', child: Text('删除')),
                            ],
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
          onPressed: _working ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton.icon(
          onPressed: _working ? null : _edit,
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('新建宏'),
        ),
      ],
    );
  }
}

class TerminalMacroParametersDialog extends StatefulWidget {
  const TerminalMacroParametersDialog({required this.macro, super.key});

  final TerminalMacro macro;

  @override
  State<TerminalMacroParametersDialog> createState() =>
      _TerminalMacroParametersDialogState();
}

class _TerminalMacroParametersDialogState
    extends State<TerminalMacroParametersDialog> {
  final _formKey = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _controllers = {
    for (final parameter in widget.macro.parameters)
      parameter.name: TextEditingController(text: parameter.defaultValue ?? ''),
  };

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _prepare() {
    if (!_formKey.currentState!.validate()) return;
    try {
      final plan = widget.macro.prepare({
        for (final entry in _controllers.entries) entry.key: entry.value.text,
      });
      Navigator.of(context).pop(plan);
    } on FormatException catch (error) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final hasSecrets = widget.macro.parameters.any(
      (parameter) => parameter.isSecret,
    );
    return AlertDialog(
      scrollable: true,
      title: const Text('填写脚本变量'),
      content: SizedBox(
        width: (viewport.width - 100).clamp(240.0, 600.0).toDouble(),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('宏：${widget.macro.name}'),
              const SizedBox(height: 8),
              for (final parameter in widget.macro.parameters) ...[
                TextFormField(
                  controller: _controllers[parameter.name],
                  obscureText: parameter.isSecret,
                  autocorrect: false,
                  enableSuggestions: !parameter.isSecret,
                  maxLength: TerminalMacro.maxParameterLength,
                  decoration: InputDecoration(
                    labelText: parameter.isSecret
                        ? '${parameter.name} · 秘密变量'
                        : parameter.name,
                    helperText: parameter.defaultValue == null
                        ? '每次执行时填写'
                        : '默认值可在本次执行中覆盖',
                  ),
                  validator: (value) {
                    if ((parameter.isSecret ||
                            parameter.defaultValue == null) &&
                        (value ?? '').isEmpty) {
                      return '请填写 ${parameter.name}';
                    }
                    return null;
                  },
                ),
              ],
              if (hasSecrets) ...[
                const SizedBox(height: 8),
                Text(
                  '秘密值不会写入宏。若变量被插入命令，远端 shell 仍可能将其记录在历史或进程信息中。',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
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
        FilledButton.icon(
          onPressed: _prepare,
          icon: const Icon(Icons.preview_rounded, size: 18),
          label: const Text('预览命令'),
        ),
      ],
    );
  }
}

class TerminalMacroExecutionReviewDialog extends StatelessWidget {
  const TerminalMacroExecutionReviewDialog({
    required this.macro,
    required this.targetNames,
    this.plan,
    super.key,
  });

  final TerminalMacro macro;
  final List<String> targetNames;
  final TerminalMacroPlan? plan;

  int get _commandCount => plan?.commands.length ?? macro.commands.length;

  String get _reviewScript => plan?.reviewCommands.join('\n') ?? macro.script;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final viewport = MediaQuery.sizeOf(context);
    final contentWidth = (viewport.width - 120).clamp(240.0, 680.0).toDouble();
    final contentHeight = (viewport.height - 220)
        .clamp(220.0, 480.0)
        .toDouble();
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: colors.tertiary),
          const SizedBox(width: 10),
          const Expanded(child: Text('确认执行命令宏')),
        ],
      ),
      content: SizedBox(
        width: contentWidth,
        height: contentHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('宏：${macro.name} · $_commandCount 条命令'),
            const SizedBox(height: 8),
            Text(
              '目标会话（${targetNames.length}）',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 72,
              child: ListView.builder(
                itemCount: targetNames.length,
                itemBuilder: (context, index) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Icon(
                        Icons.computer_rounded,
                        size: 15,
                        color: colors.primary,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          targetNames[index],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              plan == null
                  ? '将按顺序发送以下命令，并为每行发送 Enter：'
                  : '以下为变量和条件展开后的命令，将按顺序发送并为每行发送 Enter：',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: colors.outlineVariant),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(10),
                  child: SelectableText(
                    _reviewScript,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      height: 1.45,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (plan?.usesSecret == true)
              Text(
                '秘密变量已在预览中遮蔽；实际值会原样发送到终端，远端 shell 可能记录该值。',
                style: TextStyle(color: colors.error, fontSize: 12),
              ),
            if (plan?.usesSecret == true) const SizedBox(height: 6),
            Text(
              '断线或重连会停止剩余命令；已经发送的命令无法回滚。',
              style: TextStyle(color: colors.error, fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: targetNames.isEmpty
              ? null
              : () => Navigator.of(context).pop(true),
          icon: const Icon(Icons.play_arrow_rounded, size: 18),
          label: Text('执行 $_commandCount 条命令'),
        ),
      ],
    );
  }
}

class _TerminalMacroEditDialog extends StatefulWidget {
  const _TerminalMacroEditDialog({this.existing});

  final TerminalMacro? existing;

  @override
  State<_TerminalMacroEditDialog> createState() =>
      _TerminalMacroEditDialogState();
}

class _TerminalMacroEditDialogState extends State<_TerminalMacroEditDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final TextEditingController _scriptController = TextEditingController(
    text: widget.existing?.script ?? '',
  );

  @override
  void dispose() {
    _nameController.dispose();
    _scriptController.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    try {
      final macro = TerminalMacro.fromScript(
        id:
            widget.existing?.id ??
            'macro-${DateTime.now().microsecondsSinceEpoch}',
        name: _nameController.text,
        script: _scriptController.text,
      );
      Navigator.pop(context, macro);
    } on FormatException catch (error) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  String? _validateName(String? value) {
    if (value == null || value.trim().isEmpty) return '请输入宏名称';
    if (value.trim().length > TerminalMacro.maxNameLength) {
      return '宏名称不能超过 80 个字符';
    }
    return null;
  }

  String? _validateScript(String? value) {
    try {
      TerminalMacro.parseScript(value ?? '');
      return null;
    } on FormatException catch (error) {
      return error.message;
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.existing == null ? '新建命令宏' : '编辑命令宏'),
    content: SizedBox(
      width: (MediaQuery.sizeOf(context).width - 120)
          .clamp(240.0, 620.0)
          .toDouble(),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _nameController,
              autofocus: true,
              maxLength: TerminalMacro.maxNameLength,
              decoration: const InputDecoration(labelText: '名称'),
              validator: _validateName,
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _scriptController,
              minLines: 6,
              maxLines: 12,
              maxLength: TerminalMacro.maxScriptLength,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                labelText: '逐行执行的命令',
                helperText:
                    r'语法：@param HOST=qa；@secret TOKEN；@if HOST == prod / @else / @endif；@repeat 3 as INDEX / @end；用 ${HOST} 插值。最多 20 次重复、40 条展开命令。变量原样插入，需检查 shell 语法；秘密变量不保存，但可能进入远端 shell 历史。',
                helperMaxLines: 4,
                alignLabelWithHint: true,
              ),
              validator: _validateScript,
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _save, child: const Text('保存')),
    ],
  );
}
