import 'dart:convert';
import 'dart:typed_data';

const maxComparableFileBytes = 2 * 1024 * 1024;
const _maxComparableLines = 1200;
const _maxDiffCells = 900000;

enum FileComparisonStatus {
  identical,
  formattingOnly,
  textDifferent,
  binaryDifferent,
  tooComplex,
}

class FileComparisonRow {
  const FileComparisonRow({
    required this.leftLine,
    required this.rightLine,
    required this.leftLineNumber,
    required this.rightLineNumber,
    required this.isDifferent,
  });

  final String? leftLine;
  final String? rightLine;
  final int? leftLineNumber;
  final int? rightLineNumber;
  final bool isDifferent;
}

class FileComparison {
  const FileComparison({
    required this.status,
    required this.leftBytes,
    required this.rightBytes,
    this.leftLines = 0,
    this.rightLines = 0,
    this.rows = const [],
  });

  final FileComparisonStatus status;
  final int leftBytes;
  final int rightBytes;
  final int leftLines;
  final int rightLines;
  final List<FileComparisonRow> rows;
}

FileComparison compareFileContents(Uint8List left, Uint8List right) {
  if (_bytesEqual(left, right)) {
    return FileComparison(
      status: FileComparisonStatus.identical,
      leftBytes: left.length,
      rightBytes: right.length,
    );
  }

  late final String leftText;
  late final String rightText;
  try {
    leftText = utf8.decode(left);
    rightText = utf8.decode(right);
  } on FormatException {
    return FileComparison(
      status: FileComparisonStatus.binaryDifferent,
      leftBytes: left.length,
      rightBytes: right.length,
    );
  }
  if (left.contains(0) || right.contains(0)) {
    return FileComparison(
      status: FileComparisonStatus.binaryDifferent,
      leftBytes: left.length,
      rightBytes: right.length,
    );
  }

  final normalizedLeft = _normalizeLineEndings(leftText);
  final normalizedRight = _normalizeLineEndings(rightText);
  final leftLineCount = _countLines(normalizedLeft);
  final rightLineCount = _countLines(normalizedRight);
  if (leftLineCount > _maxComparableLines ||
      rightLineCount > _maxComparableLines ||
      leftLineCount * rightLineCount > _maxDiffCells) {
    return FileComparison(
      status: FileComparisonStatus.tooComplex,
      leftBytes: left.length,
      rightBytes: right.length,
      leftLines: leftLineCount,
      rightLines: rightLineCount,
    );
  }
  final leftLines = normalizedLeft.split('\n');
  final rightLines = normalizedRight.split('\n');

  final rows = _alignLines(leftLines, rightLines);
  final hasTextChanges = rows.any((row) => row.isDifferent);
  return FileComparison(
    status: hasTextChanges
        ? FileComparisonStatus.textDifferent
        : FileComparisonStatus.formattingOnly,
    leftBytes: left.length,
    rightBytes: right.length,
    leftLines: leftLines.length,
    rightLines: rightLines.length,
    rows: rows,
  );
}

bool _bytesEqual(Uint8List left, Uint8List right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

String _normalizeLineEndings(String text) =>
    text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

int _countLines(String text) {
  var count = 1;
  for (var index = 0; index < text.length; index++) {
    if (text.codeUnitAt(index) == 0x0a) count++;
  }
  return count;
}

List<FileComparisonRow> _alignLines(List<String> left, List<String> right) {
  final columns = right.length + 1;
  final lcs = Uint16List((left.length + 1) * columns);
  for (var leftIndex = left.length - 1; leftIndex >= 0; leftIndex--) {
    final row = leftIndex * columns;
    final nextRow = (leftIndex + 1) * columns;
    for (var rightIndex = right.length - 1; rightIndex >= 0; rightIndex--) {
      final index = row + rightIndex;
      if (left[leftIndex] == right[rightIndex]) {
        lcs[index] = lcs[nextRow + rightIndex + 1] + 1;
      } else {
        final skipLeft = lcs[nextRow + rightIndex];
        final skipRight = lcs[index + 1];
        lcs[index] = skipLeft >= skipRight ? skipLeft : skipRight;
      }
    }
  }

  final rows = <FileComparisonRow>[];
  var leftIndex = 0;
  var rightIndex = 0;
  while (leftIndex < left.length || rightIndex < right.length) {
    if (leftIndex < left.length &&
        rightIndex < right.length &&
        left[leftIndex] == right[rightIndex]) {
      rows.add(
        FileComparisonRow(
          leftLine: left[leftIndex],
          rightLine: right[rightIndex],
          leftLineNumber: leftIndex + 1,
          rightLineNumber: rightIndex + 1,
          isDifferent: false,
        ),
      );
      leftIndex++;
      rightIndex++;
      continue;
    }

    final matrixIndex = leftIndex * columns + rightIndex;
    final skipLeft = leftIndex < left.length
        ? lcs[(leftIndex + 1) * columns + rightIndex]
        : -1;
    final skipRight = rightIndex < right.length ? lcs[matrixIndex + 1] : -1;
    if (leftIndex < left.length &&
        (rightIndex >= right.length || skipLeft >= skipRight)) {
      rows.add(
        FileComparisonRow(
          leftLine: left[leftIndex],
          rightLine: null,
          leftLineNumber: leftIndex + 1,
          rightLineNumber: null,
          isDifferent: true,
        ),
      );
      leftIndex++;
    } else {
      rows.add(
        FileComparisonRow(
          leftLine: null,
          rightLine: right[rightIndex],
          leftLineNumber: null,
          rightLineNumber: rightIndex + 1,
          isDifferent: true,
        ),
      );
      rightIndex++;
    }
  }
  return rows;
}
