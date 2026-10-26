import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geekcore_term/settings/app_lock_page.dart';
import 'package:geekcore_term/settings/app_settings.dart';
import 'package:geekcore_term/settings/window_state.dart';
import 'package:geekcore_term/src/rust/frb_generated.dart';
import 'package:geekcore_term/terminal/terminal_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb) await RustLib.init();
  final settings = await AppSettingsController.load();
  if (!kIsWeb) await WindowStateManager.instance.initialize(settings);
  runApp(GeekcoreTermApp(settings: settings));
}

class GeekcoreTermApp extends StatelessWidget {
  const GeekcoreTermApp({required this.settings, super.key});

  final AppSettingsController settings;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: settings,
    builder: (context, _) => MaterialApp(
      title: 'Geekcore Term',
      debugShowCheckedModeBanner: false,
      theme: settings.themeData,
      home: settings.isLocked
          ? AppLockPage(settings: settings)
          : LocalTerminalPage(settings: settings),
    ),
  );
}
