import 'package:flutter/material.dart';
import 'package:geekcore_term/terminal/terminal_page.dart';
import 'package:geekcore_term/src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const GeekcoreTermApp());
}

class GeekcoreTermApp extends StatelessWidget {
  const GeekcoreTermApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF31C48D),
      brightness: Brightness.dark,
    );

    return MaterialApp(
      title: 'Geekcore Term',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF101512),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF101512),
          surfaceTintColor: Colors.transparent,
        ),
      ),
      home: const LocalTerminalPage(),
    );
  }
}
