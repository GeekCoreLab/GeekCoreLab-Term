import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/command_macro_dialog.dart';
import 'package:geekcore_term/terminal/terminal_macro.dart';

void main() {
  final macro = TerminalMacro.fromScript(
    id: 'health-check',
    name: '健康检查',
    script: 'hostname\nuptime\ndf -h /',
  );

  testWidgets('selecting a macro calls the parent execution flow', (
    tester,
  ) async {
    TerminalMacro? requested;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => TerminalMacroManagerDialog(
                    initialMacros: [macro],
                    canRun: true,
                    onSave: (_) async {},
                    onRun: (value) async {
                      requested = value;
                    },
                  ),
                ),
                child: const Text('打开宏'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开宏'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();

    expect(requested, macro);
    expect(find.text('命令宏'), findsOneWidget);
  });

  testWidgets('review shows the complete script and frozen target names', (
    tester,
  ) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  result = await showDialog<bool>(
                    context: context,
                    builder: (_) => TerminalMacroExecutionReviewDialog(
                      macro: macro,
                      targetNames: const ['prod-a · 标签 1', 'prod-b · 标签 2'],
                    ),
                  );
                },
                child: const Text('确认宏'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('确认宏'));
    await tester.pumpAndSettle();
    expect(find.text('prod-a · 标签 1'), findsOneWidget);
    expect(find.text('prod-b · 标签 2'), findsOneWidget);
    expect(find.text(macro.script), findsOneWidget);
    expect(find.text('执行 3 条命令'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });

  testWidgets('review returns approval only after explicit execution tap', (
    tester,
  ) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  result = await showDialog<bool>(
                    context: context,
                    builder: (_) => TerminalMacroExecutionReviewDialog(
                      macro: macro,
                      targetNames: const ['qa-host · 标签 4'],
                    ),
                  );
                },
                child: const Text('执行对话框'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('执行对话框'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('执行 3 条命令'));
    await tester.pumpAndSettle();

    expect(result, isTrue);
  });

  testWidgets('macro dialogs fit a phone-sized viewport', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => TerminalMacroManagerDialog(
                      initialMacros: [macro],
                      canRun: true,
                      onSave: (_) async {},
                      onRun: (_) async {},
                    ),
                  ),
                  child: const Text('打开宏管理'),
                ),
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => TerminalMacroExecutionReviewDialog(
                      macro: macro,
                      targetNames: const ['mobile-host · 标签 1'],
                    ),
                  ),
                  child: const Text('打开宏确认'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开宏管理'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('打开宏确认'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
