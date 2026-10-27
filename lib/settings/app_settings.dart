import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import '../terminal/terminal_shortcuts.dart';
import '../terminal/terminal_keyword_highlights.dart';

enum AppThemeStyle { light, emerald, ocean, graphite }

enum TerminalFontFamily {
  system('monospace', '系统默认等宽'),
  jetBrainsMono('JetBrains Mono', 'JetBrains Mono'),
  cascadianMono('Cascadia Mono', 'Cascadia Mono'),
  firaCode('Fira Code', 'Fira Code'),
  notoSansMonoCjk('Noto Sans Mono CJK SC', 'Noto Sans Mono CJK SC');

  const TerminalFontFamily(this.familyName, this.label);

  final String familyName;
  final String label;

  static TerminalFontFamily fromName(String? name) =>
      values.where((family) => family.familyName == name).firstOrNull ?? system;
}

extension AppThemeStylePresentation on AppThemeStyle {
  String get label => switch (this) {
    AppThemeStyle.light => 'HexHub 浅色',
    AppThemeStyle.emerald => '翡翠深色',
    AppThemeStyle.ocean => '海洋深色',
    AppThemeStyle.graphite => '石墨深色',
  };

  Color get seedColor => switch (this) {
    AppThemeStyle.light => const Color(0xFF3578D4),
    AppThemeStyle.emerald => const Color(0xFF31C48D),
    AppThemeStyle.ocean => const Color(0xFF55A9E8),
    AppThemeStyle.graphite => const Color(0xFF9AA8B4),
  };

  Color get scaffoldColor => switch (this) {
    AppThemeStyle.light => const Color(0xFFF5F7FA),
    AppThemeStyle.emerald => const Color(0xFF101512),
    AppThemeStyle.ocean => const Color(0xFF10151B),
    AppThemeStyle.graphite => const Color(0xFF141619),
  };

  Color get terminalBackground => switch (this) {
    AppThemeStyle.light => const Color(0xFFFFFFFF),
    AppThemeStyle.emerald => const Color(0xFF0B0E0C),
    AppThemeStyle.ocean => const Color(0xFF0A1017),
    AppThemeStyle.graphite => const Color(0xFF101214),
  };

  Color get terminalForeground => switch (this) {
    AppThemeStyle.light => const Color(0xFF252A31),
    AppThemeStyle.emerald => const Color(0xFFCCCCCC),
    AppThemeStyle.ocean => const Color(0xFFD0DAE4),
    AppThemeStyle.graphite => const Color(0xFFD0D3D6),
  };

  bool get isLight => this == AppThemeStyle.light;

  static AppThemeStyle fromName(String? name) =>
      AppThemeStyle.values.where((style) => style.name == name).firstOrNull ??
      AppThemeStyle.light;
}

class WindowBounds {
  const WindowBounds({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  bool get isUsable =>
      left.isFinite &&
      top.isFinite &&
      width.isFinite &&
      height.isFinite &&
      width >= 900 &&
      height >= 560;
}

class AppSettingsController extends ChangeNotifier {
  AppSettingsController._({
    required this._preferences,
    required this._themeStyle,
    required double terminalFontSize,
    required TerminalFontFamily terminalFontFamily,
    required int sshKeepAliveSeconds,
    required this._rememberWindowBounds,
    required this._windowBounds,
    required this._terminalShortcuts,
    required List<TerminalKeywordRule> terminalKeywordRules,
    required this._startupSessionGroup,
    required String? passwordSalt,
    required String? passwordVerifier,
  }) : // The constructor uses a public named parameter for the private field.
       // ignore: prefer_initializing_formals
       _terminalFontSize = terminalFontSize,
       // ignore: prefer_initializing_formals
       _terminalFontFamily = terminalFontFamily,
       // ignore: prefer_initializing_formals
       _sshKeepAliveSeconds = sshKeepAliveSeconds,
       _terminalKeywordRules = List.unmodifiable(terminalKeywordRules),
       _passwordSalt = passwordSalt,
       _passwordVerifier = passwordVerifier,
       _isLocked = passwordSalt != null && passwordVerifier != null;

  static const _themeKey = 'geekcore_term.settings.theme.v1';
  static const _terminalFontSizeKey =
      'geekcore_term.settings.terminal_font_size.v1';
  static const _terminalFontFamilyKey =
      'geekcore_term.settings.terminal_font_family.v1';
  static const _sshKeepAliveSecondsKey =
      'geekcore_term.settings.ssh_keep_alive_seconds.v1';
  static const _rememberWindowKey = 'geekcore_term.settings.remember_window.v1';
  static const _windowLeftKey = 'geekcore_term.settings.window_left.v1';
  static const _windowTopKey = 'geekcore_term.settings.window_top.v1';
  static const _windowWidthKey = 'geekcore_term.settings.window_width.v1';
  static const _windowHeightKey = 'geekcore_term.settings.window_height.v1';
  static const _terminalShortcutsKey =
      'geekcore_term.settings.terminal_shortcuts.v1';
  static const _terminalKeywordRulesKey =
      'geekcore_term.settings.terminal_keyword_rules.v1';
  static const _startupSessionGroupKey =
      'geekcore_term.settings.startup_session_group.v1';
  static const _passwordSaltKey = 'geekcore_term.settings.password_salt.v1';
  static const _passwordVerifierKey =
      'geekcore_term.settings.password_verifier.v1';

  static const passwordIterations = 210000;
  static const sshKeepAliveOptions = [0, 10, 30, 60];

  final SharedPreferencesAsync _preferences;
  AppThemeStyle _themeStyle;
  double _terminalFontSize;
  TerminalFontFamily _terminalFontFamily;
  int _sshKeepAliveSeconds;
  Map<TerminalShortcutAction, TerminalShortcutBinding> _terminalShortcuts;
  List<TerminalKeywordRule> _terminalKeywordRules;
  String? _startupSessionGroup;
  bool _rememberWindowBounds;
  WindowBounds? _windowBounds;
  String? _passwordSalt;
  String? _passwordVerifier;
  bool _isLocked;

  static Future<AppSettingsController> load() async {
    final preferences = SharedPreferencesAsync();
    final salt = await preferences.getString(_passwordSaltKey);
    final verifier = await preferences.getString(_passwordVerifierKey);
    final left = await preferences.getDouble(_windowLeftKey);
    final top = await preferences.getDouble(_windowTopKey);
    final width = await preferences.getDouble(_windowWidthKey);
    final height = await preferences.getDouble(_windowHeightKey);
    final terminalFontSize = await preferences.getDouble(_terminalFontSizeKey);
    final terminalFontFamily = await preferences.getString(
      _terminalFontFamilyKey,
    );
    final sshKeepAliveSeconds = await preferences.getInt(
      _sshKeepAliveSecondsKey,
    );
    final terminalShortcuts = _parseTerminalShortcuts(
      await preferences.getString(_terminalShortcutsKey),
    );
    final terminalKeywordRules = _parseTerminalKeywordRules(
      await preferences.getString(_terminalKeywordRulesKey),
    );
    final startupSessionGroup = await preferences.getString(
      _startupSessionGroupKey,
    );
    final bounds =
        left == null || top == null || width == null || height == null
        ? null
        : WindowBounds(left: left, top: top, width: width, height: height);

    return AppSettingsController._(
      preferences: preferences,
      themeStyle: AppThemeStylePresentation.fromName(
        await preferences.getString(_themeKey),
      ),
      terminalFontSize: (terminalFontSize ?? 14).clamp(10, 24).toDouble(),
      terminalFontFamily: TerminalFontFamily.fromName(terminalFontFamily),
      sshKeepAliveSeconds: sshKeepAliveOptions.contains(sshKeepAliveSeconds)
          ? sshKeepAliveSeconds!
          : 10,
      rememberWindowBounds:
          await preferences.getBool(_rememberWindowKey) ?? true,
      windowBounds: bounds?.isUsable == true ? bounds : null,
      terminalShortcuts: terminalShortcuts,
      terminalKeywordRules: terminalKeywordRules,
      startupSessionGroup: startupSessionGroup,
      passwordSalt: salt,
      passwordVerifier: verifier,
    );
  }

  AppThemeStyle get themeStyle => _themeStyle;
  double get terminalFontSize => _terminalFontSize;
  TerminalFontFamily get terminalFontFamily => _terminalFontFamily;
  int get sshKeepAliveSeconds => _sshKeepAliveSeconds;
  Map<TerminalShortcutAction, TerminalShortcutBinding> get terminalShortcuts =>
      Map.unmodifiable(_terminalShortcuts);
  List<TerminalKeywordRule> get terminalKeywordRules =>
      List.unmodifiable(_terminalKeywordRules);
  String? get startupSessionGroup => _startupSessionGroup;
  bool get rememberWindowBounds => _rememberWindowBounds;
  WindowBounds? get windowBounds => _windowBounds;
  bool get hasMasterPassword =>
      _passwordSalt != null && _passwordVerifier != null;
  bool get isLocked => _isLocked;

  ThemeData get themeData {
    final scheme = ColorScheme.fromSeed(
      seedColor: _themeStyle.seedColor,
      brightness: _themeStyle.isLight ? Brightness.light : Brightness.dark,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: _themeStyle.scaffoldColor,
      dividerColor: scheme.outlineVariant,
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
    );
  }

  TerminalTheme get terminalTheme {
    final base = TerminalThemes.defaultTheme;
    return TerminalTheme(
      cursor: _themeStyle.seedColor,
      selection: _themeStyle.seedColor.withValues(alpha: 0.35),
      foreground: _themeStyle.terminalForeground,
      background: _themeStyle.terminalBackground,
      black: base.black,
      red: base.red,
      green: base.green,
      yellow: base.yellow,
      blue: base.blue,
      magenta: base.magenta,
      cyan: base.cyan,
      white: base.white,
      brightBlack: base.brightBlack,
      brightRed: base.brightRed,
      brightGreen: base.brightGreen,
      brightYellow: base.brightYellow,
      brightBlue: base.brightBlue,
      brightMagenta: base.brightMagenta,
      brightCyan: base.brightCyan,
      brightWhite: base.brightWhite,
      searchHitBackground: base.searchHitBackground,
      searchHitBackgroundCurrent: base.searchHitBackgroundCurrent,
      searchHitForeground: base.searchHitForeground,
    );
  }

  Future<void> setThemeStyle(AppThemeStyle style) async {
    if (_themeStyle == style) return;
    await _preferences.setString(_themeKey, style.name);
    _themeStyle = style;
    notifyListeners();
  }

  Future<void> setTerminalFontSize(double size) async {
    final normalized = size.clamp(10, 24).toDouble();
    if (_terminalFontSize == normalized) return;
    await _preferences.setDouble(_terminalFontSizeKey, normalized);
    _terminalFontSize = normalized;
    notifyListeners();
  }

  Future<void> setTerminalFontFamily(TerminalFontFamily family) async {
    if (_terminalFontFamily == family) return;
    await _preferences.setString(_terminalFontFamilyKey, family.familyName);
    _terminalFontFamily = family;
    notifyListeners();
  }

  Future<void> setSshKeepAliveSeconds(int seconds) async {
    if (!sshKeepAliveOptions.contains(seconds)) {
      throw ArgumentError.value(
        seconds,
        'seconds',
        'Unsupported SSH keep-alive interval',
      );
    }
    if (_sshKeepAliveSeconds == seconds) return;
    await _preferences.setInt(_sshKeepAliveSecondsKey, seconds);
    _sshKeepAliveSeconds = seconds;
    notifyListeners();
  }

  Future<void> setTerminalShortcut(
    TerminalShortcutAction action,
    TerminalShortcutBinding binding,
  ) async {
    final key = LogicalKeyboardKey.findKeyByKeyId(binding.keyId);
    if (key == null || isTerminalShortcutModifier(key)) {
      throw ArgumentError.value(binding, 'binding', '快捷键组合无效');
    }
    for (final entry in _terminalShortcuts.entries) {
      if (entry.key != action && entry.value == binding) {
        throw ArgumentError.value(
          binding,
          'binding',
          '此组合已用于“${entry.key.label}”',
        );
      }
    }
    final updated = Map<TerminalShortcutAction, TerminalShortcutBinding>.of(
      _terminalShortcuts,
    )..[action] = binding;
    await _preferences.setString(
      _terminalShortcutsKey,
      jsonEncode({
        for (final entry in updated.entries)
          entry.key.name: entry.value.toJson(),
      }),
    );
    _terminalShortcuts = updated;
    notifyListeners();
  }

  Future<void> resetTerminalShortcuts() async {
    await _preferences.remove(_terminalShortcutsKey);
    _terminalShortcuts = defaultTerminalShortcutBindings;
    notifyListeners();
  }

  Future<void> setTerminalKeywordRules(List<TerminalKeywordRule> rules) async {
    if (rules.length > maxTerminalKeywordRules) {
      throw ArgumentError.value(
        rules.length,
        'rules',
        '关键字规则最多 $maxTerminalKeywordRules 条',
      );
    }
    final seen = <String>{};
    final normalizedRules = <TerminalKeywordRule>[];
    for (final rule in rules) {
      final keyword = rule.keyword.trim();
      if (keyword.isEmpty ||
          keyword.runes.length > 128 ||
          keyword.contains('\n') ||
          keyword.contains('\r') ||
          rule.colorValue < 0 ||
          rule.colorValue > 0xFFFFFFFF) {
        throw ArgumentError.value(rule, 'rule', '关键字规则无效');
      }
      if (!seen.add(keyword.toLowerCase())) {
        throw ArgumentError.value(rule, 'rule', '关键字不能重复');
      }
      normalizedRules.add(
        TerminalKeywordRule(
          keyword: keyword,
          colorValue: rule.colorValue,
          caseSensitive: rule.caseSensitive,
        ),
      );
    }
    await _preferences.setString(
      _terminalKeywordRulesKey,
      jsonEncode(normalizedRules.map((rule) => rule.toJson()).toList()),
    );
    _terminalKeywordRules = List.unmodifiable(normalizedRules);
    notifyListeners();
  }

  Future<void> setStartupSessionGroup(String? group) async {
    final normalized = group?.trim();
    if (normalized != null &&
        (normalized.isEmpty ||
            normalized.runes.length > 80 ||
            normalized.contains('\n') ||
            normalized.contains('\r'))) {
      throw ArgumentError.value(group, 'group', '启动会话分类名称无效');
    }
    if (_startupSessionGroup == normalized) return;
    if (normalized == null) {
      await _preferences.remove(_startupSessionGroupKey);
    } else {
      await _preferences.setString(_startupSessionGroupKey, normalized);
    }
    _startupSessionGroup = normalized;
    notifyListeners();
  }

  Future<void> setRememberWindowBounds(bool remember) async {
    if (_rememberWindowBounds == remember) return;
    await _preferences.setBool(_rememberWindowKey, remember);
    _rememberWindowBounds = remember;
    if (!remember) await _removeWindowBounds();
    notifyListeners();
  }

  Future<void> saveWindowBounds(WindowBounds bounds) async {
    if (!_rememberWindowBounds || !bounds.isUsable) return;
    await _preferences.setDouble(_windowLeftKey, bounds.left);
    await _preferences.setDouble(_windowTopKey, bounds.top);
    await _preferences.setDouble(_windowWidthKey, bounds.width);
    await _preferences.setDouble(_windowHeightKey, bounds.height);
    _windowBounds = bounds;
  }

  Future<void> _removeWindowBounds() async {
    await _preferences.remove(_windowLeftKey);
    await _preferences.remove(_windowTopKey);
    await _preferences.remove(_windowWidthKey);
    await _preferences.remove(_windowHeightKey);
    _windowBounds = null;
  }

  Future<void> setMasterPassword(String password) async {
    final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final encodedSalt = base64Encode(salt);
    final verifier = await _derivePasswordVerifier(password, encodedSalt);
    await _preferences.setString(_passwordSaltKey, encodedSalt);
    await _preferences.setString(_passwordVerifierKey, verifier);
    _passwordSalt = encodedSalt;
    _passwordVerifier = verifier;
    notifyListeners();
  }

  Future<void> removeMasterPassword() async {
    await _preferences.remove(_passwordSaltKey);
    await _preferences.remove(_passwordVerifierKey);
    _passwordSalt = null;
    _passwordVerifier = null;
    _isLocked = false;
    notifyListeners();
  }

  Future<bool> verifyMasterPassword(String password) async {
    final salt = _passwordSalt;
    final expected = _passwordVerifier;
    if (salt == null || expected == null) return false;
    final actual = await _derivePasswordVerifier(password, salt);
    if (actual.length != expected.length) return false;
    var difference = 0;
    for (var index = 0; index < actual.length; index++) {
      difference |= actual.codeUnitAt(index) ^ expected.codeUnitAt(index);
    }
    return difference == 0;
  }

  Future<bool> unlock(String password) async {
    if (!await verifyMasterPassword(password)) return false;
    _isLocked = false;
    notifyListeners();
    return true;
  }

  Future<void> clearAll() async {
    await _preferences.clear();
    _themeStyle = AppThemeStyle.light;
    _terminalFontSize = 14;
    _terminalFontFamily = TerminalFontFamily.system;
    _sshKeepAliveSeconds = 10;
    _terminalShortcuts = defaultTerminalShortcutBindings;
    _terminalKeywordRules = const [];
    _startupSessionGroup = null;
    _rememberWindowBounds = true;
    _windowBounds = null;
    _passwordSalt = null;
    _passwordVerifier = null;
    _isLocked = false;
    notifyListeners();
  }

  static Map<TerminalShortcutAction, TerminalShortcutBinding>
  _parseTerminalShortcuts(String? encoded) {
    final shortcuts = Map<TerminalShortcutAction, TerminalShortcutBinding>.of(
      defaultTerminalShortcutBindings,
    );
    if (encoded == null) return shortcuts;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map<String, dynamic>) return shortcuts;
      for (final entry in decoded.entries) {
        final action = TerminalShortcutAction.values
            .where((value) => value.name == entry.key)
            .firstOrNull;
        if (action == null) continue;
        final binding = TerminalShortcutBinding.fromJson(entry.value);
        final previous = shortcuts.remove(action);
        if (shortcuts.values.contains(binding)) {
          if (previous != null) shortcuts[action] = previous;
          continue;
        }
        shortcuts[action] = binding;
      }
    } on Object {
      return Map.of(defaultTerminalShortcutBindings);
    }
    return shortcuts;
  }

  static List<TerminalKeywordRule> _parseTerminalKeywordRules(String? encoded) {
    if (encoded == null) return const [];
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List) return const [];
      final rules = <TerminalKeywordRule>[];
      final seen = <String>{};
      for (final value in decoded) {
        final rule = TerminalKeywordRule.tryParse(value);
        if (rule == null || !seen.add(rule.keyword.trim().toLowerCase())) {
          continue;
        }
        rules.add(rule);
        if (rules.length == maxTerminalKeywordRules) break;
      }
      return List.unmodifiable(rules);
    } on Object {
      return const [];
    }
  }
}

Future<String> _derivePasswordVerifier(String password, String salt) => compute(
  _derivePasswordVerifierInBackground,
  <String, String>{'password': password, 'salt': salt},
);

String _derivePasswordVerifierInBackground(Map<String, String> input) {
  final passwordBytes = utf8.encode(input['password']!);
  final saltBytes = base64Decode(input['salt']!);
  final hmac = Hmac(sha256, passwordBytes);
  var block = hmac.convert([...saltBytes, 0, 0, 0, 1]).bytes;
  final result = List<int>.of(block);

  for (
    var iteration = 1;
    iteration < AppSettingsController.passwordIterations;
    iteration++
  ) {
    block = hmac.convert(block).bytes;
    for (var index = 0; index < result.length; index++) {
      result[index] ^= block[index];
    }
  }

  return base64Encode(result);
}
