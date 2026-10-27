import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/terminal_assistant.dart';
import 'package:geekcore_term/terminal/terminal_assistant_panel.dart';

void main() {
  test('recognizes an ANSI-colored error split across output chunks', () {
    final analyzer = TerminalAssistantAnalyzer();
    addTearDown(analyzer.dispose);

    expect(
      analyzer.observe('bind failed: \u001b[31mAddress already in '),
      isEmpty,
    );
    final findings = analyzer.observe('use\u001b[0m on port 8080');

    expect(findings, hasLength(1));
    expect(findings.single.ruleId, 'port-in-use');
    expect(findings.single.evidence, 'Address already in use');
    expect(findings.single.suggestedCommands, contains('ss -ltnp'));
    expect(findings.single.outputOffset, greaterThan(0));
  });

  test(
    'deduplicates repeated output briefly, then accepts a later occurrence',
    () {
      var now = DateTime.utc(2026, 10, 27, 1);
      final analyzer = TerminalAssistantAnalyzer(clock: () => now);
      addTearDown(analyzer.dispose);

      analyzer.observe('Connection refused');
      analyzer.observe('\r\nConnection refused');
      expect(analyzer.findings, hasLength(1));

      now = now.add(const Duration(seconds: 31));
      analyzer.observe('\r\nConnection refused');
      expect(analyzer.findings, hasLength(2));
    },
  );

  test('shows findings from the newest output position first', () {
    final analyzer = TerminalAssistantAnalyzer();
    addTearDown(analyzer.dispose);

    analyzer.observe('Connection refused; then Address already in use');

    expect(analyzer.findings.map((finding) => finding.ruleId), [
      'port-in-use',
      'connection-refused',
    ]);
  });

  test(
    'keeps only a bounded finding history and reset clears parser context',
    () {
      var now = DateTime.utc(2026, 10, 27, 2);
      final analyzer = TerminalAssistantAnalyzer(clock: () => now);
      addTearDown(analyzer.dispose);

      for (var index = 0; index < 65; index++) {
        analyzer.observe('No space left on device #$index\n');
        now = now.add(const Duration(seconds: 31));
      }
      expect(
        analyzer.findings,
        hasLength(TerminalAssistantAnalyzer.maxFindings),
      );
      analyzer.observe(List.filled(1000, 'x').join());
      expect(
        analyzer.bufferedContextCharacters,
        lessThanOrEqualTo(TerminalAssistantAnalyzer.maxContextCharacters),
      );

      analyzer.reset();
      expect(analyzer.findings, isEmpty);
      expect(
        analyzer.observe('No space left on device').single.ruleId,
        'storage-full',
      );
    },
  );

  testWidgets('sidebar fits a phone width and never runs commands', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final analyzer = TerminalAssistantAnalyzer()
      ..observe('Could not resolve hostname example.invalid');
    addTearDown(analyzer.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              TerminalAssistantPanel(
                analyzer: analyzer,
                sessionTitle: 'staging host',
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );

    expect(find.text('终端助手'), findsOneWidget);
    expect(find.text('主机名解析失败'), findsOneWidget);
    expect(find.text('Could not resolve hostname'), findsOneWidget);
    expect(find.textContaining('不会自动执行'), findsOneWidget);
    expect(find.text('getent ahosts HOSTNAME'), findsOneWidget);
    expect(find.text('排错命令本'), findsOneWidget);

    // Expand troubleshoot command drawer
    await tester.tap(find.text('排错命令本'));
    await tester.pumpAndSettle();
    expect(find.text('网络与端口排查'), findsOneWidget);
    expect(find.text('服务与日志 (systemd)'), findsOneWidget);
    expect(find.text('资源与进程 (CPU/内存/磁盘)'), findsOneWidget);
    expect(find.text('系统环境与安全'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  group('TerminalInlineHintTransformer', () {
    test('transforms systemctl status output with GUI-styled inline hints', () {
      final transformer = TerminalInlineHintTransformer();
      final line1 =
          'Loaded: loaded (/etc/systemd/system/k3s.service; enabled; preset: enabled)\r\n';
      final out1 = transformer.transform(line1);

      expect(out1, contains('enabled'));
      expect(out1, contains('已启用'));

      final line2 =
          '     Active: active (running) since Tue 2026-10-20 02:53:47 UTC; 1 week 0 days ago\r\n';
      final out2 = transformer.transform(line2);

      expect(out2, contains('active'));
      expect(out2, contains('活跃'));
      expect(out2, contains('running'));
      expect(out2, contains('运行中'));
      expect(out2, contains('本地 '));
      expect(out2, contains('1周0天前'));
    });

    test('handles split chunks across lines without losing text', () {
      final transformer = TerminalInlineHintTransformer();
      final chunk1 = 'Loaded: loaded (/etc/systemd/system/test.service; en';
      final chunk2 = 'abled; preset: disabled)\n';
      expect(transformer.transform(chunk1), isEmpty);
      final out2 = transformer.transform(chunk2);
      expect(out2, contains('enabled'));
      expect(out2, contains('已启用'));
      expect(out2, contains('disabled'));
      expect(out2, contains('已禁用'));
    });

    test('passes non-whitelisted trailing partial lines like prompts immediately without delay', () async {
      final transformer = TerminalInlineHintTransformer();
      String flushed = '';
      transformer.onFlush = (text) => flushed += text;

      // Prompts and ordinary input outside whitelisted status commands
      // should return immediately to avoid blind typing or prompt lag.
      final immediate = transformer.transform('root@bt-main:~# ');
      expect(immediate, 'root@bt-main:~# ');
      expect(flushed, isEmpty);
    });
  });
}
