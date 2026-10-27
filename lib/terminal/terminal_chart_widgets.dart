import 'package:flutter/material.dart';
import 'package:geekcore_term/terminal/terminal_chart_models.dart';

/// A card rendering the parsed `df -h` disk usage information
class TerminalDfChartWidget extends StatelessWidget {
  const TerminalDfChartWidget({
    required this.entries,
    required this.onClose,
    super.key,
  });

  final List<DfFsEntry> entries;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.6)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.pie_chart_outline_rounded, size: 16, color: colors.primary),
                const SizedBox(width: 8),
                Text(
                  '磁盘空间分析 (df -h)',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface,
                  ),
                ),
                const Spacer(),
                Text(
                  '${entries.length} 个文件系统',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: SingleChildScrollView(
                child: Column(
                  children: entries.map((e) => _buildEntryRow(context, e)).toList(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEntryRow(BuildContext context, DfFsEntry entry) {
    final colors = Theme.of(context).colorScheme;
    final pct = (entry.usePercent * 100).toStringAsFixed(0);
    final barColor = entry.usePercent > 0.9
        ? colors.error
        : entry.usePercent > 0.75
            ? const Color(0xFFE3A008)
            : const Color(0xFF31C48D);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                flex: 3,
                child: Text(
                  entry.mountedOn.isEmpty ? entry.filesystem : entry.mountedOn,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${entry.used} / ${entry.size} ($pct%)',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: entry.usePercent,
                    backgroundColor: colors.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation<Color>(barColor),
                    minHeight: 6,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 65,
                child: Text(
                  '余: ${entry.avail}',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: colors.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A card rendering the parsed `free -h` memory/swap usage information
class TerminalFreeChartWidget extends StatelessWidget {
  const TerminalFreeChartWidget({
    required this.stats,
    required this.onClose,
    super.key,
  });

  final FreeMemStats stats;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final memPct = (stats.memUsageRatio * 100).toStringAsFixed(1);
    final swapPct = (stats.swapUsageRatio * 100).toStringAsFixed(1);

    final memColor = stats.memUsageRatio > 0.9
        ? colors.error
        : stats.memUsageRatio > 0.75
            ? const Color(0xFFE3A008)
            : const Color(0xFF31C48D);

    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.6)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.memory_rounded, size: 16, color: colors.primary),
                const SizedBox(width: 8),
                Text(
                  '内存与交换空间 (free -h)',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Physical Memory
            Row(
              children: [
                const Text(
                  '物理内存 (Mem)',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                ),
                const Spacer(),
                Text(
                  '${stats.usedMem} / ${stats.totalMem} ($memPct%)',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: stats.memUsageRatio,
                backgroundColor: colors.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(memColor),
                minHeight: 7,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '空闲: ${stats.freeMem}',
                  style: TextStyle(fontSize: 10, color: colors.onSurfaceVariant),
                ),
                if (stats.buffCacheMem.isNotEmpty)
                  Text(
                    '缓存: ${stats.buffCacheMem}',
                    style: TextStyle(fontSize: 10, color: colors.onSurfaceVariant),
                  ),
                if (stats.availableMem.isNotEmpty)
                  Text(
                    '可用: ${stats.availableMem}',
                    style: TextStyle(fontSize: 10, color: colors.onSurfaceVariant),
                  ),
              ],
            ),
            if (stats.totalSwap.isNotEmpty && stats.totalSwap != '0B' && stats.totalSwap != '0') ...[
              const SizedBox(height: 10),
              // Swap
              Row(
                children: [
                  const Text(
                    '交换空间 (Swap)',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                  ),
                  const Spacer(),
                  Text(
                    '${stats.usedSwap} / ${stats.totalSwap} ($swapPct%)',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: stats.swapUsageRatio,
                  backgroundColor: colors.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    stats.swapUsageRatio > 0.5 ? colors.error : const Color(0xFF55A9E8),
                  ),
                  minHeight: 7,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '空闲: ${stats.freeSwap}',
                    style: TextStyle(fontSize: 10, color: colors.onSurfaceVariant),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Floating badge widget displayed along the command range
class TerminalFloatingBadge extends StatelessWidget {
  const TerminalFloatingBadge({
    required this.isRenderMode,
    required this.onToggle,
    required this.label,
    super.key,
  });

  final bool isRenderMode;
  final VoidCallback onToggle;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: isRenderMode
                ? colors.primaryContainer.withValues(alpha: 0.9)
                : colors.surfaceContainerHigh.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isRenderMode
                  ? colors.primary.withValues(alpha: 0.6)
                  : colors.outline.withValues(alpha: 0.4),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 4,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isRenderMode ? Icons.auto_awesome_rounded : Icons.code_rounded,
                size: 12,
                color: isRenderMode ? colors.onPrimaryContainer : colors.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                isRenderMode ? '图表渲染' : '原始输出 (Raw)',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: isRenderMode ? colors.onPrimaryContainer : colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
