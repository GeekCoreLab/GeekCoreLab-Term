import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/directory_comparison.dart';
import 'package:geekcore_term/terminal/directory_comparison_dialog.dart';

void main() {
  testWidgets('shows bounded directory differences on a phone viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectoryComparisonDialog(
            localRoot: '/tmp/project',
            remoteRoot: '/home/test/project',
            comparison: compareDirectorySnapshots(
              local: {
                'src/main.dart': const DirectoryComparisonSnapshot(
                  type: DirectoryComparisonItemType.file,
                  size: 120,
                  modifiedAtMillis: 1000,
                ),
                'notes.txt': const DirectoryComparisonSnapshot(
                  type: DirectoryComparisonItemType.file,
                  size: 20,
                  modifiedAtMillis: 1000,
                ),
              },
              remote: {
                'src/main.dart': const DirectoryComparisonSnapshot(
                  type: DirectoryComparisonItemType.file,
                  size: 120,
                  modifiedAtMillis: 1000,
                ),
                'extra.txt': const DirectoryComparisonSnapshot(
                  type: DirectoryComparisonItemType.file,
                  size: 20,
                  modifiedAtMillis: 1000,
                ),
              },
              isComplete: false,
              isSnapshotStable: false,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('目录比较'), findsOneWidget);
    expect(find.text('extra.txt'), findsOneWidget);
    await tester.drag(find.byType(ListView).first, const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.textContaining('达到安全上限'), findsOneWidget);
    expect(find.textContaining('不读取文件内容'), findsOneWidget);
    expect(find.textContaining('无法确认扫描期间列表未变化'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
