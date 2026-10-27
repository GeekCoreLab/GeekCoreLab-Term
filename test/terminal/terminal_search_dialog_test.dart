import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/terminal_search_dialog.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('search dialog highlights results and clears them on close', (
    tester,
  ) async {
    final terminal = Terminal()..write('Boot ready');
    final terminalController = TerminalController();
    final scrollController = ScrollController();

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => TerminalSearchDialog(
                    terminal: terminal,
                    terminalController: terminalController,
                    scrollController: scrollController,
                  ),
                ),
                child: const Text('打开搜索'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'boot');
    await tester.pump();

    expect(find.text('1 / 1'), findsOneWidget);
    expect(terminalController.highlights, hasLength(1));

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    expect(terminalController.highlights, isEmpty);
    terminalController.dispose();
    scrollController.dispose();
  });
}
