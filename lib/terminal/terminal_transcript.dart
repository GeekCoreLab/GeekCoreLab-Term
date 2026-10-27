import 'dart:convert';
import 'dart:typed_data';

enum TranscriptAppendResult { ignored, recorded, limitReached }

class TerminalTranscript {
  static const defaultMaxBytes = 10 * 1024 * 1024;
  static const _limitMarker = '\n[transcript stopped at 10 MiB]\n';

  TerminalTranscript({this.maxBytes = defaultMaxBytes});

  final int maxBytes;

  final BytesBuilder _buffer = BytesBuilder(copy: false);
  int _byteLength = 0;
  bool isRecording = false;

  bool get hasData => _byteLength > 0;
  int get byteLength => _byteLength;

  void start(String header) {
    clear();
    isRecording = true;
    append(header);
  }

  TranscriptAppendResult append(String value) {
    if (!isRecording) return TranscriptAppendResult.ignored;
    final bytes = utf8.encode(value);
    if (_byteLength + bytes.length > maxBytes) {
      final marker = utf8.encode(_limitMarker);
      final contentLimit = maxBytes - marker.length;
      final available = contentLimit - _byteLength;
      if (available > 0) _appendUtf8Prefix(bytes, available);
      if (_byteLength + marker.length <= maxBytes) _appendBytes(marker);
      isRecording = false;
      return TranscriptAppendResult.limitReached;
    }
    _appendBytes(bytes);
    return TranscriptAppendResult.recorded;
  }

  Uint8List snapshot() => _buffer.toBytes();

  void stop() => isRecording = false;

  void clear() {
    _buffer.takeBytes();
    _byteLength = 0;
    isRecording = false;
  }

  void _appendBytes(List<int> bytes) {
    _buffer.add(bytes);
    _byteLength += bytes.length;
  }

  void _appendUtf8Prefix(List<int> bytes, int maximumLength) {
    var length = maximumLength.clamp(0, bytes.length);
    while (length > 0) {
      try {
        _appendBytes(utf8.encode(utf8.decode(bytes.sublist(0, length))));
        return;
      } on FormatException {
        length--;
      }
    }
  }
}
