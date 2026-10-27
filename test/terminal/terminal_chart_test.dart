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
      expect(TerminalCommandChartParser.matchCommandType('docker ps'), equals(CommandChartType.dockerPs));
      expect(TerminalCommandChartParser.matchCommandType('docker ps -a'), equals(CommandChartType.dockerPs));
      expect(TerminalCommandChartParser.matchCommandType('docker container ls'), equals(CommandChartType.dockerPs));
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

    test('parses Chinese localized free -h and df -h outputs', () {
      const sampleZhFree = '''
                总计        已用        空闲        共享   缓冲/缓存        可用
内存：          30Gi        20Gi       3.2Gi       767Mi       7.9Gi       9.9Gi
交换：          47Gi        11Gi        36Gi
''';
      final stats = TerminalCommandChartParser.parseFree(sampleZhFree);
      expect(stats, isNotNull);
      expect(stats!.totalMem, equals('30Gi'));
      expect(stats.usedMem, equals('20Gi'));
      expect(stats.freeMem, equals('3.2Gi'));
      expect(stats.totalSwap, equals('47Gi'));
      expect(stats.usedSwap, equals('11Gi'));

      const sampleZhDf = '''
文件系统        大小  已用  可用 已用% 挂载点
                 16G     0   16G    0% /
/dev/nvme0n1p2  953G  554G  384G   60% /home/hhjmk
''';
      final entries = TerminalCommandChartParser.parseDf(sampleZhDf);
      expect(entries.length, equals(2));
      expect(entries[0].mountedOn, equals('/'));
      expect(entries[1].filesystem, equals('/dev/nvme0n1p2'));
      expect(entries[1].usePercent, closeTo(0.60, 0.01));
    });

    test('parses docker ps output into structured container entries', () {
      const sampleDocker = '''
CONTAINER ID   IMAGE          COMMAND                  CREATED         STATUS         PORTS                               NAMES
a1b2c3d4e5f6   nginx:alpine   "/docker-entrypoint.…"   2 hours ago     Up 2 hours     0.0.0.0:80->80/tcp, :::80->80/tcp   web-server
b2c3d4e5f6a1   redis:7        "docker-entrypoint.s…"   3 days ago      Up 3 days      0.0.0.0:6379->6379/tcp              redis-cache
c3d4e5f6a1b2   postgres:15    "docker-entrypoint.s…"   5 days ago      Exited (0)                                         pg-db
''';
      final containers = TerminalCommandChartParser.parseDockerPs(sampleDocker);
      expect(containers.length, equals(3));
      expect(containers[0].containerId, equals('a1b2c3d4e5f6'));
      expect(containers[0].image, equals('nginx:alpine'));
      expect(containers[0].names, equals('web-server'));
      expect(containers[0].isRunning, isTrue);

      expect(containers[1].containerId, equals('b2c3d4e5f6a1'));
      expect(containers[1].ports, contains('6379'));
      expect(containers[1].isRunning, isTrue);

      expect(containers[2].containerId, equals('c3d4e5f6a1b2'));
      expect(containers[2].isRunning, isFalse);
    });

    test('parses docker ps when CREATED column is shifted by inline hints or empty PORTS', () {
      const sampleDockerShifted = '''
CONTAINER ID   IMAGE                        COMMAND                  CREATED                 STATUS                  PORTS     NAMES
94e0c8a4b211   ghcr.io/immich-app/server    "tini -- /bin/sh…"       2 hours ago  2小时前     Up 2 hours (healthy)              immich_server
77a2b1c9d001   redis:6.2-alpine             "docker-entrypoint…"     3 days ago  3天前        Up 3 days               6379/tcp  immich_redis
''';
      final containers = TerminalCommandChartParser.parseDockerPs(sampleDockerShifted);
      expect(containers.length, equals(2));
      expect(containers[0].names, equals('immich_server'));
      expect(containers[0].status, contains('Up 2 hours'));
      expect(containers[0].isRunning, isTrue);

      expect(containers[1].names, equals('immich_redis'));
      expect(containers[1].ports, equals('6379/tcp'));
      expect(containers[1].isRunning, isTrue);
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

      // Verify that hidden lines are set in controller during render mode
      expect(terminalController.hiddenLineIndices, isNotEmpty);

      // Toggle mode back to raw
      coordinator.toggleBlockMode(block);
      expect(block.isRenderMode, isFalse);
      expect(terminalController.hiddenLineIndices, isEmpty);
    });

    test('captures Chinese free output with custom prompt via header detection and idle fallback', () async {
      final terminal = Terminal();
      final scrollController = ScrollController();
      final terminalController = TerminalController();
      final coordinator = TerminalChartCoordinator(
        terminal: terminal,
        scrollController: scrollController,
        terminalController: terminalController,
      );

      terminal.write('╭─hhjmk@arch ~\r\n╰─❯ free -h\r\n');
      coordinator.observeOutput('╭─hhjmk@arch ~\r\n╰─❯ free -h\r\n');
      const zhFreeOut =
          '                总计        已用        空闲        共享   缓冲/缓存        可用\r\n'
          '内存：          30Gi        20Gi       3.2Gi       767Mi       7.9Gi       9.9Gi\r\n'
          '交换：          47Gi        11Gi        36Gi\r\n'
          '╭─hhjmk@arch ~\r\n╰─❯ ';
      terminal.write(zhFreeOut);
      coordinator.observeOutput(zhFreeOut);

      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(coordinator.blocks.length, equals(1));
      final block = coordinator.blocks.first;
      expect(block.type, equals(CommandChartType.free));
      expect(block.freeStats?.totalMem, equals('30Gi'));
      expect(block.isRenderMode, isTrue);
      expect(terminalController.hiddenLineIndices, isNotEmpty);
    });

    test('only keeps the latest command chart and reverts previous command to raw', () {
      final terminal = Terminal();
      final scrollController = ScrollController();
      final terminalController = TerminalController();
      final coordinator = TerminalChartCoordinator(
        terminal: terminal,
        scrollController: scrollController,
        terminalController: terminalController,
      );

      // 1. Run `free -h`
      terminal.write('root@bt-main:~# free -h\r\n');
      coordinator.notifyUserInput('free -h\n');
      coordinator.observeOutput('root@bt-main:~# free -h\r\n');
      const freeOut =
          '               total        used        free      shared  buff/cache   available\r\n'
          'Mem:           7.7Gi       2.1Gi       3.4Gi        52Mi       2.2Gi       5.3Gi\r\n'
          'Swap:          2.0Gi       256Mi       1.7Gi\r\n'
          'root@bt-main:~# ';
      terminal.write(freeOut);
      coordinator.observeOutput(freeOut);

      expect(coordinator.blocks.length, equals(1));
      expect(coordinator.blocks.first.type, equals(CommandChartType.free));
      final freeHiddenLines = Set<int>.of(terminalController.hiddenLineIndices);
      expect(freeHiddenLines, isNotEmpty);

      // 2. Run `docker ps` -> `free -h` block should be replaced and its lines unhidden (reverted to raw)
      terminal.write('docker ps\r\n');
      coordinator.notifyUserInput('docker ps\n');
      coordinator.observeOutput('docker ps\r\n');
      const dockerOut =
          'CONTAINER ID   IMAGE          COMMAND                  CREATED         STATUS         PORTS     NAMES\r\n'
          'a1b2c3d4e5f6   nginx:alpine   "/docker-entrypoint.…"   2 hours ago     Up 2 hours               web-server\r\n'
          'root@bt-main:~# ';
      terminal.write(dockerOut);
      coordinator.observeOutput(dockerOut);

      expect(coordinator.blocks.length, equals(1));
      expect(coordinator.blocks.first.type, equals(CommandChartType.dockerPs));
      expect(coordinator.blocks.first.dockerEntries.first.isRunning, isTrue);

      final dockerHiddenLines = terminalController.hiddenLineIndices;
      expect(dockerHiddenLines.intersection(freeHiddenLines), isEmpty);

      // 3. Running `clear` clears all chart blocks and hidden lines
      coordinator.observeOutput('\x1b[2J\x1b[H');
      expect(coordinator.blocks, isEmpty);
      expect(terminalController.hiddenLineIndices, isEmpty);
    });

    test('handles commands after clear (ESC[3J) and near bottom of terminal accurately', () {
      final terminal = Terminal();
      final scrollController = ScrollController();
      final terminalController = TerminalController();
      final coordinator = TerminalChartCoordinator(
        terminal: terminal,
        scrollController: scrollController,
        terminalController: terminalController,
      );

      // Push enough lines to create scrollback (> viewHeight)
      for (var i = 0; i < 45; i++) {
        terminal.write('line $i\r\n');
      }
      expect(terminal.buffer.scrollBack, greaterThan(0));

      // Execute `clear` sequence (ESC[H + ESC[2J + ESC[3J)
      const clearSeq = '\x1b[H\x1b[2J\x1b[3J';
      terminal.write(clearSeq);
      coordinator.observeOutput(clearSeq);
      expect(terminal.buffer.scrollBack, equals(0));
      expect(terminal.buffer.absoluteCursorY, equals(0));

      // Now run `free -h` at top of cleared screen
      terminal.write('[hhjmk@arch ~]\$ free -h\r\n');
      coordinator.notifyUserInput('free -h\n');
      coordinator.observeOutput('[hhjmk@arch ~]\$ free -h\r\n');
      const freeOut =
          '               total        used        free      shared  buff/cache   available\r\n'
          'Mem:           7.7Gi       2.1Gi       3.4Gi        52Mi       2.2Gi       5.3Gi\r\n'
          'Swap:          2.0Gi       256Mi       1.7Gi\r\n'
          '[hhjmk@arch ~]\$ ';
      terminal.write(freeOut);
      coordinator.observeOutput(freeOut);

      expect(coordinator.blocks.length, equals(1));
      final block = coordinator.blocks.first;
      expect(block.currentStartLine, equals(0));
      expect(block.currentEndLine, equals(4));
      expect(terminalController.hiddenLineIndices, equals({1, 2, 3}));

      // Toggle fullscreen override
      coordinator.toggleBlockFullscreen(block, currentlyFullscreen: false);
      expect(block.isFullscreenOverride, isTrue);

      // Close chart (switch to raw)
      coordinator.toggleBlockMode(block);
      expect(block.isRenderMode, isFalse);
      expect(terminalController.hiddenLineIndices, isEmpty);
    });

    test('reverts old chart to raw when any new non-chart command is executed', () {
      final terminal = Terminal();
      final scrollController = ScrollController();
      final terminalController = TerminalController();
      final coordinator = TerminalChartCoordinator(
        terminal: terminal,
        scrollController: scrollController,
        terminalController: terminalController,
      );

      // 1. Run free -h -> chart active
      terminal.write('[hhjmk@arch ~]\$ free -h\r\n');
      coordinator.notifyUserInput('free -h\n');
      coordinator.observeOutput('[hhjmk@arch ~]\$ free -h\r\n');
      const freeOut =
          '               total        used        free      shared  buff/cache   available\r\n'
          'Mem:           7.7Gi       2.1Gi       3.4Gi        52Mi       2.2Gi       5.3Gi\r\n'
          'Swap:          2.0Gi       256Mi       1.7Gi\r\n'
          '[hhjmk@arch ~]\$ ';
      terminal.write(freeOut);
      coordinator.observeOutput(freeOut);

      expect(coordinator.blocks.length, equals(1));
      expect(coordinator.hasActiveRenderBlock, isTrue);
      expect(terminalController.hiddenLineIndices, isNotEmpty);

      // 2. User types an arbitrary new command (e.g. ls -la)
      terminal.write('ls -la\r\n');
      coordinator.notifyUserInput('ls -la\n');

      // The previous chart must immediately be closed and hidden lines cleared (reverted to raw)
      expect(coordinator.hasActiveRenderBlock, isFalse);
      expect(terminalController.hiddenLineIndices, isEmpty);
    });

    test('closeActiveCharts closes chart and returns true', () {
      final terminal = Terminal();
      final scrollController = ScrollController();
      final terminalController = TerminalController();
      final coordinator = TerminalChartCoordinator(
        terminal: terminal,
        scrollController: scrollController,
        terminalController: terminalController,
      );

      terminal.write('[hhjmk@arch ~]\$ free -h\r\n');
      coordinator.notifyUserInput('free -h\n');
      coordinator.observeOutput('[hhjmk@arch ~]\$ free -h\r\n');
      const freeOut =
          '               total        used        free      shared  buff/cache   available\r\n'
          'Mem:           7.7Gi       2.1Gi       3.4Gi        52Mi       2.2Gi       5.3Gi\r\n'
          'Swap:          2.0Gi       256Mi       1.7Gi\r\n'
          '[hhjmk@arch ~]\$ ';
      terminal.write(freeOut);
      coordinator.observeOutput(freeOut);

      expect(coordinator.hasActiveRenderBlock, isTrue);

      final closed = coordinator.closeActiveCharts();
      expect(closed, isTrue);
      expect(coordinator.hasActiveRenderBlock, isFalse);
      expect(terminalController.hiddenLineIndices, isEmpty);

      // Calling again returns false when no active chart
      expect(coordinator.closeActiveCharts(), isFalse);
    });
  });
}
