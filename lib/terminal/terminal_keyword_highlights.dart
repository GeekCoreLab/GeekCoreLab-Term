import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

class TerminalKeywordRule {
  const TerminalKeywordRule({
    required this.keyword,
    required this.colorValue,
    this.caseSensitive = false,
  });

  final String keyword;
  final int colorValue;
  final bool caseSensitive;

  Color get color => Color(colorValue);

  Map<String, Object> toJson() => {
    'keyword': keyword,
    'color': colorValue,
    'caseSensitive': caseSensitive,
  };

  static TerminalKeywordRule? tryParse(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final keyword = value['keyword'];
    final color = value['color'];
    final caseSensitive = value['caseSensitive'];
    if (keyword is! String ||
        keyword.trim().isEmpty ||
        keyword.runes.length > 128 ||
        keyword.contains('\n') ||
        keyword.contains('\r') ||
        color is! int ||
        color < 0 ||
        color > 0xFFFFFFFF ||
        (caseSensitive != null && caseSensitive is! bool)) {
      return null;
    }
    return TerminalKeywordRule(
      keyword: keyword.trim(),
      colorValue: color,
      caseSensitive: caseSensitive == true,
    );
  }
}

class TerminalKeywordMatch {
  const TerminalKeywordMatch({
    required this.startX,
    required this.endX,
    required this.line,
    required this.color,
  });

  final int startX;
  final int endX;
  final int line;
  final Color color;
}

const maxTerminalKeywordRules = 24;
const maxTerminalKeywordHighlights = 512;

/// Finds literal keyword matches and maps Unicode runes back to terminal cells.
/// Each match stays within one row so wide characters remain correctly aligned.
List<TerminalKeywordMatch> findTerminalKeywordMatches(
  Terminal terminal,
  List<TerminalKeywordRule> rules, {
  int maxMatches = maxTerminalKeywordHighlights,
  int startLine = 0,
}) {
  if (rules.isEmpty || maxMatches <= 0) return const [];

  final matches = <TerminalKeywordMatch>[];
  final buffer = terminal.buffer;
  for (
    var y = startLine.clamp(0, buffer.height).toInt();
    y < buffer.height;
    y++
  ) {
    final line = buffer.lines[y];
    final runes = <int>[];
    final starts = <int>[];
    final ends = <int>[];
    final foldedRunes = <int>[];
    final foldedStarts = <int>[];
    final foldedEnds = <int>[];
    final length = line.getTrimmedLength(buffer.viewWidth);

    for (var x = 0; x < length; x++) {
      final codePoint = line.getCodePoint(x);
      if (codePoint == 0 && x > 0 && line.getWidth(x - 1) == 2) continue;
      final cellWidth = codePoint == 0 ? 1 : line.getWidth(x).clamp(1, 2);
      final character = String.fromCharCode(codePoint == 0 ? 0x20 : codePoint);
      for (final rune in character.runes) {
        runes.add(rune);
        starts.add(x);
        ends.add(x + cellWidth);
        for (final foldedRune in String.fromCharCode(
          rune,
        ).toLowerCase().runes) {
          foldedRunes.add(foldedRune);
          foldedStarts.add(x);
          foldedEnds.add(x + cellWidth);
        }
      }
    }

    for (final rule in rules) {
      final needle = _normalizedRunes(rule.keyword, rule.caseSensitive);
      final source = rule.caseSensitive ? runes : foldedRunes;
      final sourceStarts = rule.caseSensitive ? starts : foldedStarts;
      final sourceEnds = rule.caseSensitive ? ends : foldedEnds;
      if (needle.isEmpty || needle.length > source.length) continue;
      var index = 0;
      while (index + needle.length <= source.length) {
        var found = true;
        for (var offset = 0; offset < needle.length; offset++) {
          if (source[index + offset] != needle[offset]) {
            found = false;
            break;
          }
        }

        if (found) {
          matches.add(
            TerminalKeywordMatch(
              startX: sourceStarts[index],
              endX: sourceEnds[index + needle.length - 1],
              line: y,
              color: rule.color,
            ),
          );
          if (matches.length >= maxMatches) return matches;
          index += needle.length;
        } else {
          index++;
        }
      }
    }
  }
  return matches;
}

List<int> _normalizedRunes(String value, bool caseSensitive) =>
    (caseSensitive ? value : value.toLowerCase()).runes.toList();

/// Coalesces terminal output bursts before rebuilding bounded keyword overlays.
class TerminalKeywordHighlighter {
  TerminalKeywordHighlighter(this._controller);

  final TerminalController _controller;
  final List<_OwnedKeywordHighlight> _highlights = [];
  List<TerminalKeywordRule> _pendingRules = const [];
  Terminal? _pendingTerminal;
  Timer? _timer;
  bool _hasScanned = false;
  bool _disposed = false;

  void schedule(Terminal terminal, List<TerminalKeywordRule> rules) {
    if (_disposed) return;
    _pendingTerminal = terminal;
    _pendingRules = List.unmodifiable(rules);
    if (_timer != null) return;
    _timer = Timer(const Duration(milliseconds: 120), _rebuild);
  }

  void refreshNow(Terminal terminal, List<TerminalKeywordRule> rules) {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    _pendingTerminal = terminal;
    _pendingRules = List.unmodifiable(rules);
    _rebuild();
  }

  void _rebuild() {
    _timer = null;
    final terminal = _pendingTerminal;
    if (_disposed || terminal == null) return;
    final buffer = terminal.buffer;
    final scanWindow = (buffer.viewHeight + 128).clamp(256, 1024).toInt();
    final startLine = !_hasScanned || _pendingRules.isEmpty
        ? 0
        : (buffer.height - scanWindow).clamp(0, buffer.height).toInt();
    if (startLine == 0) {
      _clear();
    } else {
      _removeHighlightsWhere(
        (item) => !item.start.attached || item.start.y >= startLine,
      );
      _highlights.sort((a, b) => a.start.y.compareTo(b.start.y));
      final overflow = _highlights.length - maxTerminalKeywordHighlights ~/ 2;
      if (overflow > 0) {
        for (final item in _highlights.take(overflow).toList()) {
          _removeHighlight(item);
        }
      }
    }
    _hasScanned = true;
    final available = maxTerminalKeywordHighlights - _highlights.length;
    for (final match in findTerminalKeywordMatches(
      terminal,
      _pendingRules,
      maxMatches: available,
      startLine: startLine,
    )) {
      final start = terminal.buffer.createAnchor(match.startX, match.line);
      final end = terminal.buffer.createAnchor(match.endX, match.line);
      final highlight = _controller.highlight(
        p1: start,
        p2: end,
        color: match.color,
      );
      _highlights.add(_OwnedKeywordHighlight(start, end, highlight));
    }
  }

  void _clear() {
    for (final item in _highlights.toList()) {
      _removeHighlight(item);
    }
  }

  void _removeHighlightsWhere(bool Function(_OwnedKeywordHighlight) test) {
    for (final item in _highlights.toList()) {
      if (test(item)) _removeHighlight(item);
    }
  }

  void _removeHighlight(_OwnedKeywordHighlight item) {
    if (!_highlights.remove(item)) return;
    item.highlight.dispose();
    item.start.dispose();
    item.end.dispose();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _pendingTerminal = null;
    _clear();
  }
}

class _OwnedKeywordHighlight {
  const _OwnedKeywordHighlight(this.start, this.end, this.highlight);

  final CellAnchor start;
  final CellAnchor end;
  final TerminalHighlight highlight;
}
