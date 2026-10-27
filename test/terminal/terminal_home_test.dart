import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/settings/app_settings.dart';
import 'package:geekcore_term/terminal/session_store.dart';
import 'package:geekcore_term/terminal/terminal_page.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets('home shows launch cards for the supported connection types', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final settings = await AppSettingsController.load();
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: settings.themeData,
        home: LocalTerminalPage(settings: settings),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('快速开始'), findsOneWidget);
    for (final title in ['本地终端', 'SSH', 'SFTP', '串口', 'Telnet']) {
      expect(find.byKey(ValueKey('home-quick-$title')), findsOneWidget);
    }
    await tester.tap(find.byTooltip('更多工具'));
    await tester.pumpAndSettle();
    expect(find.text('录制键盘输入…'), findsOneWidget);
    expect(find.text('录制宏管理…'), findsOneWidget);
    await tester.tap(find.text('录制宏管理…'));
    await tester.pumpAndSettle();
    expect(find.text('录制宏'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    tester.view.physicalSize = const Size(360, 640);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('更多工具'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('会话面板'));
    await tester.pumpAndSettle();
    expect(find.text('会话记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('助手'));
    await tester.pumpAndSettle();
    expect(find.text('终端助手'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('文件'));
    await tester.pumpAndSettle();
    expect(find.text('SFTP / SCP 文件'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('关闭侧栏'));
    await tester.pumpAndSettle();

    tester.view.physicalSize = const Size(1280, 800);
    await tester.pumpAndSettle();
    expect(find.byTooltip('快速连接'), findsOneWidget);

    tester.view.physicalSize = const Size(1600, 900);
    await tester.pumpAndSettle();
    expect(find.text('快速连接'), findsOneWidget);
    expect(find.byTooltip('录制键盘输入'), findsOneWidget);
    expect(find.byTooltip('录制宏管理'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SFTP quick start opens a file-only connection form', (
    tester,
  ) async {
    final settings = await AppSettingsController.load();
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: settings.themeData,
        home: LocalTerminalPage(settings: settings),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('home-quick-SFTP')));
    await tester.pumpAndSettle();

    expect(find.text('SFTP 文件会话'), findsOneWidget);
    expect(find.text('仅文件浏览和传输，不启动 Shell'), findsOneWidget);
    expect(find.text('SFTP 服务器（SSH 主机）'), findsOneWidget);
    expect(find.text('SSH/SFTP 端口'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('Geekcore Term'), findsNWidgets(2));
  });

  testWidgets('restores the saved split layout without opening sessions', (
    tester,
  ) async {
    await SessionStore().saveTerminalSplitMode(TerminalSplitMode.vertical);
    final settings = await AppSettingsController.load();
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: settings.themeData,
        home: LocalTerminalPage(settings: settings),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('此窗格尚未连接'), findsNWidgets(2));
    expect(find.text('连接会话'), findsNWidgets(2));
  });
}
