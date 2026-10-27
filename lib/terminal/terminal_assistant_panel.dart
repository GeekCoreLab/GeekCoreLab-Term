import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'terminal_assistant.dart';

class TerminalAssistantPanel extends StatelessWidget {
  const TerminalAssistantPanel({
    required this.analyzer,
    required this.sessionTitle,
    this.inlineHintsEnabled,
    this.onToggleInlineHints,
    this.onInsertCommand,
    this.width = 260,
    super.key,
  });

  final TerminalAssistantAnalyzer? analyzer;
  final String? sessionTitle;
  final bool? inlineHintsEnabled;
  final ValueChanged<bool>? onToggleInlineHints;
  final Future<void> Function(String command)? onInsertCommand;
  final double width;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: ColoredBox(
        color: colors.surfaceContainerLow,
        child: analyzer == null
            ? _emptyPanel(
                context,
                '终端助手',
                '打开终端后，本地助手会分析新输出中的常见故障线索。',
                width: width,
              )
            : ListenableBuilder(
                listenable: analyzer!,
                builder: (context, _) {
                  final findings = analyzer!.findings;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 8, 6),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.tips_and_updates_outlined,
                              size: 19,
                            ),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                '终端助手',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                            ),
                            if (findings.isNotEmpty)
                              IconButton(
                                tooltip: '清除本标签线索',
                                visualDensity: VisualDensity.compact,
                                onPressed: analyzer!.clear,
                                icon: const Icon(Icons.delete_sweep_outlined),
                              ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                        child: Text(
                          sessionTitle == null
                              ? '等待终端会话'
                              : '当前标签：$sessionTitle',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ),
                      if (inlineHintsEnabled != null) ...[
                        const Divider(height: 1),
                        Material(
                          color: Colors.transparent,
                          child: SwitchListTile.adaptive(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 2,
                            ),
                            title: const Text(
                              '内联提示',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            subtitle: const Text(
                              '输出服务状态与时间时插入直观标签',
                              style: TextStyle(fontSize: 11),
                            ),
                            value: inlineHintsEnabled!,
                            onChanged: onToggleInlineHints,
                          ),
                        ),
                      ],
                      const Divider(height: 1),
                      Expanded(
                        child: findings.isEmpty
                            ? _emptyPanel(
                                context,
                                '暂未发现线索',
                                '只分析后续终端文本，不重扫全部历史。匹配是启发式提示，也可能来自命令回显，不能证明当前主机状态。',
                                width: width,
                              )
                            : ListView.separated(
                                padding: const EdgeInsets.all(10),
                                itemCount: findings.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(height: 8),
                                itemBuilder: (context, index) =>
                                    _FindingCard(finding: findings[index]),
                              ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
                        child: Text(
                          '分析完全在本机进行；输出匹配可能来自命令回显。建议命令只会复制到剪贴板，不会自动执行。',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ),
                      const Divider(height: 1),
                      _TroubleshootCommandDrawer(
                        onInsertCommand: onInsertCommand,
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }

  Widget _emptyPanel(
    BuildContext context,
    String title,
    String description, {
    required double width,
  }) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
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
            ],
          ),
        ),
      ),
    );
  }
}

class _FindingCard extends StatelessWidget {
  const _FindingCard({required this.finding});

  final TerminalAssistantFinding finding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: colors.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 17,
                  color: colors.tertiary,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    finding.title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${_formatTime(finding.observedAt)} · 文本线索，需核实',
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: SelectableText(
                  finding.evidence,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              finding.explanation,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 7),
            for (final step in finding.verificationSteps)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('• ', style: TextStyle(color: colors.primary)),
                    Expanded(
                      child: Text(
                        step,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            if (finding.suggestedCommands.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text('可复制的检查命令', style: Theme.of(context).textTheme.labelMedium),
              for (final command in finding.suggestedCommands)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () async {
                      try {
                        await Clipboard.setData(ClipboardData(text: command));
                      } catch (error) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.maybeOf(
                          context,
                        )?.showSnackBar(SnackBar(content: Text('复制失败：$error')));
                        return;
                      }
                      if (!context.mounted) return;
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                        const SnackBar(content: Text('命令已复制；请检查后自行执行')),
                      );
                    },
                    icon: const Icon(Icons.copy_rounded, size: 14),
                    label: SizedBox(
                      width: 160,
                      child: Text(
                        command,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                    ),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      minimumSize: const Size(0, 30),
                      alignment: Alignment.centerLeft,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

String _formatTime(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}:${value.second.toString().padLeft(2, '0')}';

class _TroubleshootCommandDrawer extends StatefulWidget {
  const _TroubleshootCommandDrawer({this.onInsertCommand});

  final Future<void> Function(String command)? onInsertCommand;

  @override
  State<_TroubleshootCommandDrawer> createState() =>
      _TroubleshootCommandDrawerState();
}

class _TroubleshootCommandDrawerState
    extends State<_TroubleshootCommandDrawer> {
  bool _expanded = false;

  static const _groups = [
    _TroubleshootGroup(
      name: '网络与端口排查',
      icon: Icons.lan_outlined,
      commands: [
        _TroubleshootItem(
          label: '查看监听端口',
          command: 'ss -tulpn',
          description: '检查系统正在监听的 TCP/UDP 端口及对应进程',
        ),
        _TroubleshootItem(
          label: '测试外网连通性',
          command: 'ping -c 4 223.5.5.5',
          description: '向公共 DNS 发送 4 个 ICMP 包测试外网连通',
        ),
        _TroubleshootItem(
          label: '查看 DNS 配置',
          command: 'cat /etc/resolv.conf',
          description: '查看当前系统配置的 DNS 解析服务器',
        ),
        _TroubleshootItem(
          label: '查看默认路由',
          command: 'ip route show',
          description: '检查网关及内核网络路由配置',
        ),
      ],
    ),
    _TroubleshootGroup(
      name: '服务与日志 (systemd)',
      icon: Icons.miscellaneous_services_outlined,
      commands: [
        _TroubleshootItem(
          label: '列出异常失败服务',
          command: 'systemctl --failed',
          description: '列出所有当前处于 failed 状态的 unit',
        ),
        _TroubleshootItem(
          label: '查看系统错误日志',
          command: 'journalctl -p 3 -xb -n 50 --no-pager',
          description: '查看本次开机以来的 ERR 级别系统日志',
        ),
        _TroubleshootItem(
          label: '查看指定服务状态',
          command: 'systemctl status SERVICE --no-pager',
          description: '替换 SERVICE 查看运行状态与 PID',
        ),
        _TroubleshootItem(
          label: '跟踪指定服务日志',
          command: 'journalctl -u SERVICE -n 50 --no-pager',
          description: '替换 SERVICE 检索该单元近期 50 行日志',
        ),
      ],
    ),
    _TroubleshootGroup(
      name: '资源与进程 (CPU/内存/磁盘)',
      icon: Icons.speed_outlined,
      commands: [
        _TroubleshootItem(
          label: '查看磁盘容量剩余',
          command: 'df -h',
          description: '以易读单位查看各分区容量占用与剩余',
        ),
        _TroubleshootItem(
          label: '检查 Inode 耗尽',
          command: 'df -i',
          description: '检查各文件系统可用 Inode 是否耗尽',
        ),
        _TroubleshootItem(
          label: '查看物理与交换内存',
          command: 'free -h',
          description: '检查内存使用与 Swap 交换分区余量',
        ),
        _TroubleshootItem(
          label: '按 CPU 占用排序进程',
          command: 'ps aux --sort=-%cpu | head -n 15',
          description: '查看占用 CPU 最高的 15 个进程',
        ),
        _TroubleshootItem(
          label: '按内存占用排序进程',
          command: 'ps aux --sort=-%mem | head -n 15',
          description: '查看占用物理内存最高的 15 个进程',
        ),
      ],
    ),
    _TroubleshootGroup(
      name: '系统环境与安全',
      icon: Icons.shield_outlined,
      commands: [
        _TroubleshootItem(
          label: '查看操作系统与内核',
          command: 'uname -a',
          description: '显示 Linux 内核版本与系统架构',
        ),
        _TroubleshootItem(
          label: '查看当前活跃登录',
          command: 'who -a',
          description: '列出所有正在登录的终端与远程 IP',
        ),
        _TroubleshootItem(
          label: '查看登录与失败记录',
          command: 'last -n 20',
          description: '显示最近 20 条系统成功/异常登录日志',
        ),
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Material(
      color: colors.surfaceContainerHighest.withValues(alpha: 0.35),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    Icons.menu_book_outlined,
                    size: 18,
                    color: colors.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '排错命令本',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: colors.onSurface,
                      ),
                    ),
                  ),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 20,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(10, 4, 10, 12),
                  shrinkWrap: true,
                  itemCount: _groups.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, groupIndex) {
                    final group = _groups[groupIndex];
                    return Theme(
                      data: Theme.of(context).copyWith(
                        dividerColor: Colors.transparent,
                      ),
                      child: Material(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(8),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: colors.outlineVariant.withValues(alpha: 0.5),
                            ),
                          ),
                          child: ExpansionTile(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            leading: Icon(group.icon, size: 16, color: colors.primary),
                            title: Text(
                              group.name,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            tilePadding: const EdgeInsets.symmetric(horizontal: 10),
                            childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                            children: [
                              for (final item in group.commands)
                                _TroubleshootCommandRow(
                                  item: item,
                                  onInsertCommand: widget.onInsertCommand,
                                ),
                            ],
                          ),
                        ),
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
}

class _TroubleshootGroup {
  const _TroubleshootGroup({
    required this.name,
    required this.icon,
    required this.commands,
  });

  final String name;
  final IconData icon;
  final List<_TroubleshootItem> commands;
}

class _TroubleshootItem {
  const _TroubleshootItem({
    required this.label,
    required this.command,
    required this.description,
  });

  final String label;
  final String command;
  final String description;
}

class _TroubleshootCommandRow extends StatelessWidget {
  const _TroubleshootCommandRow({
    required this.item,
    this.onInsertCommand,
  });

  final _TroubleshootItem item;
  final Future<void> Function(String command)? onInsertCommand;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.label,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 11,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '复制命令',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                  icon: const Icon(Icons.copy_rounded, size: 13),
                  onPressed: () async {
                    try {
                      await Clipboard.setData(ClipboardData(text: item.command));
                    } catch (error) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                        SnackBar(content: Text('复制失败：$error')),
                      );
                      return;
                    }
                    if (!context.mounted) return;
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                      SnackBar(content: Text('已复制：${item.command}')),
                    );
                  },
                ),
                if (onInsertCommand != null)
                  IconButton(
                    tooltip: '粘贴到终端',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                    icon: const Icon(Icons.input_rounded, size: 13),
                    onPressed: () => unawaited(onInsertCommand!(item.command)),
                  ),
              ],
            ),
            SelectableText(
              item.command,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: colors.primary,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              item.description,
              style: TextStyle(
                fontSize: 10,
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
