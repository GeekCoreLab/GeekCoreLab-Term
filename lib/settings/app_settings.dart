import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

enum AppThemeStyle { emerald, ocean, graphite }

extension AppThemeStylePresentation on AppThemeStyle {
  String get label => switch (this) {
    AppThemeStyle.emerald => '翡翠深色',
    AppThemeStyle.ocean => '海洋深色',
    AppThemeStyle.graphite => '石墨深色',
  };

  Color get seedColor => switch (this) {
    AppThemeStyle.emerald => const Color(0xFF31C48D),
    AppThemeStyle.ocean => const Color(0xFF55A9E8),
    AppThemeStyle.graphite => const Color(0xFF9AA8B4),
  };

  Color get scaffoldColor => switch (this) {
    AppThemeStyle.emerald => const Color(0xFF101512),
    AppThemeStyle.ocean => const Color(0xFF10151B),
    AppThemeStyle.graphite => const Color(0xFF141619),
  };

  Color get terminalBackground => switch (this) {
    AppThemeStyle.emerald => const Color(0xFF0B0E0C),
    AppThemeStyle.ocean => const Color(0xFF0A1017),
    AppThemeStyle.graphite => const Color(0xFF101214),
  };

  Color get terminalForeground => switch (this) {
    AppThemeStyle.emerald => const Color(0xFFCCCCCC),
    AppThemeStyle.ocean => const Color(0xFFD0DAE4),
    AppThemeStyle.graphite => const Color(0xFFD0D3D6),
  };

  static AppThemeStyle fromName(String? name) =>
      AppThemeStyle.values.where((style) => style.name == name).firstOrNull ??
      AppThemeStyle.emerald;
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
    required this._rememberWindowBounds,
    required this._windowBounds,
    required String? passwordSalt,
    required String? passwordVerifier,
  }) : _passwordSalt = passwordSalt,
       _passwordVerifier = passwordVerifier,
       _isLocked = passwordSalt != null && passwordVerifier != null;

  static const _themeKey = 'geekcore_term.settings.theme.v1';
  static const _rememberWindowKey = 'geekcore_term.settings.remember_window.v1';
  static const _windowLeftKey = 'geekcore_term.settings.window_left.v1';
  static const _windowTopKey = 'geekcore_term.settings.window_top.v1';
  static const _windowWidthKey = 'geekcore_term.settings.window_width.v1';
  static const _windowHeightKey = 'geekcore_term.settings.window_height.v1';
  static const _passwordSaltKey = 'geekcore_term.settings.password_salt.v1';
  static const _passwordVerifierKey =
      'geekcore_term.settings.password_verifier.v1';

  static const passwordIterations = 210000;

  final SharedPreferencesAsync _preferences;
  AppThemeStyle _themeStyle;
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
    final bounds =
        left == null || top == null || width == null || height == null
        ? null
        : WindowBounds(left: left, top: top, width: width, height: height);

    return AppSettingsController._(
      preferences: preferences,
      themeStyle: AppThemeStylePresentation.fromName(
        await preferences.getString(_themeKey),
      ),
      rememberWindowBounds:
          await preferences.getBool(_rememberWindowKey) ?? true,
      windowBounds: bounds?.isUsable == true ? bounds : null,
      passwordSalt: salt,
      passwordVerifier: verifier,
    );
  }

  AppThemeStyle get themeStyle => _themeStyle;
  bool get rememberWindowBounds => _rememberWindowBounds;
  WindowBounds? get windowBounds => _windowBounds;
  bool get hasMasterPassword =>
      _passwordSalt != null && _passwordVerifier != null;
  bool get isLocked => _isLocked;

  ThemeData get themeData {
    final scheme = ColorScheme.fromSeed(
      seedColor: _themeStyle.seedColor,
      brightness: Brightness.dark,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: _themeStyle.scaffoldColor,
      appBarTheme: AppBarTheme(
        backgroundColor: _themeStyle.scaffoldColor,
        surfaceTintColor: Colors.transparent,
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
    _themeStyle = AppThemeStyle.emerald;
    _rememberWindowBounds = true;
    _windowBounds = null;
    _passwordSalt = null;
    _passwordVerifier = null;
    _isLocked = false;
    notifyListeners();
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
