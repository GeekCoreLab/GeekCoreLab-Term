import 'app_settings.dart';
import 'window_state_stub.dart'
    if (dart.library.io) 'window_state_io.dart'
    as platform;

class WindowStateManager {
  WindowStateManager._();

  static final instance = WindowStateManager._();
  final platform.WindowStateBackend _backend = platform.WindowStateBackend();

  Future<void> initialize(AppSettingsController settings) =>
      _backend.initialize(settings);

  Future<void> setRemembering(bool remember) =>
      _backend.setRemembering(remember);

  void resetAfterClear() => _backend.resetAfterClear();
}
