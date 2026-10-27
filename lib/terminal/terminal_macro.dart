import 'dart:convert';
import 'dart:typed_data';

class TerminalMacroParameter {
  const TerminalMacroParameter({
    required this.name,
    required this.isSecret,
    this.defaultValue,
  });

  final String name;
  final bool isSecret;
  final String? defaultValue;
}

class TerminalMacroPlan {
  TerminalMacroPlan({
    required List<String> commands,
    required List<String> reviewCommands,
    required this.usesSecret,
  }) : commands = List.unmodifiable(commands),
       reviewCommands = List.unmodifiable(reviewCommands);

  final List<String> commands;
  final List<String> reviewCommands;
  final bool usesSecret;
}

class TerminalMacro {
  factory TerminalMacro({
    required String id,
    required String name,
    required List<String> commands,
  }) =>
      TerminalMacro.fromScript(id: id, name: name, script: commands.join('\n'));

  factory TerminalMacro.fromScript({
    required String id,
    required String name,
    required String script,
  }) {
    final normalizedName = name.trim();
    _validateIdentity(id, normalizedName);
    final normalizedScript = _normalizeScript(script);
    final parsed = _TerminalMacroParser(normalizedScript).parse();
    return TerminalMacro._(
      id: id,
      name: normalizedName,
      script: normalizedScript,
      commands: parsed.commandTemplates,
      parameters: parsed.parameters,
      nodes: parsed.nodes,
      isStructured: parsed.isStructured,
    );
  }

  factory TerminalMacro._({
    required String id,
    required String name,
    required String script,
    required List<String> commands,
    required List<TerminalMacroParameter> parameters,
    required List<_MacroNode> nodes,
    required bool isStructured,
  }) => TerminalMacro._internal(
    id: id,
    name: name,
    script: script,
    commands: commands,
    parameters: parameters,
    nodes: nodes,
    isStructured: isStructured,
  );

  TerminalMacro._internal({
    required this.id,
    required this.name,
    required this.script,
    required List<String> commands,
    required List<TerminalMacroParameter> parameters,
    required List<_MacroNode> nodes,
    required this.isStructured,
  }) : commands = List.unmodifiable(commands),
       parameters = List.unmodifiable(parameters),
       _nodes = List.unmodifiable(nodes);

  static const maxNameLength = 80;
  static const maxCommands = 40;
  static const maxCommandLength = 4096;
  static const maxScriptLength = 16384;
  static const maxScriptLines = 160;
  static const maxParameters = 12;
  static const maxParameterLength = 256;

  final String id;
  final String name;
  final String script;

  /// Command templates from all branches, before variable expansion.
  final List<String> commands;
  final List<TerminalMacroParameter> parameters;
  final bool isStructured;
  final List<_MacroNode> _nodes;

  static List<String> parseScript(String script) =>
      _TerminalMacroParser(_normalizeScript(script)).parse().commandTemplates;

  Map<String, Object> toJson() => {'id': id, 'name': name, 'script': script};

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

  TerminalMacroPlan prepare(Map<String, String> suppliedValues) {
    final knownNames = parameters.map((parameter) => parameter.name).toSet();
    for (final name in suppliedValues.keys) {
      if (!knownNames.contains(name)) {
        throw FormatException('未声明变量 $name');
      }
    }

    final variables = <String, String>{};
    final secretNames = <String>{};
    for (final parameter in parameters) {
      final value = suppliedValues[parameter.name] ?? parameter.defaultValue;
      if (value == null ||
          ((parameter.isSecret || parameter.defaultValue == null) &&
              value.isEmpty)) {
        throw FormatException('变量 ${parameter.name} 需要填写');
      }
      _validateParameterValue(parameter.name, value);
      variables[parameter.name] = value;
      if (parameter.isSecret) secretNames.add(parameter.name);
    }

    final resolved = <String>[];
    final reviewed = <String>[];
    var usesSecret = false;
    var totalBytes = 0;

    void expand(List<_MacroNode> nodes) {
      for (final node in nodes) {
        switch (node) {
          case _MacroCommand(:final template, :final lineNumber):
            final variablePattern = RegExp(r'\$\{([A-Z][A-Z0-9_]*)\}');
            var commandUsesSecret = false;
            String substitute(Match match, {required bool review}) {
              final name = match.group(1)!;
              final value = variables[name];
              if (value == null) {
                throw FormatException('第 $lineNumber 行变量 $name 尚未赋值');
              }
              if (secretNames.contains(name)) {
                commandUsesSecret = true;
                return review ? '<已遮蔽变量:$name>' : value;
              }
              return value;
            }

            final command = template.replaceAllMapped(
              variablePattern,
              (match) => substitute(match, review: false),
            );
            final reviewCommand = template.replaceAllMapped(
              variablePattern,
              (match) => substitute(match, review: true),
            );
            if (command.length > maxCommandLength) {
              throw FormatException('第 $lineNumber 行展开后超过 4096 个字符');
            }
            if (resolved.length >= maxCommands) {
              throw const FormatException('展开后最多执行 40 条命令');
            }
            totalBytes += utf8.encode(command).length + 1;
            if (totalBytes > maxScriptLength) {
              throw const FormatException('展开后的命令总长度不能超过 16 KiB');
            }
            resolved.add(command);
            reviewed.add(reviewCommand);
            usesSecret = usesSecret || commandUsesSecret;
          case _MacroCondition(
            :final variable,
            :final equals,
            :final expected,
            :final whenTrue,
            :final whenFalse,
          ):
            final actual = variables[variable];
            if (actual == null) {
              throw FormatException('条件变量 $variable 尚未赋值');
            }
            final matches = actual == expected;
            expand(matches == equals ? whenTrue : whenFalse);
          case _MacroRepeat(:final count, :final variable, :final body):
            for (var index = 1; index <= count; index++) {
              if (variable != null) variables[variable] = '$index';
              expand(body);
            }
            if (variable != null) variables.remove(variable);
        }
      }
    }

    expand(_nodes);
    if (resolved.isEmpty) {
      throw const FormatException('脚本展开后没有可执行命令');
    }
    return TerminalMacroPlan(
      commands: resolved,
      reviewCommands: reviewed,
      usesSecret: usesSecret,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TerminalMacro &&
      other.id == id &&
      other.name == name &&
      other.script == script;

  @override
  int get hashCode => Object.hash(id, name, script);
}

String _normalizeScript(String script) {
  var normalized = script.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final lines = normalized.split('\n');
  while (lines.isNotEmpty && lines.first.trim().isEmpty) {
    lines.removeAt(0);
  }
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines.removeLast();
  }
  normalized = lines.join('\n');
  if (normalized.trim().isEmpty) {
    throw const FormatException('请输入至少一条命令');
  }
  if (utf8.encode(normalized).length > TerminalMacro.maxScriptLength) {
    throw const FormatException('宏脚本不能超过 16 KiB');
  }
  if (lines.length > TerminalMacro.maxScriptLines) {
    throw FormatException('宏脚本不能超过 ${TerminalMacro.maxScriptLines} 行');
  }
  for (var index = 0; index < lines.length; index++) {
    if (lines[index].codeUnits.any(
      (unit) => unit == 0x7f || (unit < 0x20 && unit != 0x09),
    )) {
      throw FormatException('第 ${index + 1} 行包含不允许的控制字符');
    }
  }
  return normalized;
}

void _validateIdentity(String id, String name) {
  if (id.trim().isEmpty || id.length > 120) {
    throw const FormatException('命令宏 ID 无效');
  }
  if (name.isEmpty || name.length > TerminalMacro.maxNameLength) {
    throw const FormatException('宏名称必须为 1–80 个字符');
  }
  if (name.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    throw const FormatException('宏名称不能包含控制字符');
  }
}

void _validateParameterValue(String name, String value) {
  if (value.length > TerminalMacro.maxParameterLength ||
      utf8.encode(value).length > TerminalMacro.maxParameterLength * 4) {
    throw FormatException(
      '变量 $name 不能超过 ${TerminalMacro.maxParameterLength} 个字符',
    );
  }
  if (value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    throw FormatException('变量 $name 不能包含换行或控制字符');
  }
}

class _TerminalMacroParser {
  _TerminalMacroParser(this.script) : _lines = script.split('\n');

  static final _namePattern = RegExp(r'^[A-Z][A-Z0-9_]{0,31}$');
  static final _parameterPattern = RegExp(
    r'^@param\s+([A-Z][A-Z0-9_]{0,31})(?:=(.*))?$',
  );
  static final _secretPattern = RegExp(r'^@secret\s+([A-Z][A-Z0-9_]{0,31})$');
  static final _conditionPattern = RegExp(
    r'^@if\s+([A-Z][A-Z0-9_]{0,31})\s+(==|!=)\s+(.+)$',
  );
  static final _repeatPattern = RegExp(
    r'^@repeat\s+(\d{1,2})(?:\s+as\s+([A-Z][A-Z0-9_]{0,31}))?$',
  );
  static final _placeholderPattern = RegExp(r'\$\{([^}]+)\}');
  static final _validPlaceholderPattern = RegExp(r'\$\{([A-Z][A-Z0-9_]*)\}');

  final String script;
  final List<String> _lines;
  final List<TerminalMacroParameter> _parameters = [];
  final Set<String> _declaredParameters = {};
  int _index = 0;
  bool _bodyStarted = false;
  bool _isStructured = false;

  _MacroParseResult parse() {
    final block = _parseBlock(const {}, depth: 0);
    if (block.terminator != null) {
      throw FormatException('第 $_index 行出现了未匹配的 ${block.terminator} 指令');
    }
    final templates = <String>[];
    _collectTemplates(block.nodes, templates);
    if (templates.isEmpty) {
      throw const FormatException('脚本至少需要一条命令');
    }
    if (_maximumExpandedCommands(block.nodes) > TerminalMacro.maxCommands) {
      throw const FormatException('任一执行分支展开后最多包含 40 条命令');
    }
    return _MacroParseResult(
      nodes: block.nodes,
      commandTemplates: List.unmodifiable(templates),
      parameters: List.unmodifiable(_parameters),
      isStructured: _isStructured,
    );
  }

  _ParsedBlock _parseBlock(
    Set<String> inheritedVariables, {
    required int depth,
  }) {
    final variables = Set<String>.of(inheritedVariables);
    final nodes = <_MacroNode>[];
    while (_index < _lines.length) {
      final lineNumber = _index + 1;
      final sourceLine = _lines[_index++];
      final directive = sourceLine.trim();
      if (directive.isEmpty || directive.startsWith('#')) continue;
      if (directive == '@else' ||
          directive == '@endif' ||
          directive == '@end') {
        return _ParsedBlock(nodes, directive);
      }

      final parameterMatch = _parameterPattern.firstMatch(directive);
      if (parameterMatch != null) {
        if (depth != 0 || _bodyStarted) {
          throw FormatException('第 $lineNumber 行变量声明必须放在脚本开头');
        }
        final name = parameterMatch.group(1)!;
        final defaultValue = parameterMatch.group(2);
        _addParameter(name, isSecret: false, defaultValue: defaultValue);
        variables.add(name);
        continue;
      }
      final secretMatch = _secretPattern.firstMatch(directive);
      if (secretMatch != null) {
        if (depth != 0 || _bodyStarted) {
          throw FormatException('第 $lineNumber 行变量声明必须放在脚本开头');
        }
        final name = secretMatch.group(1)!;
        _addParameter(name, isSecret: true);
        variables.add(name);
        continue;
      }

      final conditionMatch = _conditionPattern.firstMatch(directive);
      if (conditionMatch != null) {
        _bodyStarted = true;
        _isStructured = true;
        _checkDepth(depth, lineNumber);
        final variable = conditionMatch.group(1)!;
        if (!variables.contains(variable)) {
          throw FormatException('第 $lineNumber 行条件引用了未声明变量 $variable');
        }
        final equals = conditionMatch.group(2) == '==';
        final expected = _parseConditionValue(
          conditionMatch.group(3)!.trim(),
          lineNumber,
        );
        final trueBlock = _parseBlock(variables, depth: depth + 1);
        List<_MacroNode> whenFalse = const [];
        if (trueBlock.terminator == '@else') {
          final falseBlock = _parseBlock(variables, depth: depth + 1);
          if (falseBlock.terminator != '@endif') {
            throw FormatException('第 $lineNumber 行 @if 缺少 @endif');
          }
          whenFalse = falseBlock.nodes;
        } else if (trueBlock.terminator != '@endif') {
          throw FormatException('第 $lineNumber 行 @if 缺少 @endif');
        }
        nodes.add(
          _MacroCondition(
            variable: variable,
            equals: equals,
            expected: expected,
            whenTrue: trueBlock.nodes,
            whenFalse: whenFalse,
          ),
        );
        continue;
      }

      final repeatMatch = _repeatPattern.firstMatch(directive);
      if (repeatMatch != null) {
        _bodyStarted = true;
        _isStructured = true;
        _checkDepth(depth, lineNumber);
        final count = int.parse(repeatMatch.group(1)!);
        if (count < 1 || count > 20) {
          throw FormatException('第 $lineNumber 行 @repeat 次数必须在 1 到 20 之间');
        }
        final variable = repeatMatch.group(2);
        final bodyVariables = Set<String>.of(variables);
        if (variable != null) {
          if (variables.contains(variable)) {
            throw FormatException('第 $lineNumber 行循环变量 $variable 已存在');
          }
          bodyVariables.add(variable);
        }
        final body = _parseBlock(bodyVariables, depth: depth + 1);
        if (body.terminator != '@end') {
          throw FormatException('第 $lineNumber 行 @repeat 缺少 @end');
        }
        nodes.add(
          _MacroRepeat(count: count, variable: variable, body: body.nodes),
        );
        continue;
      }

      if (directive.startsWith('@')) {
        throw FormatException('第 $lineNumber 行脚本指令无效：$directive');
      }
      _bodyStarted = true;
      _validateTemplate(sourceLine, variables, lineNumber);
      nodes.add(_MacroCommand(sourceLine, lineNumber));
    }
    return _ParsedBlock(nodes, null);
  }

  void _addParameter(
    String name, {
    required bool isSecret,
    String? defaultValue,
  }) {
    if (!_namePattern.hasMatch(name)) {
      throw FormatException('变量名 $name 必须为大写字母、数字或下划线');
    }
    if (_declaredParameters.contains(name)) {
      throw FormatException('变量 $name 重复声明');
    }
    if (_parameters.length >= TerminalMacro.maxParameters) {
      throw FormatException('脚本最多声明 ${TerminalMacro.maxParameters} 个变量');
    }
    if (isSecret && defaultValue != null) {
      throw FormatException('秘密变量 $name 不能保存默认值');
    }
    if (defaultValue != null) _validateParameterValue(name, defaultValue);
    _declaredParameters.add(name);
    _parameters.add(
      TerminalMacroParameter(
        name: name,
        isSecret: isSecret,
        defaultValue: defaultValue,
      ),
    );
    _isStructured = true;
  }

  void _validateTemplate(
    String template,
    Set<String> variables,
    int lineNumber,
  ) {
    for (final match in _placeholderPattern.allMatches(template)) {
      final full = match.group(0)!;
      final valid = _validPlaceholderPattern.firstMatch(full);
      if (valid == null) {
        throw FormatException('第 $lineNumber 行变量格式无效：$full');
      }
      final name = valid.group(1)!;
      if (!variables.contains(name)) {
        throw FormatException('第 $lineNumber 行引用了未声明变量 $name');
      }
    }
  }

  String _parseConditionValue(String raw, int lineNumber) {
    if (raw.startsWith('"')) {
      try {
        final value = jsonDecode(raw);
        if (value is String) return value;
      } on FormatException {
        // Re-throw below with a line-specific script diagnostic.
      }
      throw FormatException('第 $lineNumber 行条件值的引号格式无效');
    }
    if (raw.isEmpty || raw.contains(RegExp(r'\s|["\x27]'))) {
      throw FormatException('第 $lineNumber 行带空格的条件值请使用双引号包裹');
    }
    return raw;
  }

  void _checkDepth(int depth, int lineNumber) {
    if (depth >= 4) {
      throw FormatException('第 $lineNumber 行脚本嵌套不能超过 4 层');
    }
  }

  void _collectTemplates(List<_MacroNode> nodes, List<String> output) {
    for (final node in nodes) {
      switch (node) {
        case _MacroCommand(:final template):
          output.add(template);
        case _MacroCondition(:final whenTrue, :final whenFalse):
          _collectTemplates(whenTrue, output);
          _collectTemplates(whenFalse, output);
        case _MacroRepeat(:final body):
          _collectTemplates(body, output);
      }
    }
  }

  int _maximumExpandedCommands(List<_MacroNode> nodes) {
    var count = 0;
    for (final node in nodes) {
      switch (node) {
        case _MacroCommand():
          count++;
        case _MacroCondition(:final whenTrue, :final whenFalse):
          final trueCount = _maximumExpandedCommands(whenTrue);
          final falseCount = _maximumExpandedCommands(whenFalse);
          count += trueCount > falseCount ? trueCount : falseCount;
        case _MacroRepeat(count: final repeatCount, body: final body):
          count += repeatCount * _maximumExpandedCommands(body);
      }
      if (count > TerminalMacro.maxCommands) return count;
    }
    return count;
  }
}

class _MacroParseResult {
  const _MacroParseResult({
    required this.nodes,
    required this.commandTemplates,
    required this.parameters,
    required this.isStructured,
  });

  final List<_MacroNode> nodes;
  final List<String> commandTemplates;
  final List<TerminalMacroParameter> parameters;
  final bool isStructured;
}

class _ParsedBlock {
  const _ParsedBlock(this.nodes, this.terminator);

  final List<_MacroNode> nodes;
  final String? terminator;
}

abstract class _MacroNode {}

class _MacroCommand extends _MacroNode {
  _MacroCommand(this.template, this.lineNumber);

  final String template;
  final int lineNumber;
}

class _MacroCondition extends _MacroNode {
  _MacroCondition({
    required this.variable,
    required this.equals,
    required this.expected,
    required this.whenTrue,
    required this.whenFalse,
  });

  final String variable;
  final bool equals;
  final String expected;
  final List<_MacroNode> whenTrue;
  final List<_MacroNode> whenFalse;
}

class _MacroRepeat extends _MacroNode {
  _MacroRepeat({
    required this.count,
    required this.variable,
    required this.body,
  });

  final int count;
  final String? variable;
  final List<_MacroNode> body;
}

/// Sends each expanded command with a terminal Enter, stopping when the target changes.
Future<int> executeTerminalMacroCommands({
  required TerminalMacro macro,
  List<String>? commands,
  required bool Function(int completedCommands) canContinue,
  required Future<void> Function(Uint8List input) write,
}) async {
  var completed = 0;
  for (final command in commands ?? macro.commands) {
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
