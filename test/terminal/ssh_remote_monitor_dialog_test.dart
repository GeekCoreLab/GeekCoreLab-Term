import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/ssh_remote_monitor_bar.dart';
import 'package:geekcore_term/terminal/ssh_remote_monitor_cache.dart';
import 'package:geekcore_term/terminal/ssh_remote_monitor_dialog.dart';

void main() {
  testWidgets('monitor details fit a phone-width viewport', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final cache = SshRemoteMonitorCache();
    addTearDown(cache.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SshRemoteMonitorDialog(cache: cache, sessionTitle: '测试 SSH'),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('远程监控'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('single-line monitor strip fits a phone-width viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final cache = SshRemoteMonitorCache();
    addTearDown(cache.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: SshRemoteMonitorBar(
            client: null,
            cache: cache,
            sessionTitle: '测试 SSH',
            onOpenDetails: () {},
          ),
        ),
      ),
    );

    expect(find.text('SSH 尚未连接'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
