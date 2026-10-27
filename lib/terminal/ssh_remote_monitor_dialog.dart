import 'dart:async';

import 'package:flutter/material.dart';

import 'ssh_remote_monitor.dart';
import 'ssh_remote_monitor_cache.dart';

class SshRemoteMonitorDialog extends StatefulWidget {
  const SshRemoteMonitorDialog({
    super.key,
    required this.cache,
    required this.sessionTitle,
  });

  final SshRemoteMonitorCache cache;
  final String sessionTitle;

  @override
  State<SshRemoteMonitorDialog> createState() => _SshRemoteMonitorDialogState();
}

class _SshRemoteMonitorDialogState extends State<SshRemoteMonitorDialog> {
  @override
  void initState() {
    super.initState();
    widget.cache.addListener(_onCacheChanged);
    unawaited(_sample());
  }

  @override
  void didUpdateWidget(SshRemoteMonitorDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cache != widget.cache) {
      oldWidget.cache.removeListener(_onCacheChanged);
      widget.cache.addListener(_onCacheChanged);
      unawaited(_sample());
    }
  }

  @override
  void dispose() {
    widget.cache.removeListener(_onCacheChanged);
    super.dispose();
  }

  void _onCacheChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _sample() async {
    await widget.cache.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final cache = widget.cache;
    final metrics = cache.metrics;
    final error = cache.error;
    final trafficRate = cache.trafficRate;
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.monitor_heart_outlined, color: colors.primary),
          const SizedBox(width: 10),
          const Expanded(child: Text('远程监控')),
          IconButton(
            tooltip: '立即刷新',
            onPressed: cache.isSampling ? null : () => unawaited(_sample()),
            icon: cache.isSampling
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      content: SizedBox(
        width: 620,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 560),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${widget.sessionTitle} · Linux · 只读 · 每 5 秒采样',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  _NoticeCard(
                    icon: Icons.info_outline_rounded,
                    text: error,
                    isError: metrics == null,
                  ),
                ],
                if (metrics == null) ...[
                  const SizedBox(height: 28),
                  Center(
                    child: cache.isSampling
                        ? const CircularProgressIndicator()
                        : FilledButton.icon(
                            onPressed: () => unawaited(_sample()),
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('重新采集'),
                          ),
                  ),
                ] else ...[
                  const SizedBox(height: 14),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final cardWidth = constraints.maxWidth < 296
                          ? constraints.maxWidth
                          : 296.0;
                      return Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          _MetricCard(
                            width: cardWidth,
                            title: '系统负载',
                            icon: Icons.speed_rounded,
                            value: metrics.load1 == null
                                ? '不可用'
                                : metrics.load1!.toStringAsFixed(2),
                            detail: metrics.load1 == null
                                ? '内核未返回负载数据'
                                : '1 分钟 · ${metrics.load5?.toStringAsFixed(2) ?? '—'} / '
                                      '${metrics.load15?.toStringAsFixed(2) ?? '—'}（5 / 15 分钟）',
                            trend: _sparkline(
                              cache.history.map((m) => m.load1).toList(),
                            ),
                          ),
                          _MetricCard(
                            width: cardWidth,
                            title: '内存',
                            icon: Icons.memory_rounded,
                            value: _memoryValue(metrics),
                            detail: metrics.memoryUsedPercent == null
                                ? '不可用'
                                : '${metrics.memoryUsedPercent!.toStringAsFixed(1)}% 已使用',
                            progress: metrics.memoryUsedPercent == null
                                ? null
                                : metrics.memoryUsedPercent! / 100,
                            trend: _sparkline(
                              cache.history
                                  .map((m) => m.memoryUsedPercent)
                                  .toList(),
                            ),
                          ),
                          _MetricCard(
                            width: cardWidth,
                            title: '根文件系统 /',
                            icon: Icons.storage_rounded,
                            value: _diskValue(metrics),
                            detail: metrics.diskPercent == null
                                ? '不可用'
                                : '${metrics.diskPercent}% 已使用',
                            progress: metrics.diskPercent == null
                                ? null
                                : metrics.diskPercent! / 100,
                            trend: _sparkline(
                              cache.history
                                  .map((m) => m.diskPercent?.toDouble())
                                  .toList(),
                            ),
                          ),
                          if (metrics.networkReceivedBytes != null) ...[
                            _MetricCard(
                              width: cardWidth,
                              title: '网络接收',
                              icon: Icons.south_rounded,
                              value: _formatRate(
                                trafficRate?.receivedBytesPerSecond,
                              ),
                              detail: '所有非 lo 接口 · RX',
                              trend: _sparkline(cache.receiveRates),
                            ),
                            _MetricCard(
                              width: cardWidth,
                              title: '网络发送',
                              icon: Icons.north_rounded,
                              value: _formatRate(
                                trafficRate?.transmittedBytesPerSecond,
                              ),
                              detail: '所有非 lo 接口 · TX',
                              trend: _sparkline(cache.transmitRates),
                            ),
                          ],
                          _MetricCard(
                            width: cardWidth,
                            title: '进程',
                            icon: Icons.account_tree_outlined,
                            value: metrics.processCount?.toString() ?? '不可用',
                            detail: '采样于 ${_formatTime(metrics.sampledAt)}',
                          ),
                        ],
                      );
                    },
                  ),
                  if (metrics.topProcesses.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Text(
                      'CPU 使用较高的进程',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 6),
                    ...metrics.topProcesses.map(
                      (process) => _ProcessRow(process: process),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Text(
                    '趋势共享底部监控栏的数据，保留最近 2 分钟；关闭 SSH 标签后清除。网络速度统计所有非 lo 接口，虚拟网桥可能造成重复计数。负载值需结合远端 CPU 核心数判断。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  String _memoryValue(SshRemoteMetrics metrics) {
    final used = metrics.memoryUsedKiB;
    final total = metrics.memoryTotalKiB;
    if (used == null || total == null) return '不可用';
    return '${_formatBytes(used * 1024)} / ${_formatBytes(total * 1024)}';
  }

  String _diskValue(SshRemoteMetrics metrics) {
    final used = metrics.diskUsedKiB;
    final total = metrics.diskTotalKiB;
    if (used == null || total == null) return '不可用';
    return '${_formatBytes(used * 1024)} / ${_formatBytes(total * 1024)}';
  }

  String _sparkline(List<double?> values) {
    const bars = '▁▂▃▄▅▆▇█';
    final valid = values.whereType<double>().toList();
    if (valid.length < 2) return '采集中';
    final minimum = valid.reduce((a, b) => a < b ? a : b);
    final maximum = valid.reduce((a, b) => a > b ? a : b);
    final range = maximum - minimum;
    return values.whereType<double>().map((value) {
      final level = range == 0
          ? 0
          : (((value - minimum) / range) * (bars.length - 1)).round();
      return bars[level];
    }).join();
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.width,
    required this.title,
    required this.icon,
    required this.value,
    required this.detail,
    this.progress,
    this.trend,
  });

  final double width;
  final String title;
  final IconData icon;
  final String value;
  final String detail;
  final double? progress;
  final String? trend;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: colors.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 18, color: colors.primary),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
              if (progress != null) ...[
                const SizedBox(height: 9),
                ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: LinearProgressIndicator(
                    value: progress!.clamp(0.0, 1.0),
                    minHeight: 5,
                  ),
                ),
              ],
              if (trend != null) ...[
                const SizedBox(height: 8),
                Text(
                  trend!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: colors.primary,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ProcessRow extends StatelessWidget {
  const _ProcessRow({required this.process});

  final SshRemoteProcessMetric process;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 58,
            child: Text(
              '${process.pid}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              process.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 106,
            child: Text(
              '${process.cpuPercent.toStringAsFixed(1)}% CPU',
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          SizedBox(
            width: 106,
            child: Text(
              '${process.memoryPercent.toStringAsFixed(1)}% MEM',
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.icon,
    required this.text,
    required this.isError,
  });

  final IconData icon;
  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = isError ? colors.error : colors.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isError ? colors.errorContainer : colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: foreground),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: isError ? colors.onErrorContainer : foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MiB';
  }
  return '${(bytes / 1024).toStringAsFixed(0)} KiB';
}

String _formatRate(double? bytesPerSecond) {
  if (bytesPerSecond == null) return '采集中';
  if (bytesPerSecond >= 1024 * 1024 * 1024) {
    return '${(bytesPerSecond / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB/s';
  }
  if (bytesPerSecond >= 1024 * 1024) {
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MiB/s';
  }
  if (bytesPerSecond >= 1024) {
    return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KiB/s';
  }
  return '${bytesPerSecond.toStringAsFixed(0)} B/s';
}

String _formatTime(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}:${value.second.toString().padLeft(2, '0')}';
