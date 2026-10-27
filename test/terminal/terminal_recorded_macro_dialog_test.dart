import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/terminal_input_recording.dart';
import 'package:geekcore_term/terminal/terminal_recorded_macro_dialog.dart';

void main() {
  final macro = TerminalRecordedMacro(
    id: 'recorded-test',
    name: '查看状态',
    events: [
      TerminalRecordedInputEvent(bytes: [0x68, 0x6F, 0x73, 0x74], delayMs: 0),
      TerminalRecordedInputEvent(bytes: [0x0D], delayMs: 60),
    ],
  );

  testWidgets('review requires explicit inspection before replay', (
    tester,
  ) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<bool>(
                  context: context,
                  builder: (_) => TerminalRecordedMacroReviewDialog(
                    macro: macro,
                    targetNames: const ['prod · 标签 1'],
                  ),
                );
              },
              child: const Text('打开确认'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开确认'));
    await tester.pumpAndSettle();
    expect(find.text('接收会话：prod · 标签 1'), findsOneWidget);
    expect(find.text('host␍'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '回放'))
          .onPressed,
      isNull,
    );

    await tester.tap(find.text('我已检查输入内容和目标会话'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '回放'))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.text('回放'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('save requires a named, reviewed preview', (tester) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<String>(
                  context: context,
                  builder: (_) => TerminalRecordedMacroNameDialog(
                    preview: macro.preview,
                    eventCount: macro.events.length,
                    totalBytes: macro.totalBytes,
                  ),
                );
              },
              child: const Text('打开保存'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开保存'));
    await tester.pumpAndSettle();
    expect(find.text(macro.preview), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byType(TextField), '常用命令');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('我已检查，内容不含秘密信息'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(result, '常用命令');
  });

  testWidgets('recorded macro dialogs fit a phone-sized viewport', (
    tester,
  ) async {
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
                    builder: (_) => TerminalRecordedMacroManagerDialog(
                      initialMacros: [macro],
                      onSave: (_) async {},
                      onRun: (_, _) async {},
                    ),
                  ),
                  child: const Text('打开管理'),
                ),
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => TerminalRecordedMacroReviewDialog(
                      macro: macro,
                      targetNames: const ['mobile · 标签 1'],
                    ),
                  ),
                  child: const Text('打开审核'),
                ),
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => TerminalRecordedMacroNameDialog(
                      preview: macro.preview,
                      eventCount: macro.events.length,
                      totalBytes: macro.totalBytes,
                    ),
                  ),
                  child: const Text('打开保存'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开管理'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开审核'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开保存'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('manager exposes a stop action while playback is running', (
    tester,
  ) async {
    final playback = Completer<void>();
    TerminalRecordedMacroRunControl? runControl;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => TerminalRecordedMacroManagerDialog(
                  initialMacros: [macro],
                  onSave: (_) async {},
                  onRun: (_, control) {
                    runControl = control;
                    return playback.future;
                  },
                ),
              ),
              child: const Text('打开运行管理'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开运行管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ListTile).first);
    await tester.pump();
    expect(find.text('停止回放'), findsOneWidget);
    expect(runControl?.isCancelled, isFalse);
    await tester.tap(find.text('停止回放'));
    expect(runControl?.isCancelled, isTrue);
    playback.complete();
    await tester.pumpAndSettle();
  });
}
