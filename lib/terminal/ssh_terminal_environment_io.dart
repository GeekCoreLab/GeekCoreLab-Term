import 'dart:io';

Map<String, String> sshTerminalEnvironment() {
  final environment = Platform.environment;
  final locale = _effectiveCharacterLocale(environment);
  if (locale == null ||
      !RegExp(r'(^|[._-])utf-?8($|@)', caseSensitive: false).hasMatch(locale)) {
    return const {};
  }

  return {'LC_CTYPE': locale};
}

String? _effectiveCharacterLocale(Map<String, String> environment) {
  for (final name in const ['LC_ALL', 'LC_CTYPE', 'LANG']) {
    final value = environment[name]?.trim();
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}
