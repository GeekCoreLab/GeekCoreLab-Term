import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/command_snippet_dialog.dart';
import 'package:geekcore_term/terminal/session_store.dart';

void main() {
  testWidgets('pastes a selected snippet through the caller callback', (
    tester,
  ) async {
    const snippet = CommandSnippet(id: 'disk', name: '检查磁盘', command: 'df -h');
    CommandSnippet? inserted;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => CommandSnippetManagerDialog(
                    initialSnippets: const [snippet],
                    sessionTitle: '测试会话',
                    canInsert: true,
                    isBroadcasting: false,
                    onSave: (_) async {},
                    onInsert: (value) async {
                      inserted = value;
                      return true;
                    },
                  ),
                ),
                child: const Text('打开片段'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开片段'));
    await tester.pumpAndSettle();
    expect(find.text('检查磁盘'), findsOneWidget);

    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();

    expect(inserted, snippet);
    expect(find.text('命令片段'), findsNothing);
  });
}
