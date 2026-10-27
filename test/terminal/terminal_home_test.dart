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
    for (final title in ['本地终端', 'SSH', '串口', 'Telnet']) {
      expect(find.byKey(ValueKey('home-quick-$title')), findsOneWidget);
    }

    tester.view.physicalSize = const Size(1280, 800);
    await tester.pumpAndSettle();
    expect(find.byTooltip('快速连接'), findsOneWidget);

    tester.view.physicalSize = const Size(1600, 900);
    await tester.pumpAndSettle();
    expect(find.text('快速连接'), findsOneWidget);
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
