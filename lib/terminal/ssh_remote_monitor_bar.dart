import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';

import 'ssh_remote_monitor.dart';
import 'ssh_remote_monitor_cache.dart';

/// Compact, single-line remote metrics strip for the active SSH session.
class SshRemoteMonitorBar extends StatefulWidget {
  const SshRemoteMonitorBar({
    super.key,
    required this.client,
    required this.cache,
    required this.sessionTitle,
    required this.onOpenDetails,
  });

  final SSHClient? client;
  final SshRemoteMonitorCache cache;
  final String sessionTitle;
  final VoidCallback onOpenDetails;

  @override
  State<SshRemoteMonitorBar> createState() => _SshRemoteMonitorBarState();
}

class _SshRemoteMonitorBarState extends State<SshRemoteMonitorBar> {
  @override
  void initState() {
    super.initState();
    widget.cache.watch(widget.client);
  }

  @override
  void didUpdateWidget(SshRemoteMonitorBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cache != widget.cache) {
      oldWidget.cache.unwatch(oldWidget.client);
      widget.cache.watch(widget.client);
    } else if (oldWidget.client != widget.client) {
      widget.cache.watch(widget.client);
    }
  }

  @override
  void dispose() {
    widget.cache.unwatch(widget.client);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      child: SizedBox(
        height: 38,
        child: InkWell(
          onTap: widget.client == null ? null : widget.onOpenDetails,
          child: Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: colors.outlineVariant)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: ListenableBuilder(
              listenable: widget.cache,
              builder: (context, _) {
                final metrics = widget.client == null
                    ? null
                    : widget.cache.metrics;
                final error = widget.client == null ? null : widget.cache.error;
                final isSampling =
                    widget.client != null && widget.cache.isSampling;
                final label = widget.client == null
                    ? 'SSH 尚未连接'
                    : error != null && metrics == null
                    ? '监控采集失败'
                    : metrics == null
                    ? '正在读取远端指标…'
                    : widget.sessionTitle;
                return Row(
                  children: [
                    Icon(
                      Icons.monitor_heart_outlined,
                      size: 17,
                      color: widget.client == null
                          ? colors.onSurfaceVariant
                          : colors.primary,
                    ),
                    const SizedBox(width: 7),
                    SizedBox(
                      width: 118,
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                    const SizedBox(width: 10),
                    VerticalDivider(
                      width: 1,
                      indent: 9,
                      endIndent: 9,
                      color: colors.outlineVariant,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: metrics == null
                              ? [
                                  Tooltip(
                                    message: error ?? label,
                                    child: Text(
                                      error != null && widget.client != null
                                          ? error
                                          : isSampling
                                          ? '采样中…'
                                          : '等待数据',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: error == null
                                                ? colors.onSurfaceVariant
                                                : colors.error,
                                          ),
                                    ),
                                  ),
                                ]
                              : [
                                  if (metrics.platform ==
                                      SshRemotePlatform.windows)
                                    _MonitorMetric(
                                      icon: Icons.speed_rounded,
                                      label: 'CPU',
                                      value: metrics.cpuPercent == null
                                          ? '—'
                                          : '${metrics.cpuPercent!.toStringAsFixed(1)}%',
                                    )
                                  else
                                    _MonitorMetric(
                                      icon: Icons.speed_rounded,
                                      label: '负载',
                                      value:
                                          metrics.load1?.toStringAsFixed(2) ??
                                          '—',
                                    ),
                                  _MonitorMetric(
                                    icon: Icons.memory_rounded,
                                    label: '内存',
                                    value: metrics.memoryUsedPercent == null
                                        ? '—'
                                        : '${metrics.memoryUsedPercent!.toStringAsFixed(1)}%',
                                  ),
                                  _MonitorMetric(
                                    icon: Icons.storage_rounded,
                                    label:
                                        metrics.platform ==
                                            SshRemotePlatform.windows
                                        ? '系统盘'
                                        : '根盘',
                                    value: metrics.diskPercent == null
                                        ? '—'
                                        : '${metrics.diskPercent}%',
                                  ),
                                  if (metrics.networkReceivedBytes != null) ...[
                                    _MonitorMetric(
                                      icon: Icons.south_rounded,
                                      label: '收',
                                      value: _formatRate(
                                        widget
                                            .cache
                                            .trafficRate
                                            ?.receivedBytesPerSecond,
                                      ),
                                    ),
                                    _MonitorMetric(
                                      icon: Icons.north_rounded,
                                      label: '发',
                                      value: _formatRate(
                                        widget
                                            .cache
                                            .trafficRate
                                            ?.transmittedBytesPerSecond,
                                      ),
                                    ),
                                  ],
                                  _MonitorMetric(
                                    icon: Icons.account_tree_outlined,
                                    label: '进程',
                                    value:
                                        metrics.processCount?.toString() ?? '—',
                                  ),
                                  const SizedBox(width: 14),
                                  Text(
                                    '更新于 ${_formatTime(metrics.sampledAt)}',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: colors.onSurfaceVariant,
                                        ),
                                  ),
                                ],
                        ),
                      ),
                    ),
                    if (isSampling) ...[
                      const SizedBox(width: 8),
                      SizedBox.square(
                        dimension: 13,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.7,
                          color: colors.primary,
                        ),
                      ),
                    ],
                    const SizedBox(width: 7),
                    Tooltip(
                      message: '打开详细远程监控',
                      child: Icon(
                        Icons.open_in_full_rounded,
                        size: 15,
                        color: widget.client == null
                            ? colors.onSurfaceVariant
                            : colors.primary,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _MonitorMetric extends StatelessWidget {
  const _MonitorMetric({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 18),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: colors.onSurfaceVariant),
          const SizedBox(width: 5),
          Text(
            '$label $value',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

String _formatTime(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}:${value.second.toString().padLeft(2, '0')}';

String _formatRate(double? bytesPerSecond) {
  if (bytesPerSecond == null) return '—';
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
