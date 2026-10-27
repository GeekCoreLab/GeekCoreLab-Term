import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/terminal_transcript.dart';

void main() {
  group('TerminalTranscript', () {
    test('records UTF-8 output only while recording', () {
      final transcript = TerminalTranscript();
      expect(transcript.append('ignored'), TranscriptAppendResult.ignored);

      transcript.start('session header\n');
      expect(transcript.append('服务器已连接\n'), TranscriptAppendResult.recorded);
      transcript.stop();
      expect(transcript.append('not recorded'), TranscriptAppendResult.ignored);
      expect(transcript.snapshot(), utf8.encode('session header\n服务器已连接\n'));
    });

    test('stops at the size cap and writes a marker within the cap', () {
      const maxBytes = 128;
      final transcript = TerminalTranscript(maxBytes: maxBytes);
      transcript.start('');

      final result = transcript.append(
        List<String>.filled(maxBytes + 1, 'x').join(),
      );

      expect(result, TranscriptAppendResult.limitReached);
      expect(transcript.isRecording, isFalse);
      expect(transcript.byteLength, lessThanOrEqualTo(maxBytes));
      expect(
        transcript.snapshot().toList(),
        containsAllInOrder('[transcript stopped at 10 MiB]'.codeUnits),
      );
    });

    test('keeps truncated UTF-8 output valid at the byte cap', () {
      final transcript = TerminalTranscript(maxBytes: 80)..start('');

      expect(
        transcript.append(List<String>.filled(40, '🙂').join()),
        TranscriptAppendResult.limitReached,
      );

      expect(() => utf8.decode(transcript.snapshot()), returnsNormally);
    });

    test('clear releases data and resets the recorder', () {
      final transcript = TerminalTranscript()..start('header');
      transcript.append('output');
      transcript.clear();

      expect(transcript.hasData, isFalse);
      expect(transcript.byteLength, 0);
      expect(transcript.isRecording, isFalse);
      expect(transcript.snapshot(), isEmpty);
    });
  });
}
