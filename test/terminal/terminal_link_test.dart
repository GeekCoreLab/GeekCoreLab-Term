import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/terminal_link.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('uses platform primary modifier for opening terminal links', () {
    expect(
      terminalLinkModifierPressed(
        platform: TargetPlatform.linux,
        controlPressed: true,
        metaPressed: false,
      ),
      isTrue,
    );
    expect(
      terminalLinkModifierPressed(
        platform: TargetPlatform.macOS,
        controlPressed: true,
        metaPressed: false,
      ),
      isFalse,
    );
    expect(
      terminalLinkModifierPressed(
        platform: TargetPlatform.macOS,
        controlPressed: false,
        metaPressed: true,
      ),
      isTrue,
    );
  });

  test('finds HTTP links after wide characters and trims punctuation', () {
    final terminal = Terminal();
    const link = 'https://example.com/path_(ok)';
    terminal.write('访问 $link.');

    expect(
      terminalHttpLinkAtCell(terminal, const CellOffset(10, 0)).toString(),
      link,
    );
    expect(
      terminalHttpLinkAtCell(terminal, CellOffset(5 + link.length, 0)),
      isNull,
    );
  });

  test('finds links that wrap across terminal rows', () {
    final terminal = Terminal(maxLines: 40);
    terminal.resize(12, 4);
    terminal.write('https://example.com');

    expect(
      terminalHttpLinkAtCell(terminal, const CellOffset(3, 1)).toString(),
      'https://example.com',
    );
  });

  test('rejects unsupported schemes and URLs with embedded credentials', () {
    final unsupported = Terminal();
    unsupported.write('ftp://example.com');
    expect(terminalHttpLinkAtCell(unsupported, const CellOffset(8, 0)), isNull);

    final credentialed = Terminal();
    credentialed.write('https://user:secret@example.com');
    expect(
      terminalHttpLinkAtCell(credentialed, const CellOffset(15, 0)),
      isNull,
    );
  });

  test('trims quoted URL punctuation from terminal output', () {
    final terminal = Terminal();
    terminal.write("Open 'https://example.com'");

    expect(
      terminalHttpLinkAtCell(terminal, const CellOffset(12, 0)).toString(),
      'https://example.com',
    );
  });

  testWidgets(
    'tap callback runs and intercepted clicks skip remote mouse input',
    (tester) async {
      final terminal = Terminal();
      final output = <String>[];
      terminal.onOutput = output.add;
      terminal.write('\u001b[?1000h');
      var tapCount = 0;
      var interceptCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 480,
              height: 240,
              child: TerminalView(
                terminal,
                padding: EdgeInsets.zero,
                onTapDownIntercept: (_, _) {
                  interceptCount++;
                  return true;
                },
                onTapUp: (_, _) => tapCount++,
              ),
            ),
          ),
        ),
      );

      await tester.tapAt(const Offset(80, 40));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));

      expect(tapCount, 1);
      expect(interceptCount, 1);
      expect(output, isEmpty);
    },
  );
}
