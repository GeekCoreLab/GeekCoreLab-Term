import 'package:flutter/material.dart';

import 'package:geekcore_term/terminal/ssh_config.dart';

class SshConfigImportDialog extends StatefulWidget {
  const SshConfigImportDialog({
    required this.hosts,
    required this.warnings,
    super.key,
  });

  final List<SshConfigHost> hosts;
  final List<String> warnings;

  @override
  State<SshConfigImportDialog> createState() => _SshConfigImportDialogState();
}

class _SshConfigImportDialogState extends State<SshConfigImportDialog> {
  late final Set<String> _selectedAliases = {
    for (final host in widget.hosts) host.alias.toLowerCase(),
  };

  void _finish() {
    Navigator.of(context).pop([
      for (final host in widget.hosts)
        if (_selectedAliases.contains(host.alias.toLowerCase())) host,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('导入 OpenSSH 配置'),
      content: SizedBox(
        width: 560,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '选择要加入已保存会话的主机。支持 Host、HostName、User、Port、IdentityFile 和单层 ProxyJump 别名。',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            if (widget.warnings.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                constraints: const BoxConstraints(maxHeight: 90),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colors.tertiaryContainer.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    widget.warnings.join('\n'),
                    style: TextStyle(fontSize: 11, color: colors.onSurface),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: widget.hosts.length,
                itemBuilder: (context, index) {
                  final host = widget.hosts[index];
                  final selected = _selectedAliases.contains(
                    host.alias.toLowerCase(),
                  );
                  final details = <String>[
                    if (host.username.isNotEmpty) host.username,
                    '${host.hostName}:${host.port}',
                    if (host.identityFile != null)
                      '密钥 ${host.identityFile!.split(RegExp(r'[\\/]')).last}',
                    if (host.proxyJump != null) '经 ${host.proxyJump!.alias}',
                  ].join(' · ');
                  return CheckboxListTile(
                    dense: true,
                    value: selected,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(host.alias),
                    subtitle: Text(
                      details,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onChanged: (value) => setState(() {
                      if (value ?? false) {
                        _selectedAliases.add(host.alias.toLowerCase());
                      } else {
                        _selectedAliases.remove(host.alias.toLowerCase());
                      }
                    }),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _selectedAliases.isEmpty ? null : _finish,
          icon: const Icon(Icons.download_done_rounded),
          label: Text('导入 ${_selectedAliases.length} 项'),
        ),
      ],
    );
  }
}
