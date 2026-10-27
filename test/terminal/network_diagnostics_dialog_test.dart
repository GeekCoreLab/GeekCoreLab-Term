import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/network_diagnostics_dialog.dart';

void main() {
  testWidgets('dialog validates a port and fits a phone-sized viewport', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: NetworkDiagnosticsDialog())),
    );
    expect(tester.takeException(), isNull);

    await tester.enterText(find.byType(TextField).first, 'localhost');
    await tester.enterText(find.byType(TextField).last, '0');
    await tester.tap(find.text('测试 TCP 端口'));
    await tester.pump();
    await tester.pump();

    expect(find.text('诊断失败'), findsOneWidget);
    expect(find.textContaining('TCP 端口范围为 1 到 65535'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
