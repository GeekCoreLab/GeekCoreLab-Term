import 'package:flutter/material.dart';
import 'package:geekcore_term/terminal/directory_comparison.dart';

class DirectoryComparisonDialog extends StatefulWidget {
  const DirectoryComparisonDialog({
    required this.localRoot,
    required this.remoteRoot,
    required this.comparison,
    super.key,
  });

  final String localRoot;
  final String remoteRoot;
  final DirectoryComparison comparison;

  @override
  State<DirectoryComparisonDialog> createState() =>
      _DirectoryComparisonDialogState();
}

class _DirectoryComparisonDialogState extends State<DirectoryComparisonDialog> {
  bool _showOnlyDifferences = true;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final compact = screen.width < 680;
    final colors = Theme.of(context).colorScheme;
    final width = (screen.width - (compact ? 0 : 64)).clamp(280.0, 900.0);
    final height = (screen.height - (compact ? 0 : 64)).clamp(320.0, 820.0);
    final visibleEntries = widget.comparison.entries
        .where(
          (entry) =>
              !_showOnlyDifferences ||
              entry.kind != DirectoryComparisonKind.metadataMatches,
        )
        .toList(growable: false);

    return Dialog(
      clipBehavior: Clip.antiAlias,
      insetPadding: EdgeInsets.all(compact ? 0 : 32),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(compact ? 14 : 22, 14, 8, 10),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.folder_copy_rounded,
                      color: colors.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      '目录比较',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: compact ? 14 : 22),
              child: Column(
                children: [
                  _rootCard(
                    '本地',
                    widget.localRoot,
                    Icons.computer_rounded,
                    colors,
                  ),
                  const SizedBox(height: 6),
                  _rootCard('远端', widget.remoteRoot, Icons.dns_rounded, colors),
                ],
              ),
            ),
            const SizedBox(height: 10),
            _summary(colors),
            if (!widget.comparison.isComplete)
              Container(
                width: double.infinity,
                margin: EdgeInsets.fromLTRB(
                  compact ? 14 : 22,
                  8,
                  compact ? 14 : 22,
                  0,
                ),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colors.tertiaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '扫描已达到安全上限，当前结果不包含整棵目录树。请缩小比较范围后重试。',
                  style: TextStyle(
                    color: colors.onTertiaryContainer,
                    fontSize: 12,
                  ),
                ),
              ),
            if (!widget.comparison.isSnapshotStable)
              Container(
                width: double.infinity,
                margin: EdgeInsets.fromLTRB(
                  compact ? 14 : 22,
                  8,
                  compact ? 14 : 22,
                  0,
                ),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '远端部分目录未提供修改时间，无法确认扫描期间列表未变化；结果只代表本次读取到的元数据。',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 14 : 22,
                8,
                compact ? 14 : 22,
                8,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      '只比较相对路径、类型、大小和修改时间，不读取文件内容、不修改或同步文件。元数据相同不代表内容字节相同。',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.outlineVariant),
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 12 : 18,
                6,
                compact ? 12 : 18,
                2,
              ),
              child: Row(
                children: [
                  Text(
                    '${widget.comparison.entries.length} 项有结果',
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                  const Spacer(),
                  FilterChip(
                    label: const Text('仅显示差异'),
                    selected: _showOnlyDifferences,
                    onSelected: (value) =>
                        setState(() => _showOnlyDifferences = value),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
            Expanded(
              child: visibleEntries.isEmpty
                  ? _emptyState(colors)
                  : ListView.separated(
                      padding: EdgeInsets.fromLTRB(
                        compact ? 12 : 18,
                        4,
                        compact ? 12 : 18,
                        10,
                      ),
                      itemCount: visibleEntries.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 3),
                      itemBuilder: (context, index) =>
                          _entryRow(visibleEntries.elementAt(index), colors),
                    ),
            ),
            Divider(height: 1, color: colors.outlineVariant),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 7, 16, 9),
              child: Row(
                children: [
                  Icon(
                    widget.comparison.hasDifferences
                        ? Icons.compare_arrows_rounded
                        : Icons.check_circle_outline_rounded,
                    size: 16,
                    color: widget.comparison.hasDifferences
                        ? colors.tertiary
                        : colors.primary,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      '本地 ${widget.comparison.localItemCount} 项 · 远端 ${widget.comparison.remoteItemCount} 项',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('完成'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rootCard(
    String label,
    String path,
    IconData icon,
    ColorScheme colors,
  ) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: colors.outlineVariant),
    ),
    child: Row(
      children: [
        Icon(icon, size: 16, color: colors.primary),
        const SizedBox(width: 8),
        SizedBox(
          width: 38,
          child: Text(
            label,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(
          child: Text(
            path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 11),
          ),
        ),
      ],
    ),
  );

  Widget _summary(ColorScheme colors) {
    final counts = <(String, DirectoryComparisonKind, Color)>[
      ('仅本地', DirectoryComparisonKind.onlyLocal, colors.error),
      ('仅远端', DirectoryComparisonKind.onlyRemote, colors.tertiary),
      ('元数据不同', DirectoryComparisonKind.sizeDifferent, colors.error),
      ('修改时间不同', DirectoryComparisonKind.modifiedDifferent, colors.error),
      ('元数据一致', DirectoryComparisonKind.metadataMatches, colors.primary),
    ];
    final typeAndSafetyCount =
        widget.comparison.count(DirectoryComparisonKind.typeDifferent) +
        widget.comparison.count(DirectoryComparisonKind.symbolicLink) +
        widget.comparison.count(DirectoryComparisonKind.metadataUnavailable) +
        widget.comparison.count(DirectoryComparisonKind.unsupportedType);
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: MediaQuery.sizeOf(context).width < 680 ? 12 : 20,
      ),
      child: Wrap(
        spacing: 7,
        runSpacing: 5,
        children: [
          for (final (label, kind, color) in counts)
            _countPill(label, widget.comparison.count(kind), color),
          _countPill('类型/元数据待确认', typeAndSafetyCount, colors.onSurfaceVariant),
        ],
      ),
    );
  }

  Widget _countPill(String label, int count, Color tone) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: tone.withValues(alpha: 0.09),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      '$label $count',
      style: TextStyle(color: tone, fontSize: 10, fontWeight: FontWeight.w600),
    ),
  );

  Widget _entryRow(DirectoryComparisonEntry entry, ColorScheme colors) {
    final (label, icon, tone) = _presentation(entry.kind, colors);
    final isFolder =
        entry.local?.type == DirectoryComparisonItemType.directory ||
        entry.remote?.type == DirectoryComparisonItemType.directory;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: [
          Icon(
            isFolder ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
            size: 17,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.relativePath,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  _metadataLabel(entry),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(icon, size: 15, color: tone),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: tone,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  (String, IconData, Color) _presentation(
    DirectoryComparisonKind kind,
    ColorScheme colors,
  ) => switch (kind) {
    DirectoryComparisonKind.onlyLocal => (
      '仅本地',
      Icons.upload_rounded,
      colors.error,
    ),
    DirectoryComparisonKind.onlyRemote => (
      '仅远端',
      Icons.download_rounded,
      colors.tertiary,
    ),
    DirectoryComparisonKind.typeDifferent => (
      '类型不同',
      Icons.swap_horiz_rounded,
      colors.error,
    ),
    DirectoryComparisonKind.sizeDifferent => (
      '大小不同',
      Icons.data_usage_rounded,
      colors.error,
    ),
    DirectoryComparisonKind.modifiedDifferent => (
      '时间不同',
      Icons.schedule_rounded,
      colors.error,
    ),
    DirectoryComparisonKind.metadataMatches => (
      '元数据一致',
      Icons.check_rounded,
      colors.primary,
    ),
    DirectoryComparisonKind.metadataUnavailable => (
      '元数据不完整',
      Icons.help_outline_rounded,
      colors.onSurfaceVariant,
    ),
    DirectoryComparisonKind.symbolicLink => (
      '符号链接未跟随',
      Icons.link_rounded,
      colors.onSurfaceVariant,
    ),
    DirectoryComparisonKind.unsupportedType => (
      '特殊类型',
      Icons.block_rounded,
      colors.onSurfaceVariant,
    ),
  };

  String _metadataLabel(DirectoryComparisonEntry entry) {
    String item(DirectoryComparisonSnapshot? snapshot) {
      if (snapshot == null) return '—';
      if (snapshot.type == DirectoryComparisonItemType.directory) return '目录';
      if (snapshot.type == DirectoryComparisonItemType.symbolicLink) {
        return '符号链接';
      }
      if (snapshot.type != DirectoryComparisonItemType.file) return '特殊文件';
      final size = snapshot.size == null
          ? '大小未知'
          : _formatBytes(snapshot.size!);
      final modified = snapshot.modifiedAtMillis == null
          ? '时间未知'
          : DateTime.fromMillisecondsSinceEpoch(
              snapshot.modifiedAtMillis!,
            ).toLocal().toString().substring(0, 16);
      return '$size · $modified';
    }

    return '本地 ${item(entry.local)}  |  远端 ${item(entry.remote)}';
  }

  Widget _emptyState(ColorScheme colors) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.check_circle_outline_rounded,
            size: 34,
            color: colors.primary,
          ),
          const SizedBox(height: 9),
          Text(
            _showOnlyDifferences ? '没有发现元数据差异' : '目录树为空',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 5),
          Text(
            '文件内容未读取；元数据相同不能证明文件内容一致。',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 11),
          ),
        ],
      ),
    ),
  );

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
