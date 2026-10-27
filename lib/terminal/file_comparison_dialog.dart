import 'package:flutter/material.dart';
import 'package:geekcore_term/terminal/file_comparison.dart';

class FileComparisonDialog extends StatelessWidget {
  const FileComparisonDialog({
    required this.leftName,
    required this.leftPath,
    required this.rightName,
    required this.rightPath,
    required this.comparison,
    super.key,
  });

  final String leftName;
  final String leftPath;
  final String rightName;
  final String rightPath;
  final FileComparison comparison;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final compact = screen.width < 700;
    final colors = Theme.of(context).colorScheme;
    final width = (screen.width - (compact ? 0 : 64)).clamp(340.0, 1160.0);
    final height = (screen.height - (compact ? 0 : 64)).clamp(320.0, 840.0);
    final (title, tone, icon) = _statusPresentation(colors);

    return Dialog(
      clipBehavior: Clip.antiAlias,
      insetPadding: EdgeInsets.all(compact ? 0 : 32),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(compact ? 14 : 22, 16, 8, 12),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: tone.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(Icons.compare_arrows_rounded, color: tone),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '文件比较',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        Text(
                          title,
                          style: TextStyle(color: tone, fontSize: 12),
                        ),
                      ],
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
              child: Row(
                children: [
                  Expanded(child: _fileHeading(leftName, leftPath, colors)),
                  const SizedBox(width: 12),
                  Expanded(child: _fileHeading(rightName, rightPath, colors)),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Divider(height: 1, color: colors.outlineVariant),
            Expanded(child: _buildBody(colors, tone)),
            Divider(height: 1, color: colors.outlineVariant),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
              child: Row(
                children: [
                  Icon(icon, size: 16, color: tone),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      '${_formatBytes(comparison.leftBytes)} 与 ${_formatBytes(comparison.rightBytes)}',
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

  Widget _fileHeading(String name, String path, ColorScheme colors) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
            ),
            const SizedBox(height: 2),
            Text(
              path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 10),
            ),
          ],
        ),
      );

  Widget _buildBody(ColorScheme colors, Color tone) {
    switch (comparison.status) {
      case FileComparisonStatus.identical:
        return _message(
          colors: colors,
          icon: Icons.check_circle_outline_rounded,
          title: '两个文件逐字节一致',
          detail: '文件内容和换行格式完全相同。',
        );
      case FileComparisonStatus.formattingOnly:
        return _message(
          colors: colors,
          icon: Icons.check_circle_outline_rounded,
          title: '文本内容一致',
          detail: '文本行相同，但文件字节不同，通常是换行格式不同。',
        );
      case FileComparisonStatus.binaryDifferent:
        return _message(
          colors: colors,
          icon: Icons.data_object_rounded,
          title: '文件内容不同，无法按 UTF-8 文本比较',
          detail: '检测到二进制内容或无效 UTF-8。比较过程只读取文件，没有写入或覆盖。',
        );
      case FileComparisonStatus.tooComplex:
        return _message(
          colors: colors,
          icon: Icons.speed_rounded,
          title: '文本文件较大，跳过逐行差异计算',
          detail: '每个文件最多比较 1200 行，差异矩阵最多处理 900000 个单元。文件大小仍显示在底部。',
        );
      case FileComparisonStatus.textDifferent:
        return ListView.builder(
          itemCount: comparison.rows.length,
          itemBuilder: (context, index) =>
              _diffRow(comparison.rows[index], colors, tone),
        );
    }
  }

  Widget _diffRow(FileComparisonRow row, ColorScheme colors, Color tone) {
    final deleted = row.leftLine != null && row.rightLine == null;
    final added = row.leftLine == null && row.rightLine != null;
    final leftColor = deleted
        ? colors.errorContainer.withValues(alpha: 0.65)
        : row.isDifferent
        ? colors.surfaceContainerLow
        : Colors.transparent;
    final rightColor = added
        ? colors.tertiaryContainer.withValues(alpha: 0.65)
        : row.isDifferent
        ? colors.surfaceContainerLow
        : Colors.transparent;
    return SizedBox(
      height: 34,
      child: Row(
        children: [
          Expanded(
            child: _lineCell(
              lineNumber: row.leftLineNumber,
              text: row.leftLine,
              background: leftColor,
              colors: colors,
            ),
          ),
          Container(width: 1, color: colors.outlineVariant),
          Expanded(
            child: _lineCell(
              lineNumber: row.rightLineNumber,
              text: row.rightLine,
              background: rightColor,
              colors: colors,
            ),
          ),
        ],
      ),
    );
  }

  Widget _lineCell({
    required int? lineNumber,
    required String? text,
    required Color background,
    required ColorScheme colors,
  }) => Container(
    color: background,
    padding: const EdgeInsets.symmetric(horizontal: 7),
    child: Row(
      children: [
        SizedBox(
          width: 34,
          child: Text(
            lineNumber?.toString() ?? '',
            textAlign: TextAlign.right,
            style: TextStyle(color: colors.outline, fontSize: 10),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        ),
      ],
    ),
  );

  Widget _message({
    required ColorScheme colors,
    required IconData icon,
    required String title,
    required String detail,
  }) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 42, color: colors.primary),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
    ),
  );

  (String, Color, IconData) _statusPresentation(ColorScheme colors) =>
      switch (comparison.status) {
        FileComparisonStatus.identical => (
          '完全一致',
          colors.tertiary,
          Icons.check_circle_rounded,
        ),
        FileComparisonStatus.formattingOnly => (
          '文本行相同，编码或换行不同',
          colors.tertiary,
          Icons.info_outline_rounded,
        ),
        FileComparisonStatus.textDifferent => (
          '${comparison.leftLines} 行对 ${comparison.rightLines} 行',
          colors.primary,
          Icons.compare_arrows_rounded,
        ),
        FileComparisonStatus.binaryDifferent => (
          '二进制或非 UTF-8 文件',
          colors.error,
          Icons.data_object_rounded,
        ),
        FileComparisonStatus.tooComplex => (
          '超过逐行比较上限',
          colors.error,
          Icons.speed_rounded,
        ),
      };

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
