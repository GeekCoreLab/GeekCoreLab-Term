import 'package:flutter/services.dart';

enum TerminalShortcutAction {
  quickConnect,
  newLocalTerminal,
  copy,
  paste,
  search,
  closeTab,
  nextTab,
  previousTab,
}

extension TerminalShortcutActionPresentation on TerminalShortcutAction {
  String get label => switch (this) {
    TerminalShortcutAction.quickConnect => '快速连接',
    TerminalShortcutAction.newLocalTerminal => '新建本地终端',
    TerminalShortcutAction.copy => '复制选区',
    TerminalShortcutAction.paste => '粘贴剪贴板',
    TerminalShortcutAction.search => '搜索终端输出',
    TerminalShortcutAction.closeTab => '关闭当前标签',
    TerminalShortcutAction.nextTab => '切换到下一标签',
    TerminalShortcutAction.previousTab => '切换到上一标签',
  };
}

class TerminalShortcutBinding {
  const TerminalShortcutBinding({required this.keyId, this.shift = false});

  final int keyId;
  final bool shift;

  LogicalKeyboardKey get key =>
      LogicalKeyboardKey.findKeyByKeyId(keyId) ?? LogicalKeyboardKey(keyId);

  String label({required bool isMacOS}) => [
    isMacOS ? '⌘' : 'Ctrl',
    if (shift) 'Shift',
    key.keyLabel.isEmpty ? '未知键' : key.keyLabel,
  ].join('+');

  bool matches(
    KeyEvent event, {
    required bool primaryPressed,
    required bool shiftPressed,
    required bool altPressed,
  }) =>
      event is KeyDownEvent &&
      event.logicalKey.keyId == keyId &&
      primaryPressed &&
      !altPressed &&
      shiftPressed == shift;

  Map<String, Object> toJson() => {'keyId': keyId, 'shift': shift};

  factory TerminalShortcutBinding.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('快捷键格式无效');
    }
    final keyId = value['keyId'];
    final shift = value['shift'];
    if (keyId is! int || (shift != null && shift is! bool)) {
      throw const FormatException('快捷键字段无效');
    }
    final key = LogicalKeyboardKey.findKeyByKeyId(keyId);
    if (key == null || _isModifier(key)) {
      throw const FormatException('快捷键不能绑定修饰键');
    }
    return TerminalShortcutBinding(
      keyId: keyId,
      shift: shift as bool? ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TerminalShortcutBinding &&
      other.keyId == keyId &&
      other.shift == shift;

  @override
  int get hashCode => Object.hash(keyId, shift);
}

Map<TerminalShortcutAction, TerminalShortcutBinding>
get defaultTerminalShortcutBindings => Map.unmodifiable({
  TerminalShortcutAction.quickConnect: TerminalShortcutBinding(
    keyId: LogicalKeyboardKey.keyQ.keyId,
    shift: true,
  ),
  TerminalShortcutAction.newLocalTerminal: TerminalShortcutBinding(
    keyId: LogicalKeyboardKey.keyT.keyId,
    shift: true,
  ),
  TerminalShortcutAction.copy: TerminalShortcutBinding(
    keyId: LogicalKeyboardKey.keyC.keyId,
    shift: true,
  ),
  TerminalShortcutAction.paste: TerminalShortcutBinding(
    keyId: LogicalKeyboardKey.keyV.keyId,
    shift: true,
  ),
  TerminalShortcutAction.search: TerminalShortcutBinding(
    keyId: LogicalKeyboardKey.keyF.keyId,
  ),
  TerminalShortcutAction.closeTab: TerminalShortcutBinding(
    keyId: LogicalKeyboardKey.keyW.keyId,
  ),
  TerminalShortcutAction.nextTab: TerminalShortcutBinding(
    keyId: LogicalKeyboardKey.tab.keyId,
  ),
  TerminalShortcutAction.previousTab: TerminalShortcutBinding(
    keyId: LogicalKeyboardKey.tab.keyId,
    shift: true,
  ),
});

bool isTerminalShortcutModifier(LogicalKeyboardKey key) => _isModifier(key);

bool _isModifier(LogicalKeyboardKey key) => {
  LogicalKeyboardKey.shift.keyId,
  LogicalKeyboardKey.shiftLeft.keyId,
  LogicalKeyboardKey.shiftRight.keyId,
  LogicalKeyboardKey.control.keyId,
  LogicalKeyboardKey.controlLeft.keyId,
  LogicalKeyboardKey.controlRight.keyId,
  LogicalKeyboardKey.alt.keyId,
  LogicalKeyboardKey.altLeft.keyId,
  LogicalKeyboardKey.altRight.keyId,
  LogicalKeyboardKey.meta.keyId,
  LogicalKeyboardKey.metaLeft.keyId,
  LogicalKeyboardKey.metaRight.keyId,
}.contains(key.keyId);
