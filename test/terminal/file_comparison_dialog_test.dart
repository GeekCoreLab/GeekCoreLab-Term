import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/file_comparison.dart';
import 'package:geekcore_term/terminal/file_comparison_dialog.dart';

void main() {
  testWidgets('renders aligned changes without overflow on a phone viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FileComparisonDialog(
            leftName: 'local.txt',
            leftPath: '/tmp/local.txt',
            rightName: 'remote.txt',
            rightPath: '/home/test/remote.txt',
            comparison: compareFileContents(
              Uint8List.fromList(utf8.encode('before\nremoved\nafter\n')),
              Uint8List.fromList(utf8.encode('before\nadded\nafter\n')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('文件比较'), findsOneWidget);
    expect(find.text('removed'), findsOneWidget);
    expect(find.text('added'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
