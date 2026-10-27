import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/terminal_keyword_highlights.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('maps Unicode and wide-character keyword matches to terminal cells', () {
    final terminal = Terminal();
    terminal.write('前缀 ERROR timeout');
    const rule = TerminalKeywordRule(
      keyword: 'ERROR',
      colorValue: 0x70EF4444,
      caseSensitive: true,
    );

    final matches = findTerminalKeywordMatches(terminal, const [rule]);

    expect(matches, hasLength(1));
    expect(matches.single.startX, 5);
    expect(matches.single.endX, 10);
  });

  test(
    'matches phrases case-insensitively and respects case-sensitive rules',
    () {
      final terminal = Terminal();
      terminal.write('Error: connection timeout; error: retry');

      final insensitive = findTerminalKeywordMatches(terminal, const [
        TerminalKeywordRule(keyword: 'error', colorValue: 0x70EF4444),
      ]);
      final sensitive = findTerminalKeywordMatches(terminal, const [
        TerminalKeywordRule(
          keyword: 'error',
          colorValue: 0x7060A5FA,
          caseSensitive: true,
        ),
      ]);
      final phrase = findTerminalKeywordMatches(terminal, const [
        TerminalKeywordRule(
          keyword: 'connection timeout',
          colorValue: 0x70F97316,
        ),
      ]);

      expect(insensitive.map((match) => match.startX), [0, 27]);
      expect(sensitive.map((match) => match.startX), [27]);
      expect(phrase, hasLength(1));
      expect(phrase.single.startX, 7);
      expect(phrase.single.endX, 25);
    },
  );

  test('does not match across rows and enforces the highlight limit', () {
    final terminal = Terminal(maxLines: 40);
    terminal.resize(40, 4);
    terminal.write('ERR\r\nOR ERROR ERROR ERROR');

    final matches = findTerminalKeywordMatches(terminal, const [
      TerminalKeywordRule(keyword: 'ERROR', colorValue: 0x70EF4444),
    ], maxMatches: 2);

    expect(matches, hasLength(2));
    expect(matches.every((match) => match.line == 1), isTrue);
  });

  test(
    'highlighter installs, refreshes, and disposes controller highlights',
    () {
      final terminal = Terminal();
      terminal.write('ERROR is visible');
      final controller = TerminalController();
      final highlighter = TerminalKeywordHighlighter(controller);
      const rules = [
        TerminalKeywordRule(keyword: 'ERROR', colorValue: 0x70EF4444),
      ];

      highlighter.refreshNow(terminal, rules);
      expect(controller.highlights, hasLength(1));
      final range = controller.highlights.single.range!.normalized;
      expect(range.begin.x, 0);
      expect(range.end.x, 5);

      highlighter.refreshNow(terminal, const []);
      expect(controller.highlights, isEmpty);
      highlighter.dispose();
      controller.dispose();
    },
  );
}
