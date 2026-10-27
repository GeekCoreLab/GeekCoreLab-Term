import 'package:xterm/xterm.dart';

class TerminalSearchMatch {
  const TerminalSearchMatch({
    required this.startX,
    required this.endX,
    required this.line,
  });

  final int startX;
  final int endX;
  final int line;
}

class TerminalSearchResult {
  const TerminalSearchResult({required this.matches, required this.truncated});

  final List<TerminalSearchMatch> matches;
  final bool truncated;
}

/// Searches the active terminal buffer, including its scrollback history.
/// Matches stay within a terminal row so their cell ranges remain precise.
TerminalSearchResult findTerminalMatches(
  Terminal terminal,
  String query, {
  bool caseSensitive = false,
  int maxMatches = 2000,
}) {
  final needle = _normalizeRunes(query, caseSensitive);
  if (needle.isEmpty || maxMatches <= 0) {
    return const TerminalSearchResult(matches: [], truncated: false);
  }

  final buffer = terminal.buffer;
  final matches = <TerminalSearchMatch>[];
  var truncated = false;

  for (var y = 0; y < buffer.height; y++) {
    final line = buffer.lines[y];
    final runes = <int>[];
    final starts = <int>[];
    final ends = <int>[];

    for (var x = 0; x < line.length; x++) {
      final codePoint = line.getCodePoint(x);
      if (codePoint == 0) continue;
      final width = line.getWidth(x).clamp(1, 2).toInt();
      for (final rune in _normalizeRunes(
        String.fromCharCode(codePoint),
        caseSensitive,
      )) {
        runes.add(rune);
        starts.add(x);
        ends.add(x + width);
      }
    }

    for (var i = 0; i + needle.length <= runes.length; i++) {
      var matchesQuery = true;
      for (var j = 0; j < needle.length; j++) {
        if (runes[i + j] != needle[j]) {
          matchesQuery = false;
          break;
        }
      }
      if (!matchesQuery) continue;

      if (matches.length == maxMatches) {
        truncated = true;
        break;
      }
      matches.add(
        TerminalSearchMatch(
          startX: starts[i],
          endX: ends[i + needle.length - 1],
          line: y,
        ),
      );
    }
    if (truncated) break;
  }

  return TerminalSearchResult(matches: matches, truncated: truncated);
}

List<int> _normalizeRunes(String value, bool caseSensitive) =>
    (caseSensitive ? value : value.toLowerCase()).runes.toList();
