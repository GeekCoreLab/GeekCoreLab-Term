import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

const _maxWrappedLinkRows = 64;
const _maxWrappedLinkLength = 4096;

final _httpLinkPattern = RegExp(r'https?://[^\s<>"`|]+', caseSensitive: false);

bool terminalLinkModifierPressed({
  required TargetPlatform platform,
  required bool controlPressed,
  required bool metaPressed,
}) => platform == TargetPlatform.macOS ? metaPressed : controlPressed;

/// Finds an HTTP(S) link at a terminal cell, including links wrapped across
/// adjacent terminal rows.
Uri? terminalHttpLinkAtCell(Terminal terminal, CellOffset cell) {
  final lines = terminal.lines;
  if (cell.x < 0 ||
      cell.x >= terminal.viewWidth ||
      cell.y < 0 ||
      cell.y >= lines.length) {
    return null;
  }

  var firstRow = cell.y;
  while (firstRow > 0 && lines[firstRow].isWrapped) {
    firstRow--;
  }

  var lastRow = cell.y;
  while (lastRow + 1 < lines.length && lines[lastRow + 1].isWrapped) {
    lastRow++;
  }
  if (lastRow - firstRow + 1 > _maxWrappedLinkRows) return null;

  final text = StringBuffer();
  int? clickedOffset;
  for (var row = firstRow; row <= lastRow; row++) {
    final line = lines[row];
    final endColumn = line.getTrimmedLength(terminal.viewWidth);
    for (var column = 0; column < endColumn; column++) {
      if (row == cell.y && column == cell.x) {
        clickedOffset = text.length;
      }

      final codePoint = line.getCodePoint(column);
      if (codePoint == 0) {
        if (column == 0 || line.getWidth(column - 1) != 2) {
          text.write(' ');
        }
      } else {
        text.writeCharCode(codePoint);
      }
      if (text.length > _maxWrappedLinkLength) return null;
    }
    if (row == cell.y && cell.x >= endColumn) {
      clickedOffset ??= text.length;
    }
    if (row < lastRow && !lines[row + 1].isWrapped) {
      text.write('\n');
    }
  }

  final offset = clickedOffset;
  if (offset == null) return null;

  final content = text.toString();
  for (final match in _httpLinkPattern.allMatches(content)) {
    if (offset < match.start || offset >= match.end) continue;
    final raw = match.group(0)!;
    final link = _trimLinkPunctuation(raw);
    if (link.isEmpty || offset >= match.start + link.length) return null;

    final uri = Uri.tryParse(link);
    if (uri == null ||
        !uri.isAbsolute ||
        (uri.scheme.toLowerCase() != 'http' &&
            uri.scheme.toLowerCase() != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri;
  }
  return null;
}

String _trimLinkPunctuation(String value) {
  var end = value.length;
  while (end > 0) {
    final last = value[end - 1];
    if ("'\".,!?;:".contains(last)) {
      end--;
      continue;
    }

    final opening = switch (last) {
      ')' => '(',
      ']' => '[',
      '}' => '{',
      _ => null,
    };
    if (opening != null &&
        _countCharacter(value, last) > _countCharacter(value, opening)) {
      end--;
      continue;
    }
    break;
  }
  return value.substring(0, end);
}

int _countCharacter(String value, String character) =>
    value.codeUnits.where((unit) => unit == character.codeUnitAt(0)).length;
