import 'package:flutter/material.dart';

import 'session_store.dart';

class CommandSnippetManagerDialog extends StatefulWidget {
  const CommandSnippetManagerDialog({
    required this.initialSnippets,
    required this.sessionTitle,
    required this.canInsert,
    required this.isBroadcasting,
    required this.onSave,
    required this.onInsert,
    super.key,
  });

  final List<CommandSnippet> initialSnippets;
  final String? sessionTitle;
  final bool canInsert;
  final bool isBroadcasting;
  final Future<void> Function(List<CommandSnippet> snippets) onSave;
  final Future<bool> Function(CommandSnippet snippet) onInsert;

  @override
  State<CommandSnippetManagerDialog> createState() =>
      _CommandSnippetManagerDialogState();
}

class _CommandSnippetManagerDialogState
    extends State<CommandSnippetManagerDialog> {
  late List<CommandSnippet> _snippets = List.of(widget.initialSnippets);
  bool _working = false;

  Future<void> _edit([CommandSnippet? existing]) async {
    final snippet = await showDialog<CommandSnippet>(
      context: context,
      builder: (_) => _CommandSnippetEditDialog(existing: existing),
    );
    if (!mounted || snippet == null) return;
    if (_snippets.any(
      (item) =>
          item.id != existing?.id &&
          item.name.toLowerCase() == snippet.name.toLowerCase(),
    )) {
      _showMessage('已存在同名命令片段');
      return;
    }
    final updated = [
      for (final item in _snippets)
        if (item.id == existing?.id) snippet else item,
      if (existing == null) snippet,
    ];
    await _persist(updated);
  }

  Future<void> _delete(CommandSnippet snippet) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除命令片段？'),
        content: Text('确定删除“${snippet.name}”？'),
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
    await _persist(_snippets.where((item) => item.id != snippet.id).toList());
  }

  Future<void> _persist(List<CommandSnippet> updated) async {
    setState(() => _working = true);
    try {
      await widget.onSave(updated);
      if (mounted) setState(() => _snippets = updated);
    } catch (error) {
      if (mounted) _showMessage('保存命令片段失败：$error', isError: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _insert(CommandSnippet snippet) async {
    if (!widget.canInsert) {
      _showMessage('请先连接一个终端会话');
      return;
    }
    final inserted = await widget.onInsert(snippet);
    if (mounted && inserted) Navigator.of(context).pop();
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
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(22, 18, 16, 8),
      contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      title: Row(
        children: [
          const Icon(Icons.terminal_rounded, size: 20),
          const SizedBox(width: 10),
          const Expanded(child: Text('命令片段')),
          if (_working)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
      content: SizedBox(
        width: 620,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.sessionTitle == null
                  ? '片段保存在本机。连接终端后可粘贴到会话。'
                  : '当前会话：${widget.sessionTitle}。片段为单行，只粘贴，不发送 Enter。',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
            if (widget.isBroadcasting) ...[
              const SizedBox(height: 6),
              Text(
                '分屏输入广播已开启；粘贴前还会要求确认，并会标注所有目标窗格。',
                style: TextStyle(fontSize: 11, color: colors.tertiary),
              ),
            ],
            const SizedBox(height: 8),
            Expanded(
              child: _snippets.isEmpty
                  ? Center(
                      child: Text(
                        '还没有命令片段',
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    )
                  : ListView.separated(
                      itemCount: _snippets.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final snippet = _snippets[index];
                        return ListTile(
                          enabled: !_working,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                          ),
                          leading: Icon(
                            Icons.play_arrow_rounded,
                            color: widget.canInsert
                                ? colors.primary
                                : colors.onSurfaceVariant,
                          ),
                          title: Text(
                            snippet.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            snippet.command,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                            ),
                          ),
                          onTap: _working ? null : () => _insert(snippet),
                          trailing: PopupMenuButton<String>(
                            enabled: !_working,
                            tooltip: '片段操作',
                            onSelected: (action) {
                              if (action == 'edit') {
                                _edit(snippet);
                              } else {
                                _delete(snippet);
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
            const SizedBox(height: 6),
            Text(
              '片段只允许单行，可用 && 或 ; 组合命令。不要放入密码、令牌或其他秘密。',
              style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
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
          label: const Text('新建片段'),
        ),
      ],
    );
  }
}

class _CommandSnippetEditDialog extends StatefulWidget {
  const _CommandSnippetEditDialog({this.existing});

  final CommandSnippet? existing;

  @override
  State<_CommandSnippetEditDialog> createState() =>
      _CommandSnippetEditDialogState();
}

class _CommandSnippetEditDialogState extends State<_CommandSnippetEditDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final TextEditingController _commandController = TextEditingController(
    text: widget.existing?.command ?? '',
  );

  @override
  void dispose() {
    _nameController.dispose();
    _commandController.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      CommandSnippet(
        id:
            widget.existing?.id ??
            'snippet-${DateTime.now().microsecondsSinceEpoch}',
        name: _nameController.text.trim(),
        command: _commandController.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.existing == null ? '新建命令片段' : '编辑命令片段'),
    content: SizedBox(
      width: 560,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _nameController,
              autofocus: true,
              maxLength: 80,
              decoration: const InputDecoration(labelText: '名称'),
              validator: (value) =>
                  value == null || value.trim().isEmpty ? '请输入片段名称' : null,
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _commandController,
              maxLines: 1,
              maxLength: 2048,
              keyboardType: TextInputType.text,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                labelText: '单行命令文本',
                helperText: '可使用 && 或 ; 组合多个命令',
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) return '请输入命令文本';
                if (value.contains('\n') || value.contains('\r')) {
                  return '命令片段必须为单行，避免粘贴时意外执行';
                }
                return null;
              },
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
