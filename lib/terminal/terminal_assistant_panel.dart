import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'terminal_assistant.dart';

class TerminalAssistantPanel extends StatelessWidget {
  const TerminalAssistantPanel({
    required this.analyzer,
    required this.sessionTitle,
    this.width = 260,
    super.key,
  });

  final TerminalAssistantAnalyzer? analyzer;
  final String? sessionTitle;
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
                        padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
                        child: Text(
                          '分析完全在本机进行；输出匹配可能来自命令回显。建议命令只会复制到剪贴板，不会自动执行。',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
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
