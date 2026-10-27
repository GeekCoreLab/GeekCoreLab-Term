import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/terminal_search.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('findTerminalMatches', () {
    test('searches scrollback and wraps through every row match', () {
      final terminal = Terminal(maxLines: 100);
      terminal.write('Alpha alpha\r\nother\r\nALPHA');

      final result = findTerminalMatches(terminal, 'alpha');

      expect(result.matches, hasLength(3));
      expect(result.matches[0].line, 0);
      expect(result.matches[0].startX, 0);
      expect(result.matches[1].line, 0);
      expect(result.matches[1].startX, 6);
      expect(result.matches[2].line, 2);
      expect(result.truncated, isFalse);
    });

    test('preserves cell offsets for wide characters', () {
      final terminal = Terminal(maxLines: 100);
      terminal.write('服务器 OK');

      final result = findTerminalMatches(terminal, 'OK');

      expect(result.matches, hasLength(1));
      expect(result.matches.single.startX, 7);
      expect(result.matches.single.endX, 9);
    });

    test('supports case-sensitive matching and caps large result sets', () {
      final terminal = Terminal(maxLines: 100);
      terminal.write('x x x');

      final caseSensitive = findTerminalMatches(
        terminal,
        'X',
        caseSensitive: true,
      );
      final capped = findTerminalMatches(terminal, 'x', maxMatches: 2);

      expect(caseSensitive.matches, isEmpty);
      expect(capped.matches, hasLength(2));
      expect(capped.truncated, isTrue);
    });
  });
}
