import 'dart:convert';
import 'dart:typed_data';

class TerminalMacro {
  TerminalMacro({
    required this.id,
    required String name,
    required List<String> commands,
  }) : name = name.trim(),
       commands = List.unmodifiable(commands) {
    _validate();
  }

  static const maxNameLength = 80;
  static const maxCommands = 40;
  static const maxCommandLength = 4096;
  static const maxScriptLength = 16384;

  final String id;
  final String name;
  final List<String> commands;

  String get script => commands.join('\n');

  static List<String> parseScript(String script) {
    var normalized = script.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = normalized.split('\n');
    while (lines.isNotEmpty && lines.first.trim().isEmpty) {
      lines.removeAt(0);
    }
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    normalized = lines.join('\n');
    if (normalized.isEmpty) {
      throw const FormatException('请输入至少一条命令');
    }
    if (utf8.encode(normalized).length > maxScriptLength) {
      throw const FormatException('宏脚本不能超过 16 KiB');
    }
    final commands = lines;
    if (commands.length > maxCommands) {
      throw const FormatException('宏最多包含 40 条命令');
    }
    for (var index = 0; index < commands.length; index++) {
      final command = commands[index];
      if (command.trim().isEmpty) {
        throw FormatException('第 ${index + 1} 行为空；宏中的每一行都必须是命令');
      }
      if (command.length > maxCommandLength) {
        throw FormatException('第 ${index + 1} 行超过 4096 个字符');
      }
      if (command.codeUnits.any(
        (unit) => unit == 0x7f || (unit < 0x20 && unit != 0x09),
      )) {
        throw FormatException('第 ${index + 1} 行包含不允许的控制字符');
      }
    }
    return List.unmodifiable(commands);
  }

  Map<String, Object> toJson() => {'id': id, 'name': name, 'script': script};

  factory TerminalMacro.fromScript({
    required String id,
    required String name,
    required String script,
  }) => TerminalMacro(id: id, name: name, commands: parseScript(script));

  factory TerminalMacro.fromJson(String encoded) {
    final value = jsonDecode(encoded);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('命令宏格式无效');
    }
    final id = value['id'];
    final name = value['name'];
    final script = value['script'];
    if (id is! String || id.trim().isEmpty || name is! String) {
      throw const FormatException('命令宏需要有效 ID 和名称');
    }
    if (script is! String) {
      throw const FormatException('命令宏缺少脚本');
    }
    return TerminalMacro.fromScript(id: id, name: name, script: script);
  }

  void _validate() {
    if (id.trim().isEmpty || id.length > 120) {
      throw const FormatException('命令宏 ID 无效');
    }
    if (name.isEmpty || name.length > maxNameLength) {
      throw const FormatException('宏名称必须为 1–80 个字符');
    }
    if (name.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      throw const FormatException('宏名称不能包含控制字符');
    }
    if (commands.isEmpty || commands.length > maxCommands) {
      throw const FormatException('宏必须包含 1–40 条命令');
    }
    final parsed = parseScript(commands.join('\n'));
    if (parsed.length != commands.length) {
      throw const FormatException('宏命令列表无效');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is TerminalMacro &&
      other.id == id &&
      other.name == name &&
      _listEquals(other.commands, commands);

  @override
  int get hashCode => Object.hash(id, name, Object.hashAll(commands));
}

bool _listEquals(List<String> first, List<String> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}

/// Sends each command with a terminal Enter, stopping when the target changes.
Future<int> executeTerminalMacroCommands({
  required TerminalMacro macro,
  required bool Function(int completedCommands) canContinue,
  required Future<void> Function(Uint8List input) write,
}) async {
  var completed = 0;
  for (final command in macro.commands) {
    if (!canContinue(completed)) {
      throw TerminalMacroStoppedException(completed);
    }
    try {
      await write(Uint8List.fromList(utf8.encode('$command\r')));
    } catch (error) {
      throw TerminalMacroWriteException(completed, error);
    }
    completed++;
  }
  return completed;
}

class TerminalMacroStoppedException implements Exception {
  const TerminalMacroStoppedException(this.completedCommands);

  final int completedCommands;

  @override
  String toString() => '执行已停止；已发送 $completedCommands 条命令';
}

class TerminalMacroWriteException implements Exception {
  const TerminalMacroWriteException(this.completedCommands, this.cause);

  final int completedCommands;
  final Object cause;

  @override
  String toString() => cause.toString();
}
