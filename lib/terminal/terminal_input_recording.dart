import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

class TerminalRecordedInputEvent {
  TerminalRecordedInputEvent({required List<int> bytes, required this.delayMs})
    : bytes = List.unmodifiable(bytes) {
    if (bytes.isEmpty || bytes.length > TerminalRecordedMacro.maxBytes) {
      throw const FormatException('录制宏输入片段长度无效');
    }
    if (delayMs < 0 || delayMs > TerminalRecordedMacro.maxDelayMs) {
      throw const FormatException('录制宏时间间隔无效');
    }
  }

  final List<int> bytes;
  final int delayMs;

  Map<String, Object> toJson() => {
    'data': base64Encode(bytes),
    'delayMs': delayMs,
  };

  @override
  bool operator ==(Object other) {
    if (other is! TerminalRecordedInputEvent ||
        other.delayMs != delayMs ||
        other.bytes.length != bytes.length) {
      return false;
    }
    for (var index = 0; index < bytes.length; index++) {
      if (bytes[index] != other.bytes[index]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(delayMs, Object.hashAll(bytes));

  factory TerminalRecordedInputEvent.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('录制宏事件格式无效');
    }
    final data = value['data'];
    final delayMs = value['delayMs'];
    if (data is! String || delayMs is! int) {
      throw const FormatException('录制宏事件缺少输入数据或时间间隔');
    }
    if (data.length > ((TerminalRecordedMacro.maxBytes + 2) ~/ 3) * 4) {
      throw const FormatException('录制宏输入片段超过大小限制');
    }
    try {
      return TerminalRecordedInputEvent(
        bytes: base64Decode(data),
        delayMs: delayMs,
      );
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('录制宏输入数据无效');
    }
  }
}

class TerminalRecordedMacro {
  TerminalRecordedMacro({
    required this.id,
    required String name,
    required List<TerminalRecordedInputEvent> events,
  }) : name = name.trim(),
       events = List.unmodifiable(events) {
    _validate();
  }

  static const maxNameLength = 80;
  static const maxSavedMacros = 32;
  static const maxEvents = 2048;
  static const maxBytes = 16 * 1024;
  static const maxDelayMs = 1000;

  final String id;
  final String name;
  final List<TerminalRecordedInputEvent> events;

  int get totalBytes =>
      events.fold(0, (total, event) => total + event.bytes.length);

  String get preview {
    final buffer = StringBuffer();
    for (final event in events) {
      buffer.write(_renderBytes(event.bytes));
    }
    return buffer.toString();
  }

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'events': events.map((event) => event.toJson()).toList(),
  };

  factory TerminalRecordedMacro.fromJson(String encoded) {
    final value = jsonDecode(encoded);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('录制宏格式无效');
    }
    final id = value['id'];
    final name = value['name'];
    final events = value['events'];
    if (id is! String || id.trim().isEmpty || name is! String) {
      throw const FormatException('录制宏需要有效 ID 和名称');
    }
    if (events is! List) {
      throw const FormatException('录制宏缺少输入事件');
    }
    if (events.length > maxEvents) {
      throw const FormatException('录制宏输入事件超过数量限制');
    }
    return TerminalRecordedMacro(
      id: id,
      name: name,
      events: events.map(TerminalRecordedInputEvent.fromJson).toList(),
    );
  }

  void _validate() {
    if (id.trim().isEmpty || id.length > 120) {
      throw const FormatException('录制宏 ID 无效');
    }
    if (name.isEmpty || name.length > maxNameLength) {
      throw const FormatException('录制宏名称必须为 1–80 个字符');
    }
    if (name.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      throw const FormatException('录制宏名称不能包含控制字符');
    }
    if (events.isEmpty || events.length > maxEvents) {
      throw const FormatException('录制宏必须包含 1–2048 个输入事件');
    }
    if (totalBytes > maxBytes) {
      throw const FormatException('录制宏输入总长度不能超过 16 KiB');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is TerminalRecordedMacro &&
      other.id == id &&
      other.name == name &&
      _eventsEqual(other.events, events);

  @override
  int get hashCode => Object.hash(id, name, Object.hashAll(events));
}

bool _eventsEqual(
  List<TerminalRecordedInputEvent> first,
  List<TerminalRecordedInputEvent> second,
) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    final left = first[index];
    final right = second[index];
    if (left.delayMs != right.delayMs ||
        left.bytes.length != right.bytes.length) {
      return false;
    }
    for (var byteIndex = 0; byteIndex < left.bytes.length; byteIndex++) {
      if (left.bytes[byteIndex] != right.bytes[byteIndex]) return false;
    }
  }
  return true;
}

String _renderBytes(List<int> bytes) {
  final buffer = StringBuffer();
  for (final rune in utf8.decode(bytes, allowMalformed: true).runes) {
    if (rune <= 0x1f || rune == 0x7f) {
      buffer.writeCharCode(rune == 0x7f ? 0x2421 : 0x2400 + rune);
    } else if (rune >= 0x80 && rune <= 0x9f) {
      buffer.write('<U+${rune.toRadixString(16).padLeft(4, '0')}>');
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

class TerminalInputRecorder {
  final List<TerminalRecordedInputEvent> _events = [];
  DateTime? _lastInputAt;
  int _totalBytes = 0;
  bool _isRecording = false;
  bool _hitLimit = false;

  bool get isRecording => _isRecording;
  bool get hasData => _events.isNotEmpty;
  bool get hitLimit => _hitLimit;
  int get eventCount => _events.length;
  int get totalBytes => _totalBytes;

  void start() {
    if (_isRecording) return;
    if (_events.isNotEmpty) {
      throw StateError('请先保存或丢弃上一段录制');
    }
    _lastInputAt = null;
    _totalBytes = 0;
    _hitLimit = false;
    _isRecording = true;
  }

  /// Returns false when the recording reaches a safety limit and stops.
  bool record(String input, {DateTime? receivedAt}) {
    if (!_isRecording || input.isEmpty) return _isRecording;
    final bytes = utf8.encode(input);
    if (_events.length >= TerminalRecordedMacro.maxEvents ||
        _totalBytes + bytes.length > TerminalRecordedMacro.maxBytes) {
      _isRecording = false;
      _hitLimit = true;
      return false;
    }

    final now = receivedAt ?? DateTime.now();
    final previousInputAt = _lastInputAt;
    final elapsedMs = previousInputAt == null
        ? null
        : now.difference(previousInputAt).inMilliseconds;
    final delayMs = elapsedMs == null
        ? 0
        : elapsedMs.clamp(0, TerminalRecordedMacro.maxDelayMs).toInt();
    _events.add(TerminalRecordedInputEvent(bytes: bytes, delayMs: delayMs));
    _totalBytes += bytes.length;
    _lastInputAt = now;
    return true;
  }

  void stop() {
    _isRecording = false;
  }

  TerminalRecordedMacro snapshot({required String id, required String name}) {
    stop();
    return TerminalRecordedMacro(id: id, name: name, events: _events);
  }

  void clear() {
    _isRecording = false;
    _hitLimit = false;
    _totalBytes = 0;
    _lastInputAt = null;
    _events.clear();
  }
}

class TerminalRecordedMacroRunControl {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
  }
}

Future<int> executeTerminalRecordedMacro({
  required TerminalRecordedMacro macro,
  required bool Function(int completedEvents) canContinue,
  required Future<void> Function(Uint8List input) write,
}) async {
  var completed = 0;
  for (final event in macro.events) {
    if (!canContinue(completed)) {
      throw TerminalRecordingStoppedException(completed);
    }
    if (event.delayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: event.delayMs));
      if (!canContinue(completed)) {
        throw TerminalRecordingStoppedException(completed);
      }
    }
    try {
      await write(Uint8List.fromList(event.bytes));
    } catch (error) {
      throw TerminalRecordingWriteException(completed, error);
    }
    completed++;
  }
  return completed;
}

class TerminalRecordingStoppedException implements Exception {
  const TerminalRecordingStoppedException(this.completedEvents);

  final int completedEvents;

  @override
  String toString() => '回放已停止；已发送 $completedEvents 个输入片段';
}

class TerminalRecordingWriteException implements Exception {
  const TerminalRecordingWriteException(this.completedEvents, this.cause);

  final int completedEvents;
  final Object cause;

  @override
  String toString() => cause.toString();
}
