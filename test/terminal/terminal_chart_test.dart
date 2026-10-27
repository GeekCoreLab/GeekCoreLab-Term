import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/terminal_assistant.dart';
import 'package:geekcore_term/terminal/terminal_chart_models.dart';
import 'package:geekcore_term/terminal/terminal_chart_coordinator.dart';
import 'package:xterm/xterm.dart';
import 'package:flutter/widgets.dart';

void main() {
  group('TerminalInlineHintTransformer Whitelist', () {
    test('does NOT transform ordinary echo or cat commands', () {
      final transformer = TerminalInlineHintTransformer();

      // User runs echo running > 1.txt
      transformer.notifyUserInput('echo running > 1.txt\n');
      final echoLine = 'root@bt-main:~/tmp# echo running > 1.txt\r\n';
      expect(transformer.transform(echoLine), equals(echoLine));

      // User runs cat 1.txt and gets running
      transformer.notifyUserInput('cat 1.txt\n');
      final catEcho = 'root@bt-main:~/tmp# cat 1.txt\r\n';
      expect(transformer.transform(catEcho), equals(catEcho));

      final output = 'running\r\n';
      final transformed = transformer.transform(output);
      // Must not insert 运行中
      expect(transformed, equals(output));
      expect(transformed, isNot(contains('运行中')));
    });

    test('transforms whitelisted systemctl status output correctly', () {
      final transformer = TerminalInlineHintTransformer();

      transformer.notifyUserInput('systemctl status k3s\n');
      final promptLine = 'root@bt-main:~# systemctl status k3s\r\n';
      transformer.transform(promptLine);

      final statusLine =
          '   Active: active (running) since Tue 2026-10-20 02:53:47 UTC; 1 week 0 days ago\r\n';
      final transformed = transformer.transform(statusLine);

      expect(transformed, contains('活跃'));
      expect(transformed, contains('运行中'));
      expect(transformed, contains('本地 '));
      expect(transformed, contains('1周0天前'));

      // Shell prompt returns with newline, exiting whitelist
      final endPrompt = 'root@bt-main:~# \r\n';
      final endTransformed = transformer.transform(endPrompt);
      expect(endTransformed, equals(endPrompt));

      // Subsequent ordinary output is untouched
      final laterOutput = 'running\r\n';
      expect(transformer.transform(laterOutput), equals(laterOutput));
    });
  });

  group('TerminalCommandChartParser', () {
    test('identifies command candidates', () {
      expect(TerminalCommandChartParser.matchCommandType('df -h'), equals(CommandChartType.df));
      expect(TerminalCommandChartParser.matchCommandType('  df  -h / '), equals(CommandChartType.df));
      expect(TerminalCommandChartParser.matchCommandType('free -h'), equals(CommandChartType.free));
      expect(TerminalCommandChartParser.matchCommandType('free -m'), equals(CommandChartType.free));
      expect(TerminalCommandChartParser.matchCommandType('cat 1.txt'), isNull);
    });

    test('parses df -h output into structured entries', () {
      const sampleDf = '''
Filesystem      Size  Used Avail Use% Mounted on
udev            3.9G     0  3.9G   0% /dev
tmpfs           794M  1.4M  793M   1% /run
/dev/sda1        40G   18G   20G  48% /
tmpfs           3.9G     0  3.9G   0% /dev/shm
/dev/sdb1       100G   75G   25G  75% /data
''';
      final entries = TerminalCommandChartParser.parseDf(sampleDf);
      expect(entries.length, equals(5));

      final rootFs = entries.firstWhere((e) => e.mountedOn == '/');
      expect(rootFs.filesystem, equals('/dev/sda1'));
      expect(rootFs.size, equals('40G'));
      expect(rootFs.used, equals('18G'));
      expect(rootFs.avail, equals('20G'));
      expect(rootFs.usePercent, closeTo(0.48, 0.01));

      final dataFs = entries.firstWhere((e) => e.mountedOn == '/data');
      expect(dataFs.usePercent, closeTo(0.75, 0.01));
    });

    test('parses free -h output into structured statistics', () {
      const sampleFree = '''
               total        used        free      shared  buff/cache   available
Mem:           7.7Gi       2.1Gi       3.4Gi        52Mi       2.2Gi       5.3Gi
Swap:          2.0Gi       256Mi       1.7Gi
''';
      final stats = TerminalCommandChartParser.parseFree(sampleFree);
      expect(stats, isNotNull);
      expect(stats!.totalMem, equals('7.7Gi'));
      expect(stats.usedMem, equals('2.1Gi'));
      expect(stats.freeMem, equals('3.4Gi'));
      expect(stats.totalSwap, equals('2.0Gi'));
      expect(stats.usedSwap, equals('256Mi'));
      expect(stats.memUsageRatio, greaterThan(0.2));
      expect(stats.memUsageRatio, lessThan(0.35));
    });
  });

  group('TerminalChartCoordinator', () {
    test('captures and finishes a command block when prompt returns', () {
      final terminal = Terminal();
      final scrollController = ScrollController();
      final terminalController = TerminalController();
      final coordinator = TerminalChartCoordinator(
        terminal: terminal,
        scrollController: scrollController,
        terminalController: terminalController,
      );

      terminal.write('root@bt-main:~# df -h\r\n');
      coordinator.notifyUserInput('df -h\n');
      coordinator.observeOutput('root@bt-main:~# df -h\r\n');
      terminal.write('Filesystem      Size  Used Avail Use% Mounted on\r\n');
      coordinator.observeOutput('Filesystem      Size  Used Avail Use% Mounted on\r\n');
      terminal.write('/dev/sda1        40G   18G   20G  48% /\r\n');
      coordinator.observeOutput('/dev/sda1        40G   18G   20G  48% /\r\n');
      terminal.write('root@bt-main:~# ');
      coordinator.observeOutput('root@bt-main:~# ');

      expect(coordinator.blocks.length, equals(1));
      final block = coordinator.blocks.first;
      expect(block.command, equals('df -h'));
      expect(block.type, equals(CommandChartType.df));
      expect(block.dfEntries.length, equals(1));
      expect(block.isRenderMode, isTrue);

      // Toggle mode back to raw
      coordinator.toggleBlockMode(block);
      expect(block.isRenderMode, isFalse);
    });
  });
}
