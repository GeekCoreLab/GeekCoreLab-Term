import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/settings/app_settings.dart';
import 'package:geekcore_term/settings/settings_page.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test('new or unknown theme settings use the HexHub-style light theme', () {
    expect(AppThemeStylePresentation.fromName(null), AppThemeStyle.light);
    expect(AppThemeStylePresentation.fromName('missing'), AppThemeStyle.light);
    expect(AppThemeStylePresentation.fromName('ocean'), AppThemeStyle.ocean);
  });

  test('persists and clamps the terminal font size', () async {
    final settings = await AppSettingsController.load();

    expect(settings.terminalFontSize, 14);
    await settings.setTerminalFontSize(21);
    expect((await AppSettingsController.load()).terminalFontSize, 21);

    await settings.setTerminalFontSize(50);
    expect(settings.terminalFontSize, 24);
  });

  test('persists and restores the terminal font family', () async {
    final settings = await AppSettingsController.load();

    expect(settings.terminalFontFamily, TerminalFontFamily.system);
    await settings.setTerminalFontFamily(TerminalFontFamily.jetBrainsMono);
    expect(
      (await AppSettingsController.load()).terminalFontFamily,
      TerminalFontFamily.jetBrainsMono,
    );
  });

  test('clearAll restores first-run appearance defaults', () async {
    final settings = await AppSettingsController.load();
    await settings.setThemeStyle(AppThemeStyle.graphite);
    await settings.setTerminalFontSize(19);
    await settings.setTerminalFontFamily(TerminalFontFamily.firaCode);
    await settings.setSshKeepAliveSeconds(60);

    await settings.clearAll();

    expect(settings.themeStyle, AppThemeStyle.light);
    expect(settings.terminalFontSize, 14);
    expect(settings.terminalFontFamily, TerminalFontFamily.system);
    expect(settings.sshKeepAliveSeconds, 10);
  });

  test('persists supported SSH keep-alive intervals only', () async {
    final settings = await AppSettingsController.load();
    expect(settings.sshKeepAliveSeconds, 10);

    await settings.setSshKeepAliveSeconds(30);
    expect((await AppSettingsController.load()).sshKeepAliveSeconds, 30);
    await expectLater(settings.setSshKeepAliveSeconds(15), throwsArgumentError);
  });

  testWidgets('settings page applies and displays the selected font size', (
    tester,
  ) async {
    final settings = await AppSettingsController.load();
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: settings.themeData,
        home: AppSettingsPage(settings: settings, onClearAppData: () async {}),
      ),
    );

    expect(
      tester
          .widget<DropdownButtonFormField<int>>(
            find.byType(DropdownButtonFormField<int>),
          )
          .initialValue,
      10,
    );

    tester.widget<Slider>(find.byType(Slider)).onChanged!(20);
    await tester.pump();
    tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(20);
    await tester.pumpAndSettle();

    expect(settings.terminalFontSize, 20);
    expect(find.text('20 px'), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<TerminalFontFamily>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('JetBrains Mono').last);
    await tester.pumpAndSettle();
    expect(settings.terminalFontFamily, TerminalFontFamily.jetBrainsMono);

    final keepAliveDropdown = find.byType(DropdownButtonFormField<int>);
    await tester.ensureVisible(keepAliveDropdown);
    await tester.pumpAndSettle();
    await tester.tap(keepAliveDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('30 秒'));
    await tester.pumpAndSettle();
    expect(settings.sshKeepAliveSeconds, 30);
  });
}
