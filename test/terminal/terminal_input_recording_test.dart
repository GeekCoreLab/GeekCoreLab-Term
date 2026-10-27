import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/terminal_input_recording.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('records UTF-8, control keys, bounded delays, and safe preview', () {
    final recorder = TerminalInputRecorder()..start();
    final start = DateTime.utc(2026, 10, 27);

    expect(recorder.record('中文', receivedAt: start), isTrue);
    expect(
      recorder.record(
        '\r\u001b',
        receivedAt: start.add(const Duration(seconds: 3)),
      ),
      isTrue,
    );
    final macro = recorder.snapshot(id: 'keys-1', name: '测试输入');

    expect(macro.totalBytes, utf8.encode('中文\r\u001b').length);
    expect(macro.events.map((event) => event.delayMs), [0, 1000]);
    expect(macro.preview, '中文␍␛');
    expect(TerminalRecordedMacro.fromJson(jsonEncode(macro.toJson())), macro);
  });

  test('stops at the recording limit without losing accepted input', () {
    final recorder = TerminalInputRecorder()..start();

    expect(
      recorder.record('a'.padRight(TerminalRecordedMacro.maxBytes)),
      isTrue,
    );
    expect(recorder.record('overflow'), isFalse);
    expect(recorder.isRecording, isFalse);
    expect(recorder.hitLimit, isTrue);
    expect(recorder.totalBytes, TerminalRecordedMacro.maxBytes);
    expect(recorder.hasData, isTrue);
  });

  test('replay preserves exact bytes and stops between events', () async {
    final macro = TerminalRecordedMacro(
      id: 'play-1',
      name: '完整输入',
      events: [
        TerminalRecordedInputEvent(bytes: [0xE4, 0xB8, 0xAD], delayMs: 0),
        TerminalRecordedInputEvent(bytes: [0x0D], delayMs: 0),
      ],
    );
    final sent = <List<int>>[];

    await expectLater(
      executeTerminalRecordedMacro(
        macro: macro,
        canContinue: (completed) => completed == 0,
        write: (input) async => sent.add(input.toList()),
      ),
      throwsA(
        isA<TerminalRecordingStoppedException>().having(
          (error) => error.completedEvents,
          'completedEvents',
          1,
        ),
      ),
    );
    expect(sent, [utf8.encode('中')]);
  });

  test(
    'reports a failed write with the number of completed input events',
    () async {
      final macro = TerminalRecordedMacro(
        id: 'play-failure',
        name: '写入失败',
        events: [
          TerminalRecordedInputEvent(bytes: [0x61], delayMs: 0),
          TerminalRecordedInputEvent(bytes: [0x62], delayMs: 0),
        ],
      );
      var writes = 0;

      await expectLater(
        executeTerminalRecordedMacro(
          macro: macro,
          canContinue: (_) => true,
          write: (_) async {
            writes++;
            if (writes == 2) throw StateError('断开');
          },
        ),
        throwsA(
          isA<TerminalRecordingWriteException>().having(
            (error) => error.completedEvents,
            'completedEvents',
            1,
          ),
        ),
      );
    },
  );

  test(
    'run control stops the next input after the current write completes',
    () async {
      final macro = TerminalRecordedMacro(
        id: 'play-cancel',
        name: '可停止回放',
        events: [
          TerminalRecordedInputEvent(bytes: [0x61], delayMs: 0),
          TerminalRecordedInputEvent(bytes: [0x62], delayMs: 0),
        ],
      );
      final control = TerminalRecordedMacroRunControl();
      final sent = <int>[];

      await expectLater(
        executeTerminalRecordedMacro(
          macro: macro,
          canContinue: (_) => !control.isCancelled,
          write: (input) async {
            sent.add(input.single);
            control.cancel();
          },
        ),
        throwsA(isA<TerminalRecordingStoppedException>()),
      );
      expect(sent, [0x61]);
    },
  );

  test('xterm reports user input but excludes terminal-generated replies', () {
    final userInput = <String>[];
    final output = <String>[];
    final terminal = Terminal(onUserInput: userInput.add, onOutput: output.add);

    terminal.textInput('中文');
    terminal.paste('paste');
    terminal.charInput('['.codeUnitAt(0), ctrl: true);
    terminal.keyInput(TerminalKey.enter);
    terminal.write('\u001b[5n');

    expect(userInput, ['中文', 'paste', '\u001b', '\r']);
    expect(output.take(4), userInput);
    expect(output.skip(4), ['\u001b[0n']);
  });
}
