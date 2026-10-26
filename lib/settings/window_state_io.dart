import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import 'app_settings.dart';

class WindowStateBackend with WindowListener {
  AppSettingsController? _settings;
  Timer? _saveTimer;
  bool _initialized = false;
  bool _skipNextBoundsSave = false;

  bool get _isDesktop =>
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  Future<void> initialize(AppSettingsController settings) async {
    if (!_isDesktop || _initialized) return;
    _initialized = true;
    _settings = settings;
    await windowManager.ensureInitialized();
    windowManager.addListener(this);

    final initialBounds = settings.windowBounds;
    unawaited(
      windowManager.waitUntilReadyToShow(
        const WindowOptions(size: Size(1280, 820), center: true),
        () async {
          await windowManager.setMinimumSize(const Size(900, 560));
          if (settings.rememberWindowBounds && initialBounds != null) {
            await windowManager.setBounds(
              Rect.fromLTWH(
                initialBounds.left,
                initialBounds.top,
                initialBounds.width,
                initialBounds.height,
              ),
            );
          } else {
            await windowManager.center();
          }
          await windowManager.show();
          await windowManager.focus();
        },
      ),
    );
  }

  Future<void> setRemembering(bool remember) async {
    _saveTimer?.cancel();
    if (remember && _initialized) await _saveCurrentBounds();
  }

  void resetAfterClear() {
    _saveTimer?.cancel();
    _skipNextBoundsSave = true;
  }

  @override
  void onWindowMove() => _scheduleSave();

  @override
  void onWindowResize() => _scheduleSave();

  void _scheduleSave() {
    final settings = _settings;
    if (settings == null || !settings.rememberWindowBounds) return;
    if (_skipNextBoundsSave) {
      _skipNextBoundsSave = false;
      return;
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 350), _saveCurrentBounds);
  }

  Future<void> _saveCurrentBounds() async {
    final settings = _settings;
    if (settings == null || !settings.rememberWindowBounds) return;
    try {
      if (await windowManager.isMaximized()) return;
      final bounds = await windowManager.getBounds();
      await settings.saveWindowBounds(
        WindowBounds(
          left: bounds.left,
          top: bounds.top,
          width: bounds.width,
          height: bounds.height,
        ),
      );
    } on Object {
      // Window persistence is best effort; it must not interrupt terminal IO.
    }
  }
}
