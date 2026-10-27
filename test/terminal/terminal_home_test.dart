import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64;
import 'package:geekcore_term/settings/app_settings.dart';
import 'package:geekcore_term/src/rust/frb_generated.dart';
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
    expect(find.byTooltip('终端分屏'), findsOneWidget);
    expect(find.byTooltip('隐藏终端助手'), findsOneWidget);

    // Toggle assistant panel from the top right button
    await tester.tap(find.byTooltip('隐藏终端助手'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('显示终端助手'), findsOneWidget);

    await tester.tap(find.byTooltip('显示终端助手'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('隐藏终端助手'), findsOneWidget);
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
    await tester.tap(find.text('SSH 代理'));
    await tester.pumpAndSettle();
    expect(find.text('通过代理连接 SSH 主机'), findsOneWidget);
    await tester.ensureVisible(find.text('通过代理连接 SSH 主机'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('通过代理连接 SSH 主机'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('代理主机'));
    await tester.pumpAndSettle();
    expect(find.text('代理主机'), findsOneWidget);
    expect(find.text('代理端口'), findsOneWidget);
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

  testWidgets('startup group opens saved sessions sequentially and by group', (
    tester,
  ) async {
    await SessionStore().saveSaved([
      _telnetRecord('first', '10.0.0.1', group: 'ops'),
      _telnetRecord('other', '10.0.1.1', group: 'dev'),
      _telnetRecord('second', '10.0.0.2', group: 'ops'),
    ]);
    final settings = await AppSettingsController.load();
    addTearDown(settings.dispose);
    await settings.setStartupSessionGroup('ops');
    final api = _MockRustLibApi();
    RustLib.initMock(api: api);
    addTearDown(RustLib.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: settings.themeData,
        home: LocalTerminalPage(settings: settings),
      ),
    );
    await tester.pumpAndSettle();

    expect(api.startedTelnetHosts, ['10.0.0.1', '10.0.0.2']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

SessionRecord _telnetRecord(String id, String host, {required String group}) =>
    SessionRecord(
      id: id,
      name: id,
      protocol: SessionProtocol.telnet,
      address: host,
      port: 23,
      group: group,
      lastConnectedAt: DateTime.utc(2026),
    );

class _MockRustLibApi implements RustLibApi {
  final List<String> startedTelnetHosts = [];

  @override
  Future<PlatformInt64> crateApiTerminalStartTelnetSession({
    required String host,
    required int port,
    required int cols,
    required int rows,
  }) async {
    startedTelnetHosts.add(host);
    return startedTelnetHosts.length;
  }

  @override
  Future<void> crateApiTerminalCloseTerminalSession({
    required PlatformInt64 sessionId,
  }) async {}

  @override
  Stream<Uint8List> crateApiTerminalReadTerminalOutput({
    required PlatformInt64 sessionId,
  }) => const Stream.empty();

  @override
  Future<void> crateApiTerminalResizeTerminalSession({
    required PlatformInt64 sessionId,
    required int cols,
    required int rows,
  }) async {}

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
