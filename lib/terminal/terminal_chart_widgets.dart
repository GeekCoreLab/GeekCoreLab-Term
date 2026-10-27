import 'package:flutter/material.dart';
import 'package:geekcore_term/terminal/terminal_chart_models.dart';

/// A card rendering the parsed `df -h` disk usage information
class TerminalDfChartWidget extends StatelessWidget {
  const TerminalDfChartWidget({
    required this.entries,
    required this.onClose,
    this.maxHeight,
    this.isFullscreen = false,
    this.onToggleFullscreen,
    super.key,
  });

  final List<DfFsEntry> entries;
  final VoidCallback? onClose;
  final double? maxHeight;
  final bool isFullscreen;
  final VoidCallback? onToggleFullscreen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final listMaxHeight = maxHeight != null
        ? (maxHeight! - 48.0).clamp(40.0, 2000.0)
        : 280.0;

    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.6)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.pie_chart_outline_rounded, size: 15, color: colors.primary),
                const SizedBox(width: 6),
                Text(
                  '磁盘空间分析 (df -h)',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
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
                if (onToggleFullscreen != null) ...[
                  const SizedBox(width: 6),
                  _ChartCardFullscreenButton(
                    isFullscreen: isFullscreen,
                    onToggle: onToggleFullscreen!,
                  ),
                ],
                if (onClose != null) ...[
                  const SizedBox(width: 4),
                  _ChartCardCloseButton(onClose: onClose!),
                ],
              ],
            ),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: listMaxHeight),
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
                  isFullscreen && entry.mountedOn.isNotEmpty
                      ? '${entry.mountedOn}  (${entry.filesystem})'
                      : (entry.mountedOn.isEmpty ? entry.filesystem : entry.mountedOn),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                  overflow: isFullscreen ? TextOverflow.visible : TextOverflow.ellipsis,
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
    this.maxHeight,
    this.isFullscreen = false,
    this.onToggleFullscreen,
    super.key,
  });

  final FreeMemStats stats;
  final VoidCallback? onClose;
  final double? maxHeight;
  final bool isFullscreen;
  final VoidCallback? onToggleFullscreen;

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
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.6)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.memory_rounded, size: 15, color: colors.primary),
                  const SizedBox(width: 6),
                  Text(
                    '内存与交换空间 (free -h)',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: colors.onSurface,
                    ),
                  ),
                  const Spacer(),
                  if (onToggleFullscreen != null) ...[
                    _ChartCardFullscreenButton(
                      isFullscreen: isFullscreen,
                      onToggle: onToggleFullscreen!,
                    ),
                    const SizedBox(width: 4),
                  ],
                  if (onClose != null) _ChartCardCloseButton(onClose: onClose!),
                ],
              ),
              const SizedBox(height: 6),
              // Physical Memory
              Row(
                children: [
                  const Text(
                    '物理内存 (Mem)',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 11),
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
              const SizedBox(height: 3),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: stats.memUsageRatio,
                  backgroundColor: colors.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation<Color>(memColor),
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: 3),
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
                const SizedBox(height: 6),
                // Swap
                Row(
                  children: [
                    const Text(
                      '交换空间 (Swap)',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 11),
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
                const SizedBox(height: 3),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: stats.swapUsageRatio,
                    backgroundColor: colors.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      stats.swapUsageRatio > 0.5 ? colors.error : const Color(0xFF55A9E8),
                    ),
                    minHeight: 6,
                  ),
                ),
                const SizedBox(height: 3),
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
      ),
    );
  }
}

/// A card rendering the parsed `docker ps` container information
class TerminalDockerPsChartWidget extends StatelessWidget {
  const TerminalDockerPsChartWidget({
    required this.entries,
    required this.onClose,
    this.maxHeight,
    this.isFullscreen = false,
    this.onToggleFullscreen,
    super.key,
  });

  final List<DockerContainerEntry> entries;
  final VoidCallback? onClose;
  final double? maxHeight;
  final bool isFullscreen;
  final VoidCallback? onToggleFullscreen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final runningCount = entries.where((e) => e.isRunning).length;
    final listMaxHeight = maxHeight != null
        ? (maxHeight! - 48.0).clamp(40.0, 2000.0)
        : 280.0;

    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.6)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.directions_boat_rounded, size: 15, color: colors.primary),
                const SizedBox(width: 6),
                Text(
                  'Docker 容器 (docker ps)',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: colors.onSurface,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF31C48D).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '运行中: $runningCount / ${entries.length}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF31C48D),
                    ),
                  ),
                ),
                if (onToggleFullscreen != null) ...[
                  const SizedBox(width: 6),
                  _ChartCardFullscreenButton(
                    isFullscreen: isFullscreen,
                    onToggle: onToggleFullscreen!,
                  ),
                ],
                if (onClose != null) ...[
                  const SizedBox(width: 4),
                  _ChartCardCloseButton(onClose: onClose!),
                ],
              ],
            ),
            const SizedBox(height: 6),
            if (entries.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  '当前没有运行中的容器',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: listMaxHeight),
                child: SingleChildScrollView(
                  child: Column(
                    children: entries.map((e) => _buildContainerRow(context, e)).toList(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildContainerRow(BuildContext context, DockerContainerEntry entry) {
    final colors = Theme.of(context).colorScheme;
    final isUp = entry.isRunning;
    final statusColor = isUp ? const Color(0xFF31C48D) : colors.error;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: statusColor,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                flex: 3,
                child: Text(
                  isFullscreen && entry.names.isNotEmpty
                      ? '${entry.names}  (${entry.containerId})'
                      : (entry.names.isNotEmpty ? entry.names : entry.containerId),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                  overflow: isFullscreen ? TextOverflow.visible : TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                flex: 2,
                child: Text(
                  entry.image,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.right,
                  overflow: isFullscreen ? TextOverflow.visible : TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 2,
                child: Text(
                  isFullscreen && entry.created.isNotEmpty
                      ? '${entry.status} · 创建于 ${entry.created}'
                      : entry.status,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: isUp ? colors.onSurface : colors.error,
                  ),
                  overflow: isFullscreen ? TextOverflow.visible : TextOverflow.ellipsis,
                ),
              ),
              if (entry.ports.isNotEmpty) ...[
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: Text(
                    entry.ports,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: colors.primary,
                    ),
                    textAlign: TextAlign.right,
                    overflow: isFullscreen ? TextOverflow.visible : TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
          if (isFullscreen && entry.command.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              '启动命令: ${entry.command}',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                color: colors.onSurfaceVariant.withValues(alpha: 0.85),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Fullscreen / Compact toggle button inside chart card headers
class _ChartCardFullscreenButton extends StatelessWidget {
  const _ChartCardFullscreenButton({
    required this.isFullscreen,
    required this.onToggle,
  });

  final bool isFullscreen;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(4),
      child: Tooltip(
        message: isFullscreen ? '收起为紧凑视图' : '展开全屏查看完整信息',
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(
            isFullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
            size: 15,
            color: colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Close / Switch-to-raw button inside chart card headers
class _ChartCardCloseButton extends StatelessWidget {
  const _ChartCardCloseButton({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onClose,
      borderRadius: BorderRadius.circular(4),
      child: Tooltip(
        message: '切回原始输出 (Raw) [ESC]',
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(
            Icons.close_rounded,
            size: 15,
            color: colors.onSurfaceVariant,
          ),
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
